//
//  PostgresSessionTests.swift
//  PostgresKitTests
//

import Testing
import Foundation
import DataEngine
import DataEngineTestKit
@testable import PostgresKit

/// Postgres has no fake transport — it is libpq talking to a socket — so these need a
/// server and skip without one:
///
/// ```
/// docker run -d --name qn-postgres -p 15432:5432 \
///   -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=demo postgres:16
/// ```
///
/// Override with `POSTGRES_TEST_HOST` / `POSTGRES_TEST_PORT` / `POSTGRES_TEST_PASSWORD`.
@Suite("Postgres session", .enabled(if: PostgresServer.isReachable))
struct PostgresSessionTests {

    /// The property that separates this driver from ClickHouse's, and the reason the
    /// migration could have quietly broken editing: Postgres reports the `pg_class` oid
    /// of the table behind each column, and that oid is what the catalog's primary keys
    /// are keyed by. Lose it and every grid silently becomes read-only.
    @Test("a column from a table carries its table's oid")
    func columnOrigin() async throws {
        let session = try await PostgresServer.session()

        _ = try await session.execute(sql: "DROP TABLE IF EXISTS qn_origin")
        _ = try await session.execute(sql: "CREATE TABLE qn_origin (id int primary key, name text)")
        _ = try await session.execute(sql: "INSERT INTO qn_origin VALUES (1, 'a')")

        let expected = try await PostgresServer.oid(of: "qn_origin", session: session)
        let outcome = try await session.execute(sql: "SELECT id, name, 1 + 1 AS computed FROM qn_origin")

        #expect(outcome.columns[0].origin == .handle(UInt64(expected)))
        #expect(outcome.columns[1].origin == .handle(UInt64(expected)))
        // An expression has no backing table, and a column with no owner is read-only
        // downstream — which is correct, not a loss.
        #expect(outcome.columns[2].origin == nil)

        _ = try await session.execute(sql: "DROP TABLE qn_origin")
    }

    /// The migration's visible gain. Under the old flat `TypeCategory`, `jsonb` and
    /// `int4[]` both collapsed to "user-defined" or a bare array; the driver now says
    /// what they are, so the grid can offer an inspector rather than a text field.
    @Test("types describe themselves properly")
    func shapes() async throws {
        let session = try await PostgresServer.session()

        let outcome = try await session.execute(
            sql: """
            SELECT 1::int4        AS an_int,
                   1.5::numeric   AS a_decimal,
                   1.5::float8    AS a_float,
                   true           AS a_bool,
                   'x'::text      AS some_text,
                   'x'::varchar   AS a_varchar,
                   now()          AS a_timestamptz,
                   now()::date    AS a_date,
                   '{}'::jsonb    AS some_json,
                   '{1,2}'::int4[] AS an_int_array,
                   '\\x00'::bytea  AS a_blob,
                   gen_random_uuid() AS an_id
            """
        )

        let shapes = Dictionary(uniqueKeysWithValues: outcome.columns.map { ($0.name, $0.shape) })

        #expect(shapes["an_int"] == .scalar(.integer))
        #expect(shapes["a_decimal"] == .scalar(.decimal))
        #expect(shapes["a_float"] == .scalar(.float))
        #expect(shapes["a_bool"] == .scalar(.boolean))
        #expect(shapes["some_text"] == .scalar(.text))
        #expect(shapes["a_varchar"] == .scalar(.text))
        #expect(shapes["a_timestamptz"] == .scalar(.timestampWithZone))
        #expect(shapes["a_date"] == .scalar(.date))
        #expect(shapes["a_blob"] == .scalar(.binary))
        #expect(shapes["an_id"] == .scalar(.uuid))

        // `jsonb` is category "U" — user-defined — in the catalog. Reading only the
        // category renders a JSON document, a blob and a UUID identically.
        #expect(shapes["some_json"] == .variant)

        // An array names its element type through `typelem`, so this is a list *of
        // integers* rather than a list of something unknown.
        #expect(shapes["an_int_array"] == .list(.scalar(.integer)))
    }

