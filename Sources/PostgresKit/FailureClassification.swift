//
//  FailureClassification.swift
//  PostgresKit
//

import Foundation
import CPostgres
import DataEngine

/// Turns libpq's account of a failure into a ``FailureKind``.
///
/// Postgres is the engine where this can be done properly rather than by reading
/// English: every error the server generates carries a five-character SQLSTATE, the
/// classes are specified rather than conventional, and libpq hands it over on the
/// `PGresult` next to the message. So a dropped socket is `08006` and a typo is `42703`,
/// and nothing here has to match on prose to tell them apart.
///
/// The one place that is not true is the *startup* failure — see ``ofConnect(_:)``.
enum PostgresFailure {

    /// `PG_DIAG_SQLSTATE`, spelled out rather than imported.
    ///
    /// It is `#define PG_DIAG_SQLSTATE 'C'` in `postgres_ext.h`, and a character-literal
    /// macro is one of the shapes Swift's C importer declines to bring across. Writing
    /// the byte is not a workaround for a missing symbol so much as the same constant
    /// with one fewer thing that can go wrong at import time.
    private static let diagSqlState = Int32(UInt8(ascii: "C"))

    /// The kind of failure `result` represents, with `connection` as the fallback
    /// witness where the result carries no SQLSTATE.
    ///
    /// Both are needed. A result is the precise answer and is not always present — a
    /// `PQsendQuery` that never got onto the wire produces none — while the connection's
    /// status is always readable and only ever says *that* something is broken, never
    /// what.
    static func of(result: OpaquePointer?, connection: OpaquePointer) -> FailureKind {
        guard let result, let field = PQresultErrorField(result, diagSqlState) else {
            return of(connection: connection)
        }

        return of(sqlState: String(cString: field), connection: connection)
    }

    /// What the connection itself says, for the failures that produce no result.
    ///
    /// `CONNECTION_BAD` is definitive and is the whole point of consulting it: libpq
    /// latches it the moment it discovers the socket is unusable, so a send that failed
    /// because the server went away is distinguishable — without a message — from one
    /// that failed for any other reason.
    static func of(connection: OpaquePointer) -> FailureKind {
        PQstatus(connection) == CONNECTION_BAD ? .transport : .statement
    }

    /// Classifies a five-character SQLSTATE.
    ///
    /// Matched by class where the whole class means one thing and by code where it does
    /// not, which is how the specification is written and is why this reads unevenly.
    static func of(sqlState: String, connection: OpaquePointer? = nil) -> FailureKind {
        switch sqlState {
        // Cancelled on request — the answer to `PQcancel`, and the reason it is picked
        // out of class 57 rather than left to it. The user pressing stop is not a
        // transport failure and must not put the connection in question.
        case "57014":
            return .cancelled

        // The server is going away or will not have us: admin shutdown, crash shutdown,
        // cannot connect now (a standby still coming up). Transport rather than
        // statement, because what recovers them is reconnecting — later.
        case "57P01", "57P02", "57P03":
            return .transport

        // Too many connections, and the configuration limit beside it. A reconnect on a
        // backoff is exactly the right response, which is what makes these transport
        // despite being a resource condition rather than a broken socket.
        case "53300", "53400":
            return .transport

        default:
            break
        }

        switch sqlState.prefix(2) {
        // Class 08 — connection exception, entire. `08006` connection_failure,
        // `08003` connection_does_not_exist, `08P01` protocol_violation, and the rest.
        case "08":
            return .transport

        // Class 28 — invalid authorization specification, including `28P01`
        // invalid_password. Never automatically retried; see ``FailureKind/authentication``.
        case "28":
            return .authentication

        default:
            // An unrecognised SQLSTATE is a statement failure unless the connection has
            // meanwhile gone bad — which happens when the server reports an error and
            // then drops the link in the same breath.
            return connection.map(of(connection:)) ?? .statement
        }
    }

}

extension PostgresFailure {

    /// The kind of a failure to *open* a connection.
    ///
    /// This is the one case libpq gives nothing structured for. A startup failure has no
    /// `PGresult` and therefore no SQLSTATE; all there is, is `PQerrorMessage`, which is
    /// prose and is translated when the server's locale says so. So this matches on the
    /// untranslated spellings and is a heuristic, stated as one.
    ///
    /// Getting it wrong in the safe direction matters more than getting it right, and
    /// the safe direction is ``FailureKind/authentication`` — a connection wrongly
    /// called transport would be reconnected on a timer against a server rejecting the
    /// password, which is how an account gets locked out rather than recovered.
    ///
    /// What actually carries the weight here is not this function: it is the rule that
    /// nothing is ever reconnected automatically unless it connected successfully at
    /// least once. A password that was accepted an hour ago and is refused now is a far
    /// better candidate for "something else broke" than for "the credentials changed",
    /// and a password that was never accepted is not reconnected at all.
    static func ofConnect(_ connection: OpaquePointer?) -> FailureKind {
        guard let connection else { return .transport }

        let message = String(cString: PQerrorMessage(connection)).lowercased()

        let authenticationPhrases = [
            "authentication failed",
            "no password supplied",
            "password authentication",
            "role \"",
            "permission denied for database",
            "pg_hba.conf"
        ]

        if authenticationPhrases.contains(where: message.contains) {
            return .authentication
        }

        if message.contains("timeout expired") || message.contains("timed out") {
            return .timeout
        }

        return .transport
    }

}
