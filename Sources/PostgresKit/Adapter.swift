//
//  Adapter.swift
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

import Foundation
@preconcurrency import CPostgres
import SqlAdapterKit
import ConnectionPool

public struct PostgresConfiguration: Sendable {

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

struct PostgresConnectionFactory: ConnectionFactory {

    let configuration: PostgresConfiguration

    func connect() throws(QueryError) -> PostgresKit.Connection {
        let connection = PQconnectdb(configuration.connectionString)
        if PQstatus(connection) != CONNECTION_OK {
            defer { PQfinish(connection)}

            throw .init(message: String(cString: PQerrorMessage(connection)))
        }

        return .init(connection: connection!)
    }

}

public final actor PostgresAdapter: SqlAdapter, Sendable {

    private let pool: ConnectionPool<PostgresConnectionFactory>

    private let metaInfo = DbInfo()

    public init(configuration: PostgresConfiguration) async throws(QueryError) {
        self.pool = try await .init(factory: .init(configuration: configuration))

        try await pool.withConnection { (connection: Connection) throws(QueryError) in
            await metaInfo.reload(connection: connection)
        }
    }

}

public extension PostgresAdapter {

    func query(_ query: String) async throws(QueryError) -> SqlAdapterKit.QueryResult {
        try await pool.withConnection { (connection) throws(QueryError) in
            try connection.query(query, metaInfo: metaInfo)
        }
    }

    nonisolated func cancelQuery() {
//        connection.cancelQuery()
    }

    func table(for column: any SqlAdapterKit.Column) -> (any SqlTable)? {
        guard let column = column as? PostgresColumn else {
            return nil
        }

        return metaInfo.oidToTable(column.tableOid)
    }

    func fetchTables() async throws(QueryError) -> [any SqlTable] {
        let sqlQuery = """
with tables as (
    SELECT table_schema, table_name
    FROM information_schema.tables
    WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema')
)
SELECT
    table_schema, table_name,
    CONCAT('"', table_schema, '"."', table_name, '"')::regclass::oid as oid
FROM tables
"""
        let result = try await pool.withConnection { (connection) throws(QueryError) in
            try connection.query(sqlQuery, metaInfo: metaInfo)
        }
        
        let tables: [PostgresTable] = result.rows.compactMap { row in
            guard row.data.count == 3,
                  let schema = row.data[0].value,
                  let name = row.data[1].value,
                  let oidString = row.data[2].value else {
                return nil
            }
            let oid = OId(oidString) ?? 0

            return PostgresTable(tableSchema: schema, name: name, oid: oid)
        }

        metaInfo.tables = tables
        return tables
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
        try await pool.withConnection { (connection) throws(QueryError) in
            await metaInfo.reload(connection: connection)
        }
    }

}
