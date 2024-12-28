//
//  Connection.swift
//  PostgresKit
//
//  Created by Illia Senchukov on 13.09.2024.
//

import Foundation
import CPostgres
import SqlAdapterKit

final class Connection: @unchecked Sendable {

    private let connection: UnsafeMutablePointer<pqxx.connection>

    init(connection: UnsafeMutablePointer<pqxx.connection>) {
        self.connection = connection
    }

    deinit {
        connection.pointee.cancel_query()
        connection.pointee.close()
        connection.deallocate()
    }

    func close() {
        connection.pointee.close()
        connection.deallocate()
    }

}

extension Connection {

    func query(_ query: String, metaInfo: DbInfo) throws(QueryError) -> SqlAdapterKit.QueryResult {
        let result = query.withCString { pointer in
            CPostgres.postgres.query(connection, pointer)
        }

        guard result.isSuccess() else {
            let error = result.getError()
            throw .init(message: String(error.message))
        }

        let mapStart = CFAbsoluteTimeGetCurrent()
        let queryResult = result.getValue()

        let columns = queryResult.columns.enumerated().map { idx, column in
            let type = metaInfo.oidToType(column.type) ?? .init(name: "UNKNOWN", category: .unknown)
            return PostgresColumn(
                id: idx,
                name: .init(column.name),
                tableOid: column.table,
                type: type.genericType
            )
        }

        var rows: [GenericRow] = []
        rows.reserveCapacity(queryResult.rows.count)

        for i in (queryResult.rows.startIndex..<queryResult.rows.endIndex) {
            let row = queryResult.rows[i]

            var data: [GenericField] = []
            data.reserveCapacity(row.count)

            for f in row.startIndex..<row.endIndex {
                data.append(.init(value: row[f].isNull ? nil : String(row[f].value)))
            }

            rows.append(.init(id: i, data: consume data))
        }

        print("Mapping took \(CFAbsoluteTimeGetCurrent() - mapStart) seconds")
        return .init(columns: columns, rows: rows)
    }

    func cancelQuery() {
        connection.pointee.cancel_query()
    }

}
