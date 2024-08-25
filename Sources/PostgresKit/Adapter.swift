//
//  Adapter.swift
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

import CPostgres
import SqlAdapterKit

public final class PostgresAdapter {

    let connection: Connection

    init(connection: Connection) {
        self.connection = connection
    }

    public static func connect(configuration: SqlAdapterKit.Configuration) -> Result<PostgresAdapter, QueryError> {
        let result = configuration.connectionString.withCString { pointer in
            CPostgres.newConnection(pointer)
        }
        guard !result.hasError() else {
            let error = result.getError()
            return .failure(.init(message: String(error.message)))
        }

        guard let connection = result.getValue() else {
            return .failure(.init(message: "Internal error"))
        }

        return .success(.init(connection: connection))
    }

}

extension PostgresAdapter: SqlAdapter {

    public func query(_ query: String) -> Result<[String], QueryError> {
        let result = query.withCString { pointer in
            CPostgres.query(connection, pointer)
        }

        guard result.isSuccess() else {
            let error = result.getError()
            return .failure(.init(message: String(error.message)))
        }

        let queryResult = result.getValue()

        print("Query result:", queryResult.rows.count)
        return .success([])
    }

    public func execute(_ query: String) {

    }

}
