//
//  Adapter.swift
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

import Foundation
import CPostgres
import ConnectionPool
import DataEngine

/// What libpq should do about TLS.
///
/// Only the two values that are actually chosen between here. `prefer` is libpq's own
/// default — encrypt if the server offers it, connect anyway if it does not — and
/// `require` refuses to connect in the clear, which is what a managed cluster reached
/// over the internet needs.
public enum PostgresSSLMode: String, Sendable {

    case prefer
    case require

}

public struct PostgresConfiguration: Sendable {

    public var username: String
    public var password: String
    public var host: String
    public var port: UInt16
    public var database: String?
    public var sslMode: PostgresSSLMode

    /// The libpq connection URI.
    ///
    /// User and password are percent-encoded, which they were not before Redshift
    /// arrived and found the gap: a password containing `@` or `/` — which AWS hands out
    /// routinely — silently reshaped the URI, so libpq parsed part of the password as a
    /// host and reported a connection failure naming a host nobody typed.
    public var connectionString: String {
        let user = Self.encode(username)
        let secret = Self.encode(password)

        return "postgres://\(user):\(secret)@\(host):\(port)/\(database ?? "")?sslmode=\(sslMode.rawValue)"
    }

    public init(
        username: String,
        password: String,
        host: String,
        port: UInt16,
        database: String?,
        sslMode: PostgresSSLMode = .prefer
    ) {
        self.username = username
        self.password = password
        self.host = host
        self.port = port
        self.database = database
        self.sslMode = sslMode
    }

    /// Percent-encodes one URI component. `urlUserAllowed` still permits the
    /// sub-delimiters, so `:` and `@` — the two that actually break the parse — are the
    /// ones this escapes.
    private static func encode(_ component: String) -> String {
        component.addingPercentEncoding(withAllowedCharacters: .postgresURIComponent) ?? component
    }

}

private extension CharacterSet {

    static let postgresURIComponent = CharacterSet.alphanumerics.union(.init(charactersIn: "-._~"))

}

struct PostgresConnectionFactory: ConnectionFactory {

    let configuration: PostgresConfiguration

    func connect() throws(QueryError) -> PostgresConnection {
        let connection = PQconnectdb(configuration.connectionString)
        if PQstatus(connection) != CONNECTION_OK {
            defer { PQfinish(connection) }

            throw .init(message: String(cString: PQerrorMessage(connection)))
        }

        return .init(connection: connection!)
    }

}

/// A connection to a Postgres server.
///
/// Migrated off `SqlAdapter` onto ``DataEngine/Session``. What changed is the shape of
/// what it hands back — ``ColumnDescriptor`` rather than an existential `Column`, an
/// ``ExecutionOutcome`` rather than a `QueryResult` — and, with it, that the driver now
/// says what a column *is* rather than which of a fixed list of categories it falls in:
/// `jsonb` arrives as a composite, `int4[]` as a list of integers.
///
/// What deliberately did not change is the pool. `ConnectionPool.withCancellableConnection`
/// already gets the hard part right — a cancelled statement sends `PQcancel` on a live
/// connection and then *drops* that connection rather than returning it to the buffer,
/// so a later borrower cannot inherit a pending cancellation. Rewriting that as part of
/// a type migration would have risked the one piece of this driver whose failure mode is
/// silent.
public final actor PostgresSession: Session {

    public nonisolated let capabilities: EngineCapabilities

    private let pool: ConnectionPool<PostgresConnectionFactory>

    private let metaInfo = DbInfo()

    public init(
        configuration: PostgresConfiguration,
        capabilities: EngineCapabilities = .postgres
    ) async throws(QueryError) {
        self.capabilities = capabilities
        self.pool = try await .init(factory: .init(configuration: configuration))

        try await pool.withConnection { (connection: PostgresConnection) throws(QueryError) in
            try await metaInfo.reload(connection: connection)
        }
    }

}

public extension PostgresSession {

    func execute(
        _ request: QueryRequest,
        onPartial: (@Sendable (PartialResult) -> Void)?
    ) async throws(QueryError) -> ExecutionOutcome {
        try validate(request)

        guard let sql = request.sql else {
            throw QueryError(message: "This connection only runs SQL.")
        }

        return try await pool.withCancellableConnection { connection throws(QueryError) in
            do {
                return try await connection.execute(sql, metaInfo: metaInfo, onPartial: onPartial)
            } catch let error as QueryError {
                throw error
            } catch {
                throw .cancelled
            }
        }
    }

    /// Cancellation is `.connection`, not `.token`: Postgres cancels over a side channel
    /// tied to the connection running the statement, so there is no id to address and
    /// nothing for this to do. The pool sends `PQcancel` from its own cancellation
    /// handler, which is the only place that still holds the right connection.
    func cancel(_ handle: ExecutionHandle) async {}

}

public extension EngineCapabilities {

    /// What a Postgres connection can be asked to do.
    ///
    /// `.unrestricted` because Postgres reports the table behind each column as a
    /// `pg_class` oid, so a row can be identified — and where a table declares no
    /// primary key, matching every selected column is a filter this engine can run
    /// cheaply on the table sizes people keep in it.
    ///
    /// `.implicitPerRequest`, which is a statement about the protocol rather than about
    /// the server: everything in one simple-query message runs in one implicit
    /// transaction, committed when the message completes and rolled back entirely if any
    /// statement in it fails. `execute` sends the whole request in a single
    /// `PQsendQuery`, so an atomic request is already atomic and this driver adds
    /// nothing. Adding a `BEGIN` anyway would break it: a script that failed halfway
    /// would never reach its `COMMIT`, and the pool would take the connection back with
    /// a transaction still open on it.
    static let postgres = EngineCapabilities(
        mutation: .unrestricted(.all),
        scripting: .script,
        transactions: .implicitPerRequest,
        cancellation: .connection,
        identifierFolding: .lower
    )

}
