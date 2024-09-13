//
//  Types.swift
//  PostgresKit
//
//  Created by Illia Senchukov on 13.09.2024.
//

import Foundation
import SqlAdapterKit
import CPostgres

public typealias OId = UInt32

public struct PostgresColumn: SqlAdapterKit.Column {

    public let id: Int
    public let name: String

    let tableOid: OId

    public init(id: Int, name: String, tableOid: OId) {
        self.id = id
        self.name = name
        self.tableOid = tableOid
    }

}

public class PostgresTable: SqlTable {

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

    let oid: OId

    init(tableSchema: String, name: String, oid: OId) {
        self.tableSchema = tableSchema
        self.name = name
        self.oid = oid
    }

}

enum TypeCategory: String {
    case array = "A"
    case boolean = "B"
    case composite = "C"
    case datetime = "D"
    case `enum` = "E"
    case geometric = "G"
    case networkAddress = "I"
    case numeric = "N"
    case pseudo = "P"
    case range = "R"
    case string = "S"
    case timespan = "T"
    case userDefined = "U"
    case bitString = "V"
    case unknown = "X"
    case `internal` = "Z"
}

struct PostgresType {
    let name: String
    let category: TypeCategory
}
