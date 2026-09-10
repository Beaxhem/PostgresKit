//
//  Connection.swift
//  PostgresKit
//
//  Created by Illia Senchukov on 13.09.2024.
//

import Foundation
import CPostgres
import ConnectionPool
import DataEngine

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

    /// Runs `query`, reporting each statement of it as it completes.
    ///
    /// `PQexec` reported only the last statement of a multi-statement string;
    /// `PQgetResult` instead surfaces one result set per statement, which this loop has
    /// always drained and then thrown away all but the last of. Reporting them is the
    /// whole of the change — the same string goes to the same `PQsendQuery`, so the
    /// implicit per-request transaction Postgres wraps it in is untouched.
    func execute(
        _ query: String,
        metaInfo: DbInfo,
        reporting: (@Sendable (RunEvent) -> Void)? = nil
    ) async throws -> ExecutionOutcome {
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

        // Each statement's rows go into their own arena: column counts differ between
        // statements, and a shared arena would both merge unrelated rows and trip the
        // builder's rectangular-rows assertion.
        //
        // `latest` is still kept, and still takes a command as readily as a result set:
        // what a script's last statement did is the answer this function returns,
        // whether or not it was a SELECT, exactly as it was under `PQexec`.
        var latest: ExecutionOutcome?

        // In-flight statement. The builder is made once this statement's columns are
        // known rather than up front, because a streamed run has to hand out whole
        // results and a result needs its columns — capturing them at construction is
        // what keeps the emit closure free of mutable state.
        var builder: StreamingResultBuilder?
        var columns: [ColumnDescriptor]?
        var pendingError: String?

        // Which statement is being drained, and when it began. The index is what a
        // reported outcome is addressed by — the driver has `PGresult`s, not character
        // offsets, so an ordinal is the whole of a result's identity.
        var statementIndex = 0
        var statementStart = start

        // The old `mayStream` guard is gone. It existed because a later statement
        // superseded an earlier one's result and rows already handed over cannot be
        // taken back — so a script could only ever stream its first statement. A partial
        // now carries the index of the statement it belongs to, and there is nothing
        // left to supersede; a caller that still wants one grid's worth says so by
        // ignoring the rest. See ``execute(_:metaInfo:onPartial:)``.

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

                let statementBuilder: StreamingResultBuilder
                if let builder {
                    statementBuilder = builder
                } else {
                    let statementColumns = columns ?? []
                    let index = statementIndex

                    statementBuilder = StreamingResultBuilder(
                        onPartial: reporting.map { emit in
                            { store in
                                emit(
                                    .partial(
                                        index: index,
                                        PartialResult(columns: statementColumns, store: store)
                                    )
                                )
                            }
                        }
                    )

                    builder = statementBuilder
                }

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
                            statementBuilder.appendNull()
                            continue
                        }

                        let length = Int(PQgetlength(result, tuple, columnIdx))
                        statementBuilder.appendValue(cell, length: length)
                    }

                    statementBuilder.finishRow()
                }

                // `PGRES_TUPLES_OK` terminates the current statement's result set.
                if status == PGRES_TUPLES_OK, let statementColumns = columns {
                    let outcome = ExecutionOutcome(
                        columns: statementColumns,
                        store: statementBuilder.makeStore(),
                        statistics: .init(duration: CFAbsoluteTimeGetCurrent() - statementStart)
                    )

                    latest = outcome
                    builder = nil
                    columns = nil

                    reporting?(
                        .statement(StatementOutcome(index: statementIndex, disposition: .succeeded(outcome)))
                    )

                    statementIndex += 1
                    statementStart = CFAbsoluteTimeGetCurrent()
                }
            case PGRES_COMMAND_OK, PGRES_EMPTY_QUERY:
                // A statement with no result set (INSERT/UPDATE/DDL, or empty). It
                // still counts as the latest statement, so a trailing command wins
                // over an earlier SELECT — as it did under `PQexec`. What it did is
                // carried out rather than dropped, so the grid can say so instead of
                // drawing an empty table.
                guard pendingError == nil else { continue }

                let outcome = ExecutionOutcome.command(
                    Self.makeCommandSummary(result),
                    statistics: .init(duration: CFAbsoluteTimeGetCurrent() - statementStart)
                )

                latest = outcome
                builder = nil
                columns = nil

                reporting?(
                    .statement(StatementOutcome(index: statementIndex, disposition: .succeeded(outcome)))
                )

                statementIndex += 1
                statementStart = CFAbsoluteTimeGetCurrent()
            default:
                // Latch the first error, then keep looping so the connection is
                // fully drained before we surface it.
                //
                // Reported here as well as latched, because the driver is the only thing
                // that knows *which* statement broke — it is the one counting them. What
                // it cannot know is how many were left behind: libpq abandons the rest of
                // the message and never mentions them, and finding out would mean
                // splitting the script, which is exactly what this design does not do. So
                // a run says where it stopped and never claims "4 of 9".
                if pendingError == nil {
                    let message = String(cString: PQerrorMessage(connection))

                    pendingError = message

                    reporting?(
                        .statement(
                            StatementOutcome(
                                index: statementIndex,
                                disposition: .failed(QueryError(message: message))
                            )
                        )
                    )
                }
            }
        }

        if let pendingError {
            // Rows read before the error was latched are still rows the database sent,
            // and the caller keeps whatever has been published when a run breaks. Those
            // in the segment still being filled would otherwise be dropped for no
            // reason but where the chunk boundary happened to fall.
            builder?.flush()

            throw QueryError(message: pendingError)
        }

        let statistics = ExecutionStatistics(duration: CFAbsoluteTimeGetCurrent() - start)

        // Nothing at all came back — not a command, not a result set. Nothing observed
        // reaches here, but a driver that grew a status we do not handle would.
        guard let latest else {
            return ExecutionOutcome(columns: [], store: .empty, statistics: statistics)
        }

        // Restated with the *run's* wall time rather than the last statement's, because
        // that is what this function has always returned and what the tile's stats line
        // reads. Each reported statement kept its own figure, which is the one a chip
        // wants — the two are different questions and now have different answers.
        return ExecutionOutcome(
            columns: latest.columns,
            store: latest.store,
            command: latest.command,
            statistics: statistics,
            delivery: latest.delivery
        )
    }

    /// Runs `query`, reporting rows early for the **first** statement only.
    ///
    /// The shape every existing caller has, preserved exactly: a caller holding one grid
    /// has nowhere to put a second statement's rows and cannot take back what it has
    /// already drawn.
    func execute(
        _ query: String,
        metaInfo: DbInfo,
        onPartial: (@Sendable (PartialResult) -> Void)?
    ) async throws -> ExecutionOutcome {
        guard let onPartial else { return try await execute(query, metaInfo: metaInfo, reporting: nil) }

        return try await execute(query, metaInfo: metaInfo) { event in
            guard case .partial(let index, let partial) = event, index == 0 else { return }

            onPartial(partial)
        }
    }

    /// Reads a `PGRES_COMMAND_OK` result's own account of itself.
    ///
    /// `PQcmdStatus` is the command tag verbatim — "UPDATE 3", "INSERT 0 5",
    /// "CREATE TABLE", and empty for `PGRES_EMPTY_QUERY`. The counts in it are stripped
    /// here rather than shown: an INSERT's tag carries an oid that is 0 on every modern
    /// server, so printing the tag whole would read as "INSERT 0 5".
    ///
    /// `PQcmdTuples` is the row count on its own, and is an empty string for statements
    /// that touch no rows — which is why it is parsed rather than defaulted, so DDL
    /// reports nothing instead of reporting zero.
    private static func makeCommandSummary(_ result: OpaquePointer?) -> CommandSummary {
        var status = ""
        if let cStatus = PQcmdStatus(result) {
            status = String(cString: cStatus)
        }

        var affectedRows: Int?
        if let cTuples = PQcmdTuples(result) {
            affectedRows = Int(String(cString: cTuples))
        }

        let tag = status.prefix { !$0.isNumber }.trimmingCharacters(in: .whitespaces)

        return .init(tag: tag.isEmpty ? nil : tag, affectedRows: affectedRows)
    }

    /// Build the column descriptors from any result that carries field metadata
    /// (a `PGRES_SINGLE_TUPLE` row or the terminal `PGRES_TUPLES_OK`).
    ///
    /// `PQftable` is what makes this connection's grid editable where ClickHouse's is
    /// not: Postgres names the table each column was selected from, as a `pg_class` oid,
    /// and that oid is what the catalog's primary keys are keyed by. An oid of 0 means
    /// the column is not a plain table reference — an expression, a literal, a function
    /// result — and a column with no owner is read-only downstream.
    private static func makeColumns(_ result: OpaquePointer?, metaInfo: DbInfo) -> [ColumnDescriptor] {
        let columnsCount = PQnfields(result)

        var columns: [ColumnDescriptor] = []
        columns.reserveCapacity(Int(columnsCount))

        for column in 0..<columnsCount {
            let tableOid = PQftable(result, column)
            let typeOid = PQftype(result, column)

            columns.append(
                ColumnDescriptor(
                    id: Int(column),
                    name: String(cString: PQfname(result, column)),
                    typeName: metaInfo.name(of: typeOid),
                    shape: metaInfo.shape(of: typeOid),
                    origin: tableOid == 0 ? nil : .handle(UInt64(tableOid))
                )
            )
        }

        return columns
    }

    func cancelQuery<Factory, Pool>(pool: Pool) async throws(QueryError) where PostgresConnection == Factory.C, Factory: ConnectionFactory, Pool: ConnectionPool<Factory> {
        guard let cancel = PQgetCancel(connection) else { return }

        defer { PQfreeCancel(cancel) }

        let bufferSize = 256
        let errbuf = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer { errbuf.deallocate() }

        // Best effort, and deliberately quiet on failure: the statement may have
        // finished between the user pressing stop and this arriving, which is not
        // something to report.
        _ = PQcancel(cancel, errbuf, Int32(bufferSize))
    }

}
