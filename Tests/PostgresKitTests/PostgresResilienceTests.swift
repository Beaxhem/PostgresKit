//
//  PostgresResilienceTests.swift
//  PostgresKitTests
//

import Testing
import Foundation
import DataEngine
import DataEngineTestKit
@testable import PostgresKit

/// What SQLSTATE means, decided without a server.
///
/// These are the mappings everything else rests on, and they are worth pinning
/// separately from the behaviour they drive: a wrong answer here is silent — the driver
/// keeps working, and the app simply stops recovering from the failure it misread.
@Suite("Postgres failure classification")
struct PostgresFailureTests {

    /// Class 08, entire. The connection-exception class is the reason SQLSTATE is worth
    /// reading at all: it says "the link is gone" in a way no message has to be parsed for.
    @Test(
        "class 08 is a transport failure",
        arguments: ["08000", "08003", "08006", "08001", "08004", "08007", "08P01"]
    )
    func connectionExceptions(state: String) {
        #expect(PostgresFailure.of(sqlState: state) == .transport)
    }

    /// Class 28. Never reconnected automatically — see ``FailureKind/authentication``.
    @Test("class 28 is authentication", arguments: ["28000", "28P01"])
    func authorization(state: String) {
        #expect(PostgresFailure.of(sqlState: state) == .authentication)
    }

    /// Picked out of class 57 by code rather than left to the class, because the rest of
    /// 57 is the server going away and this one is the user pressing stop. Filing it as
    /// transport would make every cancelled query look like a broken connection and
    /// trigger a reconnect.
    @Test("a cancelled query is not a transport failure")
    func cancellation() {
        #expect(PostgresFailure.of(sqlState: "57014") == .cancelled)
    }

    @Test("the server going away is transport", arguments: ["57P01", "57P02", "57P03"])
    func shutdown(state: String) {
        #expect(PostgresFailure.of(sqlState: state) == .transport)
    }

    /// A resource condition rather than a broken socket, and still transport — because
    /// what recovers it is reconnecting on a backoff, which is exactly what the transport
    /// path does.
    @Test("too many connections is transport")
    func saturation() {
        #expect(PostgresFailure.of(sqlState: "53300") == .transport)
    }

    /// The ordinary case, and the one that must not move: a statement the server refused
    /// leaves a healthy connection, and treating it otherwise means a reconnect per typo.
    @Test(
        "an ordinary SQL error is a statement failure",
        arguments: ["42703", "42601", "23505", "22P02", "42P01"]
    )
    func statementErrors(state: String) {
        #expect(PostgresFailure.of(sqlState: state) == .statement)
    }

}

@Suite("Postgres connection string")
struct PostgresConnectionStringTests {

    /// The parameters are the whole of the fix for a hung connect, so their presence is
    /// worth asserting rather than trusting: a typo in a libpq keyword is not an error,
    /// it is silently ignored.
    @Test("the defaults carry a connect timeout and keepalives")
    func defaults() {
        let string = PostgresConfiguration(
            username: "u", password: "p", host: "h", port: 5432, database: "d"
        ).connectionString

        #expect(string.contains("connect_timeout=10"))
        #expect(string.contains("keepalives=1"))
        #expect(string.contains("keepalives_idle=30"))
        #expect(string.contains("keepalives_interval=10"))
        #expect(string.contains("keepalives_count=3"))
    }

    @Test("resilience can be turned off entirely")
    func none() {
        let string = PostgresConfiguration(
            username: "u", password: "p", host: "h", port: 5432, database: "d",
            resilience: .none
        ).connectionString

        #expect(string.contains("keepalives=0"))
        #expect(!string.contains("keepalives_idle"))
    }

    /// The encoding fix that predates this change, re-asserted because the connection
    /// string is now assembled rather than interpolated in one piece.
    @Test("credentials are still encoded")
    func encoding() {
        let string = PostgresConfiguration(
            username: "u@x", password: "p/@:s", host: "h", port: 5432, database: "d"
        ).connectionString

        #expect(string.contains("u%40x"))
        #expect(string.contains("p%2F%40%3As"))
    }

}

/// Recovery, against a real server reached through a proxy that can break.
///
/// The proxy is what makes these possible — see ``DataEngineTestKit/FaultProxy``. libpq
/// talks to a socket and nothing else, so the only way to reach its failure paths is to
/// break the socket underneath it.
@Suite("Postgres resilience", .enabled(if: PostgresServer.isReachable))
struct PostgresResilienceTests {

