//
//  Adapter.swift
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

import Foundation
import CPostgres
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

    func connect() throws(QueryError) -> PostgresConnection {
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

        try await pool.withConnection { (connection: PostgresConnection) throws(QueryError) in
            try await metaInfo.reload(connection: connection)
        }
    }

}

public extension PostgresAdapter {

    func query(_ query: String) async throws(QueryError) -> SqlAdapterKit.QueryResult {
        try await pool.withCancellableConnection { (connection) throws(QueryError) in
            do {
                return try await connection.query(query, metaInfo: metaInfo)
            } catch (let error as QueryError) {
                throw error
            } catch {
                throw .cancelled
            }
        }
    }

}
