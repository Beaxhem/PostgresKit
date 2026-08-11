//
//  Types.swift
//  PostgresKit
//
//  Created by Illia Senchukov on 13.09.2024.
//

import Foundation
import DataEngine

public typealias OId = UInt32

/// Postgres' own `typcategory`, from `pg_type`.
enum PostgresTypeCategory: String {
    case numeric = "N"
    case boolean = "B"
    case string = "S"
    case array = "A"
    case datetime = "D"
    case timespan = "T"
    case `enum` = "E"
    case userDefined = "U"

    case geometric = "G"
    case composite = "C"
    case networkAddress = "I"

    case range = "R"
    case bitString = "V"

    case pseudo = "P"
    case unknown = "X"
    case `internal` = "Z"
}

/// One entry of `pg_type`, as much of it as the driver reads.
struct PostgresType {

    let name: String

    let category: PostgresTypeCategory

    /// Element type for an array, 0 otherwise. What lets `int4[]` describe itself as a
    /// list *of integers* rather than a list of something unknown.
    let elementOid: OId

}

extension PostgresType {

    /// The shape of a value of this type.
    ///
    /// Name first, category second. Postgres files `jsonb`, `bytea` and `uuid` all under
    /// category `U` — "user-defined" — which is true of the catalog and useless to a
    /// grid: it would render a JSON document, a blob and an identifier identically. The
    /// names are stable across every server, so reading them is not a heuristic.
    ///
    /// - Parameter types: the whole `pg_type` map, for resolving an array's elements.
    func shape(resolving types: [OId: PostgresType]) -> DataShape {
        if let known = Self.shapesByName[name] {
            return known
        }

        switch category {
        case .numeric:
            return .scalar(Self.numericKind(name))

        case .boolean:
            return .scalar(.boolean)

        case .string:
            return .scalar(name == "char" || name == "bpchar" ? .char : .text)

        case .array:
            // `typelem` names the element type. A `_int4` whose element is missing from
            // the map is still a list, just of something this driver cannot name.
            guard elementOid != 0, let element = types[elementOid] else {
                return .list(.unknown)
            }

            return .list(element.shape(resolving: types))

        case .datetime:
            return .scalar(Self.datetimeKind(name))

        case .timespan:
            return .scalar(.interval)

        case .enum:
            return .scalar(.enumeration)

        case .range:
            // A range is two bounds and their inclusivity — structure, rendered by
            // Postgres as `[a,b)`. Composite rather than scalar, so it gets the
            // inspector rather than a text field pretending it is editable.
            return .variant

        case .composite:
            return .variant

        case .geometric:
            return .scalar(.geography)

        case .networkAddress:
            return .scalar(.text)

        case .bitString:
            return .scalar(.binary)

        case .userDefined, .pseudo, .internal:
            return .scalar(.opaque)

        case .unknown:
            return .unknown
        }
    }

}

private extension PostgresType {

    /// Types whose name says more than their category does.
    static let shapesByName: [String: DataShape] = [
        "json": .variant,
        "jsonb": .variant,
        "bytea": .scalar(.binary),
        "uuid": .scalar(.uuid),
        "xml": .scalar(.text),
        "money": .scalar(.decimal)
    ]

    static func numericKind(_ name: String) -> ScalarKind {
        switch name {
        case "int2", "int4", "int8", "smallint", "integer", "bigint", "oid":
            .integer
        case "numeric", "decimal":
            .decimal
        case "float4", "float8", "real", "double precision":
            .float
        case let name where name.hasPrefix("reg"):
            // `regclass`, `regtype` and friends are oids wearing a name. Catalog
            // plumbing, not data.
            .opaque
        default:
            .float
        }
    }

    static func datetimeKind(_ name: String) -> ScalarKind {
        switch name {
        case "date": .date
        case "time": .time
        case "timetz": .time
        case "timestamptz": .timestampWithZone
        default: .timestamp
        }
    }

}
