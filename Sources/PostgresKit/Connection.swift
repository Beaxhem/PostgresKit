//
//  Connection.swift
//  PostgresKit
//
//  Created by Illia Senchukov on 13.09.2024.
//

import Foundation
import CPostgres
import SqlAdapterKit

extension Connection {

    func query(_ query: String) throws(QueryError) -> SqlAdapterKit.QueryResult {
        let result = query.withCString { pointer in
            CPostgres.query(self, pointer)
        }
        guard result.isSuccess() else {
            let error = result.getError()
            throw .init(message: String(error.message))
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
        return .init(columns: columns, rows: rows)
    }

}
