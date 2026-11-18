//
//  PostgresSSLModeTests.swift
//  PostgresKitTests
//

import Testing
import Foundation
import CPostgres
import DataEngine
@testable import PostgresKit

/// The SSL mode setting, and the libpq underneath it actually being able to honour it.
///
/// The second half is the one that matters. Until 2026-11-16 the vendored libpq had no
/// OpenSSL: `prefer` connected in the clear without a word, and `require` failed while
/// libpq was still parsing options. Both looked fine from Swift. ``libpqWasBuiltWithTLS``
/// is the check that would have caught it.
struct PostgresSSLModeTests {

    @Test func nothingStoredReadsAsPrefer() {
        #expect(PostgresSSLMode(settings: SettingsValues()) == .prefer)
    }

    @Test(arguments: PostgresSSLMode.allCases)
    func aStoredModeIsReadBack(_ mode: PostgresSSLMode) {
        #expect(PostgresSSLMode(settings: SettingsValues([.sslMode: mode.rawValue])) == mode)
    }

    /// A value the picker never offered — a hand-edited store, a mode removed later —
    /// falls back rather than reaching libpq, which would refuse the whole URI.
    @Test func anUnknownModeFallsBack() {
        #expect(PostgresSSLMode(settings: SettingsValues([.sslMode: "verify-full"])) == .prefer)
    }

    /// The picker's default is the reader's fallback, so a connection saved before the
    /// picker existed shows the mode it actually connects with.
    @Test func thePickerDefaultIsTheFallback() throws {
        guard case .choice(let options, let defaultValue) = PostgresSSLMode.field.kind else {
            Issue.record("SSL mode is not a choice field")
            return
        }

        #expect(defaultValue == PostgresSSLMode.fallback.rawValue)
        #expect(options.map(\.value) == PostgresSSLMode.allCases.map(\.rawValue))
    }

    @Test(arguments: PostgresSSLMode.allCases)
    func theModeReachesTheURI(_ mode: PostgresSSLMode) {
        let configuration = PostgresConfiguration(
            username: "u", password: "p", host: "localhost", port: 5432, database: nil, sslMode: mode
        )

        #expect(configuration.connectionString.contains("sslmode=\(mode.rawValue)"))
    }

    /// libpq checks `sslmode` against what it was compiled with before it opens a
    /// socket, so this needs no server: a libpq without TLS fails here with "sslmode
    /// value "require" invalid when SSL support is not compiled in", and one with TLS
    /// gets past option parsing to the (refused) TCP connect.
    ///
    /// Port 1 on loopback, so the connect fails at once and touches nothing.
    @Test func libpqWasBuiltWithTLS() {
        let conn = PQconnectdb("postgres://u:p@127.0.0.1:1/?sslmode=require&connect_timeout=2")
        defer { PQfinish(conn) }

        let message = String(cString: PQerrorMessage(conn))
        #expect(!message.contains("not compiled in"), "\(message)")
    }

}
