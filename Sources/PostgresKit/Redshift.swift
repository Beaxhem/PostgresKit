//
//  Redshift.swift
//  PostgresKit
//

import Foundation
import DataEngine

/// Amazon Redshift, which speaks the Postgres wire protocol.
///
/// The whole driver is this file, because there is no driver: Redshift accepts libpq
/// connections and answers them as Postgres does, so ``PostgresSession`` runs its
/// queries unmodified. What is genuinely different is everything *around* the wire —
/// what a connection may be asked to do, how deep its catalog goes, and which system
/// tables describe it — and none of that is protocol.
///
/// Kept in `PostgresKit` rather than a package of its own for the same reason: a
/// separate package would duplicate the `libpq` binary target to add one descriptor.
public struct RedshiftEngine: DatabaseEngine {

    public static let identifier: EngineIdentifier = "redshift"

    /// Redshift's own default, and not Postgres's — a cluster listens on 5439.
    public static let defaultPort = 5439

    public let descriptor: EngineDescriptor

    public init() {
        self.descriptor = EngineDescriptor(
            id: Self.identifier,
            displayName: "Redshift",
            badge: "RS",
            catalog: .databaseSchema,
            capabilities: .redshift,
            settings: SettingsSchema(sections: [
                .init("Cluster", fields: [
                    .init(
                        .host,
                        label: "Endpoint",
                        kind: .text(placeholder: "cluster.abc123.us-east-1.redshift.amazonaws.com"),
                        isRequired: true
                    ),
                    .init(.port, label: "Port", kind: .number(default: Self.defaultPort)),
                    // Required, unlike Postgres's: libpq can open a Postgres connection
                    // with no database and list the others from it, and Redshift has no
                    // equivalent — every connection is inside a database. `dev` is the
                    // one every cluster is created with.
                    .init(
                        .database,
                        label: "Database",
                        kind: .text(placeholder: "dev"),
                        isRequired: true,
                        help: "The database to connect to. Others on the cluster are still listed."
                    ),
                    .init(
                        .useTLS,
                        label: "Require TLS",
                        kind: .toggle(default: true),
                        help: "Clusters reject unencrypted connections unless configured otherwise."
                    )
                ]),
                .init("Authentication", fields: [
                    .init(.username, label: "User", kind: .text(placeholder: "awsuser"), isRequired: true),
                    .init(.password, label: "Password", kind: .secret)
                ])
            ]),
            executionModel: .blocking(poolSize: 3)
        )
    }

    public func makeSession(_ settings: SettingsValues) async throws(QueryError) -> any Session {
        try validate(settings)

        return try await PostgresSession(
            configuration: Self.configuration(for: settings),
            capabilities: .redshift
        )
    }

}

public extension RedshiftEngine {

    /// The libpq configuration these settings describe.
    static func configuration(for settings: SettingsValues) -> PostgresConfiguration {
        PostgresConfiguration(
            username: settings.string(.username, default: ""),
            password: settings.string(.password, default: ""),
            host: settings.string(.host, default: ""),
            port: Int16(settings.int(.port, default: defaultPort)),
            database: settings.string(.database),
            sslMode: settings.bool(.useTLS, default: true) ? .require : .prefer
        )
    }

}

public extension EngineCapabilities {

    /// What a Redshift connection can be asked to do.
    ///
    /// `.readOnly` by decision rather than by limitation — Redshift takes `UPDATE` and
    /// `DELETE` perfectly well. Two things make grid editing a bad offer on it. Its
    /// primary keys are *informational*: Redshift accepts a `PRIMARY KEY` declaration,
    /// reports it in `information_schema`, and does not enforce it, so a key the app
    /// trusted to name one row can name several. And a keyless fallback that matches
    /// every selected column is a full scan of a columnar table that is sized in
    /// terabytes. `.keyed` would still permit the first of those, so this is `.readOnly`.
    ///
    /// `.free` because Redshift is not metered per query the way BigQuery is — a
    /// provisioned cluster bills by the hour and serverless by RPU-second, neither of
    /// which is attributable to one statement, and there is no dry-run API to price one
    /// with. Declaring it `.metered` would demand a confirmation step in front of every
    /// query and a number this engine cannot produce to justify it.
    ///
    /// Everything else is Postgres's, because it *is* Postgres: the same simple-query
    /// message, so the same implicit per-request transaction, and the same out-of-band
    /// `PQcancel`.
    static let redshift = EngineCapabilities(
        mutation: .readOnly,
        scripting: .script,
        transactions: .implicitPerRequest,
        cancellation: .connection,
        cost: .free,
        identifierFolding: .lower
    )

}
