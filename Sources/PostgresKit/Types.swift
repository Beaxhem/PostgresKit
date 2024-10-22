//
//  Types.swift
//  PostgresKit
//
//  Created by Illia Senchukov on 13.09.2024.
//

import Foundation
import SqlAdapterKit

public typealias OId = UInt32

public struct PostgresColumn: SqlAdapterKit.Column {

    public let id: Int
    public let name: String
    public let type: GenericType

    let tableOid: OId

    init(id: Int, name: String, tableOid: OId, type: GenericType) {
        self.id = id
        self.name = name
        self.tableOid = tableOid
        self.type = type
    }

}

public final class PostgresTable: SqlTable {

    public var id: Int {
        .init(oid)
    }

    public var queryName: String {
        "\"\(tableSchema)\".\"\(name)\""
    }

    public var displayName: String {
        name
    }

    public let tableSchema: String

    let name: String

    public let oid: OId

    init(tableSchema: String, name: String, oid: OId) {
        self.tableSchema = tableSchema
        self.name = name
        self.oid = oid
    }

}

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

struct PostgresType: SqlType {

    let name: String
    private let category: PostgresTypeCategory

    init(name: String, category: PostgresTypeCategory) {
        self.name = name
        self.category = category
    }

    var genericType: GenericType {
        .init(name: name, category: genericCategory)
    }

    var genericCategory: TypeCategory {
        switch category {
        case .numeric:
            switch name {
            case "smallint", "integer", "bigint", "numeric", "int2", "int4", "int8":
                .integer
            case "real", "double precision", "float4", "float8":
                .float
            case "regprocedure", "regoper", "regoperator", "regclass", "regcollation", "regtype", "regrole", "regnamespace":
                .system
            default:
                .float
            }
        case .boolean:
            .boolean
        case .string:
            switch name {
            case "char":
                .nchar
            case "varchar":
                .varchar
            default:
                .text
            }
        case .array:
            .array
        case .datetime:
            switch name {
            case "date":
                .date
            case "time":
                .time
            case "timestamp":
                .datetime
            default:
                .datetime
            }
        case .timespan:
            .interval
        case .enum:
            .enumeration
        case .userDefined:
            .userDefined
        case .geometric, .composite, .networkAddress, .range:
            .unknown
        case .bitString:
            .binary
        case .pseudo:
            .system
        case .unknown:
            .unknown
        case .internal:
            .system
        }
    }

}