    @Test("NULL, empty string and a value stay three different things")
    func nulls() async throws {
        let session = try await PostgresServer.session()

        let outcome = try await session.execute(
            sql: "SELECT NULL::text AS a, ''::text AS b, 'x'::text AS c"
        )

        #expect(outcome.store.field(row: 0, column: 0).isNull)
        #expect(!outcome.store.field(row: 0, column: 1).isNull)
        #expect(outcome.store.field(row: 0, column: 1).value == "")
        #expect(outcome.store.field(row: 0, column: 2).value == "x")
    }

    /// Postgres takes scripts, and the *last* statement is the answer — a trailing
    /// command beats an earlier SELECT.
    @Test("a script reports its last statement")
    func scripts() async throws {
        let session = try await PostgresServer.session()

        let selectLast = try await session.execute(sql: "SELECT 1 AS a; SELECT 2 AS b")
        #expect(selectLast.columns.map(\.name) == ["b"])

        _ = try await session.execute(sql: "DROP TABLE IF EXISTS qn_script")

        let commandLast = try await session.execute(
            sql: "SELECT 1; CREATE TABLE qn_script (id int)"
        )
        #expect(commandLast.isCommand)
        #expect(commandLast.command?.tag == "CREATE TABLE")

        _ = try await session.execute(sql: "DROP TABLE qn_script")
    }

    /// A write says what it did. DDL reports no row count at all rather than zero —
    /// "changed nothing" and "not applicable" are different claims.
    @Test("commands report a tag, and a row count only where there is one")
    func commands() async throws {
        let session = try await PostgresServer.session()

        _ = try await session.execute(sql: "DROP TABLE IF EXISTS qn_cmd")

        let ddl = try await session.execute(sql: "CREATE TABLE qn_cmd (id int)")
        #expect(ddl.command?.tag == "CREATE TABLE")
        #expect(ddl.command?.affectedRows == nil)

        let insert = try await session.execute(sql: "INSERT INTO qn_cmd VALUES (1), (2), (3)")
        #expect(insert.command?.tag == "INSERT")
        #expect(insert.command?.affectedRows == 3)

        let update = try await session.execute(sql: "UPDATE qn_cmd SET id = id WHERE id > 99")
        #expect(update.command?.affectedRows == 0)

        _ = try await session.execute(sql: "DROP TABLE qn_cmd")
    }

    @Test("a rejected statement keeps the server's message")
    func errors() async throws {
        let session = try await PostgresServer.session()

        do {
            _ = try await session.execute(sql: "SELEKT 1")

            Issue.record("the server accepted nonsense")
        } catch {
            #expect(error.message.lowercased().contains("syntax"))
        }
    }

    /// Single-row mode is what keeps peak memory to the arena plus one driver-owned row
    /// rather than the arena plus a second full copy — and it is what lets rows reach
    /// the grid before the query ends.
    @Test("a large scan streams")
    func streaming() async throws {
        let session = try await PostgresServer.session()
        let partials = Counter()

        let outcome = try await session.execute(
            QueryRequest(sql: "SELECT i, i::text FROM generate_series(1, 400000) AS i")
        ) { partial in
            partials.record(partial.store.rowCount)
        }

        #expect(outcome.rowCount == 400_000)

        let seen = partials.counts

        #expect(!seen.isEmpty, "400k rows arrived with no intermediate publication")
        #expect(zip(seen, seen.dropFirst()).allSatisfy { $0 < $1 }, "publications were not monotonic")
        #expect(seen.allSatisfy { $0 <= outcome.rowCount })
    }

