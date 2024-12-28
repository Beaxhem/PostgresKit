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

    private var _oidToType: [OId: PostgresType] = [:]
    private var _oidToTable: [OId: Int] = [:]
    private var _tableToPrimaryKeyNames: [OId: Set<String>] = [:]

    var tables: [PostgresTable] = [] {
        didSet {
            _oidToTable = tables.enumerated().reduce(into: [:]) { (partialResult, arg1) in
                let (idx, table) = arg1
                partialResult[table.oid] = idx
            }
        }
    }

}

extension DbInfo {

    func reload(connection: Connection) async {
        do {
            self._oidToType = try fetchTypes(connection: connection)
            self._tableToPrimaryKeyNames = try fetchPrimaryKeys(connection: connection)
        } catch {
            print("Couldn't collect db info: \(error.message)")
        }
    }

}

extension DbInfo {

    func oidToTable(_ oid: OId) -> PostgresTable? {
        guard let idx = _oidToTable[oid] else { return nil }

        guard idx < tables.count else { return nil }

        return tables[idx]
    }

    func oidToType(_ oid: OId) -> PostgresType? {
        _oidToType[oid]
    }

    func oidToPrimaryKeys(_ oid: OId) -> Set<String>? {
        _tableToPrimaryKeyNames[oid]
    }

}

private extension DbInfo {

    func fetchTypes(connection: Connection) throws (QueryError) -> [OId: PostgresType] {
        let result = try connection.query("select oid, typname, typcategory from pg_type", metaInfo: self)

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

    func fetchPrimaryKeys(connection: Connection) throws(QueryError) -> [OId: Set<String>] {
        let sqlQuery = """
SELECT
    tc.table_name::regclass::oid, column_name
FROM 
    information_schema.table_constraints tc
JOIN 
    information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name
    AND tc.table_schema = kcu.table_schema
WHERE 
    tc.constraint_type = 'PRIMARY KEY'
"""
        let result = try connection.query(sqlQuery, metaInfo: self)

        var primaryKeysMap = [OId: Set<String>]()
        primaryKeysMap.reserveCapacity(result.rows.count)

        return result.rows.reduce(into: primaryKeysMap) { partialResult, row in
            guard row.data.count == 2,
                  let oidString = row.data[0].value,
                  let columnName = row.data[1].value else {
                return
            }
            let oid = OId(oidString) ?? 0

            partialResult[oid, default: []].insert(columnName)
        }
    }

}
