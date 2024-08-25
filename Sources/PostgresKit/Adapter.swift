//
//  Adapter.swift
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

import CPostgres
import SqlAdapterKit

enum PostgresError: Swift.Error {
    case connectionFailed
    case dbError(String)
}

public struct PostgresAdapter {

    let connection: Connection

    public static func connect(configuration: SqlAdapterKit.Configuration) -> Result<PostgresAdapter, Swift.Error> {
        let result = configuration.connectionString.withCString { pointer in
            CPostgres.newConnection(pointer)
        }
        guard !result.hasError() else {
            let error = result.getError()
            return .failure(PostgresError.dbError(String(error.message)))
        }

        let connection = result.getValue()
        return .success(.init(connection: connection))
    }

}

extension PostgresAdapter: SqlAdapter {

    public func query(_ query: String) -> Result<[String], Swift.Error> {
        let result = query.withCString { pointer in
            CPostgres.query(connection, pointer)
        }

        guard result.isSuccess() else {
            let error = result.getError()
            return .failure(PostgresError.dbError(String(error.message)))
        }

        let queryResult = result.getValue()

        print("Query result:", queryResult.rows.count)
        return .success([])
    }

    public func execute(_ query: String) {

    }

}
