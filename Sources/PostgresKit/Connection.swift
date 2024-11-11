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

        var id = 0
        let rows = queryResult.rows.map {
            defer { id += 1}

            return SqlAdapterKit.GenericRow(id: id,
                                            data: $0.map {
                SqlAdapterKit.GenericField(value: $0.isNull ? nil : String($0.value))
            })
        }

        print("Mapping took \(CFAbsoluteTimeGetCurrent() - mapStart) seconds")
        return .init(columns: columns, rows: rows)
    }

    func cancelQuery() {
        connection.pointee.cancel_query()
    }

}