    /// The connection nobody waits for.
    ///
    /// Without `connect_timeout` this is not a slow test, it is a *stuck* one: the
    /// handshake waits out the operating system's TCP patience, upwards of a minute, and
    /// it does so inside `PQconnectdb` where cancelling the Swift task neither ends it
    /// nor gives the thread back. Ten seconds is the setting; fifteen is the assertion,
    /// so a loaded machine does not fail it spuriously.
    @Test("a stalled handshake fails on the timeout, not the operating system's")
    func stalledHandshake() async throws {
        let proxy = try FaultProxy(
            forwardingTo: PostgresServer.configuration.host,
            port: PostgresServer.configuration.port
        )

        defer { proxy.stop() }

        proxy.fault = .stallHandshake

        var configuration = PostgresServer.configuration
        configuration.host = "127.0.0.1"
        configuration.port = proxy.port
        configuration.resilience = ConnectionResilience(connectTimeout: 3)

        let started = CFAbsoluteTimeGetCurrent()

        await #expect(throws: QueryError.self) {
            _ = try await PostgresSession(configuration: configuration)
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - started

        #expect(elapsed < 15, "the connect took \(elapsed)s — connect_timeout did not apply")
    }

    /// The promise the whole pool change exists to keep: a connection that died while
    /// nobody was looking costs a handshake, not an error.
    ///
    /// This is the shape of every sleep and every short VPN flap. The session is fine,
    /// the sockets under it are not, and the user should never learn that happened.
    @Test("a query after the connections were cut succeeds without a visible failure")
    func recoversFromCutConnections() async throws {
        let proxy = try FaultProxy(
            forwardingTo: PostgresServer.configuration.host,
            port: PostgresServer.configuration.port
        )

        defer { proxy.stop() }

        var configuration = PostgresServer.configuration
        configuration.host = "127.0.0.1"
        configuration.port = proxy.port

        let session = try await PostgresSession(configuration: configuration)

        let before = try await session.execute(sql: "SELECT 1")
        #expect(before.store.value(row: 0, column: 0) == "1")

        // Every socket dies, and nothing tells libpq — exactly what waking from sleep
        // leaves behind.
        proxy.cutLiveConnections()

        // The cut is asynchronous — `forceCancel` queues the reset rather than sending
        // it — so the socket needs a moment to actually become readable. Waiting is not
        // papering over a race in the product: every real version of this event (a sleep,
        // a VPN flap, a server restart) is seconds to minutes old by the time the next
        // query is typed. What the wait excludes is the *test* asking before the kernel
        // has been told.
        try await Task.sleep(for: .milliseconds(300))

        let after = try await session.execute(sql: "SELECT 2")

        #expect(after.store.value(row: 0, column: 0) == "2", "the pool handed out a dead connection")
    }

    /// A connection cut *mid-result* has to be reported, and reported as transport.
    ///
    /// Two ways to fail this and both are worse than an error. Reporting it as a
    /// statement failure means the app never reconnects; returning the rows that did
    /// arrive means the user is shown a short answer with nothing saying it is short.
    @Test("a connection cut mid-query is a transport failure, not a short result")
    func cutMidQueryIsTransport() async throws {
        let proxy = try FaultProxy(
            forwardingTo: PostgresServer.configuration.host,
            port: PostgresServer.configuration.port
        )

        defer { proxy.stop() }

        var configuration = PostgresServer.configuration
        configuration.host = "127.0.0.1"
        configuration.port = proxy.port

        let session = try await PostgresSession(configuration: configuration)

        // Warm the connection so the cut lands on an established socket rather than on
        // a handshake.
        _ = try await session.execute(sql: "SELECT 1")

        let query = Task {
            try await session.execute(sql: "SELECT pg_sleep(5), 1")
        }

        try await Task.sleep(for: .milliseconds(500))

        proxy.cutLiveConnections()

        do {
            _ = try await query.value

            Issue.record("the query returned a result over a connection that had been cut")
        } catch let error as QueryError {
            #expect(
                error.kind == .transport,
                "a cut connection was reported as \(error.kind): \(error.message)"
            )
        }
    }

    /// The other half of the classification, proven against the server rather than
    /// against a table of SQLSTATEs: an ordinary mistake must not put the connection in
    /// question, or the app reconnects on every typo.
    @Test("a syntax error is a statement failure and the session survives it")
    func syntaxErrorIsStatement() async throws {
        let session = try await PostgresServer.session()

        do {
            _ = try await session.execute(sql: "SELECT * FROM a_table_that_is_not_there")

            Issue.record("the query should have failed")
        } catch let error as QueryError {
            #expect(error.kind == .statement)
        }

        let outcome = try await session.execute(sql: "SELECT 1")

        #expect(outcome.store.value(row: 0, column: 0) == "1")
    }

    /// A rejected password must never be called transport, because transport is the one
    /// kind the app reconnects on its own — and reconnecting into a rejection on a timer
    /// is how an account gets locked out.
    @Test("a rejected password is an authentication failure")
    func rejectedPassword() async throws {
        var configuration = PostgresServer.configuration
        configuration.password = "definitely-not-the-password-\(UUID().uuidString)"
        configuration.username = "qn_no_such_user"

        do {
            _ = try await PostgresSession(configuration: configuration)

            Issue.record("the connection should have been refused")
        } catch {
            #expect(
                error.kind == .authentication,
                "a refused login was reported as \(error.kind): \(error.message)"
            )
        }
    }

}
