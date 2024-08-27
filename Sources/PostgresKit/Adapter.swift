//
//  Adapter.swift
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

import Foundation
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

    public func query(_ query: String) -> Result<SqlAdapterKit.QueryResult, QueryError> {
        let start = CFAbsoluteTimeGetCurrent()
        let result = query.withCString { pointer in
            CPostgres.query(connection, pointer)
        }
        print("Query took \(CFAbsoluteTimeGetCurrent() - start) seconds")
        guard result.isSuccess() else {
            let error = result.getError()
            return .failure(.init(message: String(error.message)))
        }

        let mapStart = CFAbsoluteTimeGetCurrent()
        let queryResult = result.getValue()

        let columns = queryResult.columns.map { String($0) }

        let rows = queryResult.rows.enumerated().map {
            SqlAdapterKit.Row(idx: UInt32($0), columns: columns, data: $1.map {
                SqlAdapterKit.Field(type: $0.type,
                                    value: String($0.value),
                                    isNull: $0.isNull)
            })
        }

        print("Mapping took \(CFAbsoluteTimeGetCurrent() - mapStart) seconds")
        return .success(.init(columns: columns, rows: rows))
    }

    public func execute(_ query: String) {

    }

}
