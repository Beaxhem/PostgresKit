//
//  DbInfo.swift
//  PostgresKit
//
//  Created by Illia Senchukov on 13.09.2024.
//

import Foundation
import CPostgres
import DataEngine

/// `pg_type`, read once when the connection opens.
///
/// A result names its columns' types by oid and nothing else, so without this every
/// column would be "some type numbered 1184". Fetched once rather than per query: the
/// catalog can gain a type while a connection is open, but a column of a type created
/// after the connection was made is rare enough to be worth one fewer round trip on
/// every statement.
public final class DbInfo: @unchecked Sendable {

    private(set) var typesByOid: [OId: PostgresType] = [:]

    /// The shape of the type numbered `oid`, or `.unknown` for one this connection has
    /// never heard of.
    func shape(of oid: OId) -> DataShape {
        typesByOid[oid]?.shape(resolving: typesByOid) ?? .unknown
    }

    /// The type's own name — `int8`, `jsonb`, `_text` — shown to the user and used to
    /// look up enum members in the catalog.
    func name(of oid: OId) -> String {
        typesByOid[oid]?.name ?? "unknown"
    }

}

extension DbInfo {

    func reload(connection: PostgresConnection) async throws(QueryError) {
        do {
            self.typesByOid = try await fetchTypes(connection: connection)
        } catch let error as QueryError {
            throw error
        } catch {
            throw .cancelled
        }
    }

}

private extension DbInfo {

    func fetchTypes(connection: PostgresConnection) async throws -> [OId: PostgresType] {
        // `typelem` comes along so an array can name its element type — the difference
        // between `int4[]` describing itself as a list of integers and as a list of
        // something unknown.
        let outcome = try await connection.execute(
            "SELECT oid, typname, typcategory, typelem FROM pg_type",
            metaInfo: self
        )

        var types: [OId: PostgresType] = [:]
        types.reserveCapacity(outcome.store.rowCount)

        for row in 0..<outcome.store.rowCount {
            guard let oidText = outcome.store.value(row: row, column: 0),
                  let oid = OId(oidText),
                  let name = outcome.store.value(row: row, column: 1),
                  let category = outcome.store.value(row: row, column: 2) else {
                continue
            }

            types[oid] = PostgresType(
                name: name,
                category: PostgresTypeCategory(rawValue: category) ?? .unknown,
                elementOid: outcome.store.value(row: row, column: 3).flatMap(OId.init) ?? 0
            )
        }

        return types
    }

}
