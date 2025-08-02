//
//  DbInfo.swift
//  PostgresKit
//
//  Created by Illia Senchukov on 13.09.2024.
//

import Foundation
import CPostgres
import SqlAdapterKit

public final class DbInfo: @unchecked Sendable {
    private(set) var oidToType: [OId: PostgresType] = [:]
}

extension DbInfo {

    func reload(connection: PostgresConnection) async throws(QueryError) {
        do {
            self.oidToType = try await fetchTypes(connection: connection)
        } catch (let error as QueryError) {
            throw error
        } catch {
            throw .cancelled
        }
    }

}

private extension DbInfo {

    func fetchTypes(connection: PostgresConnection) async throws -> [OId: PostgresType] {
        let result = try await connection.query("select oid, typname, typcategory from pg_type", metaInfo: self)

        var typesInfo: [OId: PostgresType] = [:]
        typesInfo.reserveCapacity(result.rows.count)

        for row in result.rows {
            guard let oidString = row.data[0].value,
                  let typname = row.data[1].value,
                  let typcategoryString = row.data[2].value else {
                continue
            }

            let oid = OId(oidString) ?? 0
            let typeCategory = PostgresTypeCategory(rawValue: typcategoryString) ?? .unknown

            typesInfo[oid] = PostgresType(name: typname, category: typeCategory)
        }

        return typesInfo
    }

}
