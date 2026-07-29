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
        PQfinish(connection)
    }

}

extension PostgresConnection {

    func query(_ query: String, metaInfo: DbInfo) async throws -> QueryResult {
        let start = CFAbsoluteTimeGetCurrent()

        // Stream the result set one row at a time instead of letting libpq
        // buffer the entire thing in its own memory before we copy it out.
        // `PQsendQuery` dispatches asynchronously and `PQsetSingleRowMode` makes
        // each `PQgetResult` return a `PGresult` holding a single row, which we
        // copy into the arena and free immediately. Peak memory is therefore the
        // arena plus one driver-owned row, not the arena plus a full second copy
        // of the whole result set.
        guard PQsendQuery(connection, query) == 1 else {
            throw QueryError(message: String(cString: PQerrorMessage(connection)))
        }

        // Best effort: if this fails, libpq falls back to buffering the whole set
        // into a single `PGRES_TUPLES_OK`, which the drain loop below still reads
        // correctly — we just lose the memory win for this query.
        _ = PQsetSingleRowMode(connection)

        // `PQexec` reported only the *last* statement of a multi-statement string;
        // `PQgetResult` instead surfaces one result set per statement. To preserve
        // that behaviour we build each statement's rows into its own arena and keep
        // only the most recently completed result set — column counts can differ
        // between statements, and a single shared arena would both merge unrelated
        // rows and trip the builder's rectangular-rows assertion.
        var latest: (columns: [PostgresColumn], builder: QueryResultArenaBuilder)?

        // In-flight statement. Column count is unknown until the first row arrives,
        // so the arena can't be pre-sized; it grows by amortised doubling instead.
        var builder = QueryResultArenaBuilder()
        var columns: [PostgresColumn]?
        var pendingError: String?

        // A streamed query owns the connection until `PQgetResult` returns nil.
        // On a SQL error we must keep draining to the end: the pool returns a
        // healthy-looking connection to its buffer, and a half-drained one would
        // be busy and poison the next borrower. Cancellation is different — the
        // pool drops a cancelled connection rather than reusing it, so throwing
        // out of the loop mid-stream is safe there.
        while let result = PQgetResult(connection) {
            defer { PQclear(result) }
            let status = PQresultStatus(result)

            switch status {
            case PGRES_SINGLE_TUPLE, PGRES_TUPLES_OK:
                if columns == nil {
                    columns = Self.makeColumns(result, metaInfo: metaInfo)
                }

                // Once an error is latched we only drain; stop copying rows.
                guard pendingError == nil else { continue }

                try Task.checkCancellation()

                // `PGRES_SINGLE_TUPLE` carries one row; a `PGRES_TUPLES_OK` carries
                // the whole set when single-row mode wasn't in effect, and zero rows
                // when it was (it just marks the end of this statement).
                let columnsCount = PQnfields(result)
                for tuple in 0..<PQntuples(result) {
                    for columnIdx in 0..<columnsCount {
                        // `PQgetvalue` returns a pointer to an empty string for SQL
                        // NULL, not a null pointer, so `PQgetisnull` is the only way
                        // to tell a real NULL from an empty/zero-length value.
                        guard PQgetisnull(result, tuple, columnIdx) == 0,
                              let cell = PQgetvalue(result, tuple, columnIdx) else {
                            builder.appendNull()
                            continue
                        }

                        let length = Int(PQgetlength(result, tuple, columnIdx))
                        builder.appendValue(cell, length: length)
                    }

                    builder.finishRow()
                }

                // `PGRES_TUPLES_OK` terminates the current statement's result set.
                if status == PGRES_TUPLES_OK, let statementColumns = columns {
                    latest = (statementColumns, builder)
                    builder = QueryResultArenaBuilder()
                    columns = nil
                }
            case PGRES_COMMAND_OK, PGRES_EMPTY_QUERY:
                // A statement with no result set (INSERT/UPDATE/DDL, or empty). It
                // still counts as the latest statement, so a trailing command wins
                // over an earlier SELECT — as it did under `PQexec`.
                latest = nil
                builder = QueryResultArenaBuilder()
                columns = nil
            default:
                // Latch the first error, then keep looping so the connection is
                // fully drained before we surface it.
                if pendingError == nil {
                    pendingError = String(cString: PQerrorMessage(connection))
                }
            }
        }

        if let pendingError {
            throw QueryError(message: pendingError)
        }

        // A pure command (or empty query) as the last statement yields no result
        // set — report it as empty, matching the previous `PGRES_COMMAND_OK` path.
        guard let latest else {
            return .empty
        }

        let store = latest.builder.makeStore()
        let info = ExecutionInfo(duration: CFAbsoluteTimeGetCurrent() - start)

        return .init(columns: latest.columns, store: store, executionInfo: info)
    }

    /// Build the column descriptors from any result that carries field metadata
    /// (a `PGRES_SINGLE_TUPLE` row or the terminal `PGRES_TUPLES_OK`).
    private static func makeColumns(_ result: OpaquePointer?, metaInfo: DbInfo) -> [PostgresColumn] {
        let columnsCount = PQnfields(result)

        var columns: [PostgresColumn] = []
        columns.reserveCapacity(Int(columnsCount))

        for column in 0..<columnsCount {
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

        return columns
    }

    func cancelQuery<Factory, Pool>(pool: Pool) async throws(QueryError) where PostgresConnection == Factory.C, Factory : ConnectionFactory, Pool : ConnectionPool<Factory> {
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