    /// `.connection` cancellation: the pool sends `PQcancel` over Postgres' side channel
    /// and then drops the connection rather than returning it, so a later borrower
    /// cannot inherit a pending cancellation. Verified by asking the server, because a
    /// client that merely stopped waiting looks identical from here.
    @Test("cancelling actually stops the query server-side")
    func cancellation() async throws {
        let session = try await PostgresServer.session()

        let marker = "qn_cancel_\(UUID().uuidString.prefix(8))"
        let sql = "SELECT count(*) FROM generate_series(1, 20000000000) AS i WHERE i::text <> '\(marker)'"

        let running = Task { try await session.execute(sql: sql) }

        var started = false
        for _ in 0..<40 where !started {
            try await Task.sleep(for: .milliseconds(250))
            started = try await PostgresServer.isRunning(marker: marker)
        }

        #expect(started, "the query never reached the server")

        running.cancel()

        var stopped = false
        for _ in 0..<40 where !stopped {
            try await Task.sleep(for: .milliseconds(250))
            stopped = try await !PostgresServer.isRunning(marker: marker)
        }

        #expect(stopped, "the query was still running on the server after cancelling")
    }

    /// The suite every engine is held to. Postgres is the first to run it with mutations
    /// actually permitted, so the write and command checks are live rather than skipped.
    @Test("the shared conformance suite passes")
    func conformance() async throws {
        let session = try await PostgresServer.session()

        let report = await EngineConformance.run(session: session, fixture: .postgres)

        #expect(report.didPass, "\(report.summary)")
    }

}

private extension ConformanceFixture {

    static let postgres = ConformanceFixture(
        // `note` is NULL on every third row, which the NULL check needs.
        read: { count in
            """
            SELECT i AS id,
                   i::text AS name,
                   CASE WHEN i %% 3 = 0 THEN NULL ELSE i::text END AS note
            FROM generate_series(1, \(count)) AS i
            """
            .replacingOccurrences(of: "%%", with: "%")
        },
        write: "CREATE TABLE IF NOT EXISTS qn_conformance (id int)",
        script: "SELECT 1; SELECT 2",
        invalid: "SELEKT 1",
        nullableColumnIndex: 2
    )

}

// MARK: - Server

enum PostgresServer {

    static var configuration: PostgresConfiguration {
        let environment = ProcessInfo.processInfo.environment

        return PostgresConfiguration(
            username: environment["POSTGRES_TEST_USER"] ?? "postgres",
            password: environment["POSTGRES_TEST_PASSWORD"] ?? "secret",
            host: environment["POSTGRES_TEST_HOST"] ?? "localhost",
            port: Int16(environment["POSTGRES_TEST_PORT"] ?? "15432") ?? 15432,
            database: environment["POSTGRES_TEST_DB"] ?? "demo"
        )
    }

    /// Decided once, synchronously, because `.enabled(if:)` runs before the test does.
    static let isReachable: Bool = {
        let semaphore = DispatchSemaphore(value: 0)
        let reachable = Box()

        Task {
            reachable.value = (try? await PostgresSession(configuration: configuration)) != nil
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 10)

        return reachable.value
    }()

    static func session() async throws -> PostgresSession {
        try await PostgresSession(configuration: configuration)
    }

    static func oid(of table: String, session: PostgresSession) async throws -> UInt32 {
        let outcome = try await session.execute(sql: "SELECT '\(table)'::regclass::oid")

        return UInt32(outcome.store.value(row: 0, column: 0) ?? "0") ?? 0
    }

    /// Whether a query carrying `marker` is still in flight, asked of `pg_stat_activity`
    /// on a *separate* connection — the one running it is busy by definition.
    static func isRunning(marker: String) async throws -> Bool {
        let session = try await Self.session()

        let outcome = try await session.execute(
            sql: """
            SELECT count(*) FROM pg_stat_activity
            WHERE query LIKE '%\(marker)%'
              AND query NOT LIKE '%pg_stat_activity%'
              AND state = 'active'
            """
        )

        return (Int(outcome.store.value(row: 0, column: 0) ?? "0") ?? 0) > 0
    }

    private final class Box: @unchecked Sendable {
        var value = false
    }

}

private final class Counter: @unchecked Sendable {

    private let lock = NSLock()

    private var rows: [Int] = []

    func record(_ count: Int) {
        lock.withLock { rows.append(count) }
    }

    var counts: [Int] { lock.withLock { rows } }

}
