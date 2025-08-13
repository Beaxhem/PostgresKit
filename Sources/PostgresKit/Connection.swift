//
//  Connection.swift
//  PostgresKit
//
//  Created by Illia Senchukov on 13.09.2024.
//

import Foundation
import CPostgres
import SqlAdapterKit
import ConnectionPool

final class PostgresConnection: CancellableConnection, @unchecked Sendable {

    private let connection: OpaquePointer

    init(connection: OpaquePointer) {
        self.connection = connection
    }

    deinit {
        cancelQuery()
        PQfinish(connection)
    }

}

extension PostgresConnection {

    func query(_ query: String, metaInfo: DbInfo) async throws -> QueryResult {
        let start = CFAbsoluteTimeGetCurrent()

        let result = PQexec(connection, query)
        defer { PQclear(result) }

        switch PQresultStatus(result) {
        case PGRES_COMMAND_OK:
            return .empty
        case PGRES_TUPLES_OK:
            break
        default:
            throw QueryError(message: String(cString: PQerrorMessage(connection)))
        }

        let rowsCount = PQntuples(result)
        let columnsCount = PQnfields(result)

        var columns: [PostgresColumn] = []
        columns.reserveCapacity(Int(columnsCount))

        for column in (0..<columnsCount) {
            let tableOid = PQftable(result, column)
            let typeOid = PQftype(result, column)

            let type = metaInfo.oidToType[typeOid] ?? .init(name: "#UNKNOWN", category: .unknown)

            columns.append(
                .init(
                    id: Int(column),
                    name: String(cString: PQfname(result, column)),
                    tableOid: tableOid,
                    type: type.genericType
                )
            )
        }

        var rows: [GenericRow] = []
        rows.reserveCapacity(Int(rowsCount))

        for rowIdx in (0..<rowsCount) {
            try Task.checkCancellation()
            var fields: [GenericField] = []
            fields.reserveCapacity(Int(columnsCount))

            for columnIdx in (0..<columnsCount) {
                if let value = PQgetvalue(result, rowIdx, columnIdx) {
                    let length = PQgetlength(result, rowIdx, columnIdx)
                    let value = NSString(bytes: value, length: Int(length), encoding: String.Encoding.utf8.rawValue) as? String

                    fields.append(.init(value: value))
                } else {
                    fields.append(.init(value: nil))
                }
            }

            rows.append(.init(id: Int(rowIdx), data: fields))
        }

        let info = ExecutionInfo(duration: CFAbsoluteTimeGetCurrent() - start)

        return .init(columns: columns, rows: rows, executionInfo: info)
    }

    func cancelQuery() {
        print("POSTGRES: trying to cancel query")
        guard let cancel = PQgetCancel(connection) else {
            print("Failed to get cancel object", String(cString: PQerrorMessage(connection)))
            return
        }

        defer { PQfreeCancel(cancel) }

        let bufferSize = 256
        let errbuf = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer { errbuf.deallocate() }

        let success = PQcancel(cancel, errbuf, Int32(bufferSize)) != 0

        if success {
            print("Query cancel request sent successfully.")
        } else {
            let errorMessage = String(cString: errbuf)
            print("Failed to send cancel request: \(errorMessage)")
        }
    }

}
