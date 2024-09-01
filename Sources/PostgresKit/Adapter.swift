//
//  Adapter.swift
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

import Foundation
import CPostgres
import SqlAdapterKit

public typealias OId = UInt32

public class PostgresColumn: SqlAdapterKit.Column {

    let tableOid: OId

    public init(id: Int, name: String, tableOid: OId) {
        self.tableOid = tableOid
        super.init(id: id, name: name)
    }

}

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

        let columns = queryResult.columns.enumerated().map { idx, column in
            PostgresColumn(id: idx, name: .init(column.name), tableOid: column.table)
        }

        let rows = queryResult.rows.map {
            SqlAdapterKit.Row(data: $0.map {
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
