//
//  RedshiftTests.swift
//  PostgresKitTests
//

import Testing
import Foundation
import DataEngine
import DataEngineTestKit
@testable import PostgresKit

/// There is no Redshift to test against — AWS ships no container image, and a cluster
/// is not something a test suite can stand up. What *is* testable is everything that
/// isn't the cluster.
///
/// The wire is Postgres', so a Postgres server is a faithful stand-in for it: the
/// checks below open a real session carrying Redshift's capabilities and hold it to the
/// same conformance suite every other engine runs. That proves the part most likely to
/// be wrong — that declaring `.readOnly` actually stops writes — rather than assuming
/// it because the declaration reads correctly.
///
/// What it cannot prove is the SQL in `RedshiftProvider`, which reads `SVV_REDSHIFT_*`
/// views that exist on no other engine. Those are unverified until someone points this
/// at a cluster.
@Suite("Redshift")
struct RedshiftTests {

    // MARK: - Connection string

    /// The reason the URI is built rather than interpolated. AWS generates master
    /// passwords from a set that includes `@` and `/`, and an unescaped one of those
    /// moves the host boundary: libpq then reports that it cannot resolve a host made
    /// of the tail of the password, which is an error message nobody can act on.
    @Test func passwordPunctuationSurvivesTheUri() {
        let configuration = PostgresConfiguration(
            username: "aws user",
            password: "p@ss/w:rd?#",
            host: "cluster.example.com",
            port: 5439,
            database: "dev",
            sslMode: .require
        )

        let uri = configuration.connectionString

        #expect(uri == "postgres://aws%20user:p%40ss%2Fw%3Ard%3F%23@cluster.example.com:5439/dev?sslmode=require")

        // The host must appear exactly once — the failure mode being guarded is a second
        // `@` splitting the authority in the wrong place.
        #expect(uri.filter { $0 == "@" }.count == 1)
    }

    /// Postgres keeps libpq's own default, so nothing about existing connections moved
    /// when Redshift added the field.
    @Test func postgresStaysOnPrefer() {
        let configuration = PostgresConfiguration(
            username: "postgres",
            password: "secret",
            host: "localhost",
            port: 5432,
            database: "demo"
        )

        #expect(configuration.connectionString.hasSuffix("?sslmode=prefer"))
    }

    // MARK: - Settings

    @Test func settingsBuildAConfiguration() {
        let configuration = RedshiftEngine.configuration(
            for: SettingsValues([
                .host: "cluster.abc123.us-east-1.redshift.amazonaws.com",
                .database: "dev",
                .username: "awsuser",
                .password: "secret"
            ])
        )

        // The port is Redshift's, not Postgres', and it comes from the schema's declared
        // default rather than from a literal repeated at the call site.
        #expect(configuration.port == 5439)
        #expect(configuration.database == "dev")
        // TLS is on unless the connection says otherwise: a cluster reached over the
        // internet with `sslmode=prefer` will happily connect in the clear.
        #expect(configuration.sslMode == .require)
    }

    @Test func tlsCanBeTurnedOff() {
        let configuration = RedshiftEngine.configuration(
            for: SettingsValues([.host: "localhost", .database: "dev", .useTLS: "false"])
        )

        #expect(configuration.sslMode == .prefer)
    }

    /// A cluster is unreachable without a database, so the schema says so and
    /// `makeSession` refuses before libpq is handed a URI with an empty path.
    @Test func aMissingDatabaseIsRefusedByName() async {
        let engine = RedshiftEngine()

        do {
            _ = try await engine.makeSession(
                SettingsValues([.host: "cluster.example.com", .username: "awsuser"])
            )

            Issue.record("a connection with no database was accepted")
        } catch {
            #expect(error.message.contains("Database"))
        }
    }

    // MARK: - Capabilities

    /// The declaration this engine exists to make. Redshift takes `UPDATE` perfectly
    /// well; the app must not offer it, because Redshift's primary keys are advisory
    /// and a keyless match-every-column filter scans a columnar table whole.
    @Test func redshiftIsReadOnly() {
        let capabilities = EngineCapabilities.redshift

        #expect(capabilities.mutation == .readOnly)
        #expect(capabilities.mutation.kinds.isEmpty)
        #expect(!capabilities.mutation.allowsKeylessRows)
    }

    /// Not metered, deliberately. `.metered` puts a confirmation in front of every query
    /// and a cost estimate beside it, and Redshift can produce neither — it bills by the
    /// hour, and has no dry run to price a statement with.
    @Test func redshiftIsNotMetered() {
        #expect(EngineCapabilities.redshift.cost == .free)
        #expect(!EngineCapabilities.redshift.cost.isMetered)
    }

    /// Three tiers, unlike Postgres' two: Redshift's schemas are a level you descend
    /// into rather than a prefix folded into the table's name.
    @Test func catalogIsDatabaseThenSchema() {
        let catalog = RedshiftEngine().descriptor.catalog

        #expect(catalog.depth == 3)
        #expect(catalog.containers.map(\.singular) == ["Database", "Schema"])
        #expect(catalog.leaf.singular == "Table")
    }

}

// MARK: - Against a live server

/// Redshift's capabilities, held to the shared suite over a real Postgres socket.
///
/// Skips without a server, as the Postgres suite does — see `PostgresSessionTests` for
/// the `docker run` line.
@Suite("Redshift capabilities over the wire", .enabled(if: PostgresServer.isReachable))
struct RedshiftWireTests {

    /// The check worth having: a session declaring `.readOnly` must *refuse* a write,
    /// not merely decline to offer one in the UI. `EngineConformance` runs
    /// `readOnlyRefusesWrites` for exactly this shape of engine.
    @Test("the shared conformance suite passes with Redshift's capabilities")
    func conformance() async throws {
        let session = try await PostgresSession(
            configuration: PostgresServer.configuration,
            capabilities: .redshift
        )

        let report = await EngineConformance.run(session: session, fixture: .redshift)

        #expect(report.didPass, "\(report.summary)")
    }

    /// Spelled out rather than left to the suite, because this is the whole of the v1
    /// decision and it should fail by name if it regresses.
    @Test("a write is rejected before it reaches the server")
    func writesAreRefused() async throws {
        let session = try await PostgresSession(
            configuration: PostgresServer.configuration,
            capabilities: .redshift
        )

        do {
            _ = try await session.execute(sql: "CREATE TABLE qn_redshift_should_not_exist (id int)")

            Issue.record("a read-only session ran a CREATE TABLE")
        } catch {
            #expect(error.message.lowercased().contains("read-only"))
        }

        // And it really did not reach the server.
        let check = try await PostgresServer.session()
        let outcome = try await check.execute(
            sql: "SELECT count(*) FROM information_schema.tables WHERE table_name = 'qn_redshift_should_not_exist'"
        )

        #expect(outcome.store.value(row: 0, column: 0) == "0")
    }

}

private extension ConformanceFixture {

    /// The Postgres fixture with its write removed — a read-only engine is asked to
    /// reject that statement rather than run it, which is what
    /// `EngineConformance.readOnlyRefusesWrites` does with it.
    static let redshift = ConformanceFixture(
        read: { count in
            """
            SELECT i AS id,
                   i::text AS name,
                   CASE WHEN i %% 3 = 0 THEN NULL ELSE i::text END AS note
            FROM generate_series(1, \(count)) AS i
            """
            .replacingOccurrences(of: "%%", with: "%")
        },
        write: "CREATE TABLE IF NOT EXISTS qn_redshift_conformance (id int)",
        script: "SELECT 1; SELECT 2",
        invalid: "SELEKT 1",
        nullableColumnIndex: 2
    )

}
