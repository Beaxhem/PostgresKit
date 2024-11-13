//
//  Adapter.swift
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

import Foundation
@preconcurrency import CPostgres
import SqlAdapterKit

public struct PostgresConfiguration: Configuration, Sendable {

    public var username: String
    public var password: String
    public var host: String
    public var port: Int16
    public var database: String?

    public var connectionString: String {
        "postgres://\(username):\(password)@\(host):\(port)/\(database ?? "")"
    }

    public init(username: String, password: String, host: String, port: Int16, database: String?) {
        self.username = username
        self.password = password
        self.host = host
        self.port = port
        self.database = database
    }

}

extension PostgresConfiguration: DatabaseConnectionConfig {

    public consuming func withDatabase(_ database: String?) -> PostgresConfiguration {
        .init(username: username, password: password, host: host, port: port, database: database)
    }

}

public final actor PostgresAdapter: SqlAdapter, Sendable {

    private let connection: Connection

    private let metaInfo: DbInfo

    init(connection: Connection) async {
        self.connection = connection
        self.metaInfo = .init()

        await metaInfo.reload(connection: connection)
    }

    public static func connect(configuration: SqlAdapterKit.Configuration) async throws(QueryError) -> PostgresAdapter {
        let result = configuration.connectionString.withCString { pointer in
            CPostgres.newConnection(pointer)
        }
        guard !result.hasError() else {
            let error = result.getError()
            throw .init(message: String(error.message))
        }

        guard let connection = result.getValue() else {
            throw .init(message: "Internal error")
        }

        return await .init(connection: .init(connection: connection))
    }

}

public extension PostgresAdapter {

    func query(_ query: String) throws(QueryError) -> SqlAdapterKit.QueryResult {
        try connection.query(query, metaInfo: metaInfo)
    }

    nonisolated func cancelQuery() {
        connection.cancelQuery()
    }

    func table(for column: any SqlAdapterKit.Column) -> (any SqlTable)? {
        guard let column = column as? PostgresColumn else {
            return nil
        }

        return metaInfo.oidToTable(column.tableOid)
    }

    func fetchTables() throws(QueryError) -> [any SqlTable] {
        metaInfo.tables
    }

    func primaryKeys(for table: any SqlTable) -> Set<String> {
        guard let table = table as? PostgresTable else {
            return []
        }

        return metaInfo.oidToPrimaryKeys(table.oid) ?? []
    }

}

extension PostgresAdapter: MetaInfoProvidingAdapter {

    public func reloadMetaInfo() async throws(QueryError) {
        await metaInfo.reload(connection: connection)
    }

}
