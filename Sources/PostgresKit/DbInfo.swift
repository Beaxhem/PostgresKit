//
//  DbInfo.swift
//  PostgresKit
//
//  Created by Illia Senchukov on 13.09.2024.
//

import Foundation
import CPostgres
import SqlAdapterKit

public class DbInfo: MetaInfo {

    let connection: Connection

    private(set) var oidToType: [OId: PostgresType] = [:]
    private(set) var oidToTable: [OId: PostgresTable] = [:]

    private var tables: [PostgresTable] = [] {
        didSet {
            oidToTable = tables.reduce(into: [:], { partialResult, table in
                partialResult[table.oid] = table
            })
        }
    }

    init(connection: Connection) {
        self.connection = connection
    }

    public func reload() async {
        await collect()
    }

}

extension DbInfo {

    func collect() async {
        do {
            self.oidToType = try fetchTypes()
            self.tables = try fetchTables()
        } catch {
            print("Couldn't collect db info: \(error.message)")
        }
    }

}

private extension DbInfo {

    func fetchTypes() throws (QueryError) -> [OId: PostgresType] {
        let result = try connection.query("select oid, typname, typcategory from pg_type")

        var typesInfo: [OId: PostgresType] = [:]
        typesInfo.reserveCapacity(result.rows.count)

        for row in result.rows {
            guard let oidString = row.data[0].value,
                  let typname = row.data[1].value,
                  let typcategoryString = row.data[2].value else {
                continue
            }

            let oid = OId(oidString) ?? 0
            let typeCategory = TypeCategory(rawValue: typcategoryString) ?? .unknown

            typesInfo[oid] = PostgresType(name: typname, category: typeCategory)
        }

        return typesInfo
    }

    func fetchTables() throws (QueryError) -> [PostgresTable] {
        let sqlQuery = """
with tables as (
    SELECT table_schema, table_name
    FROM information_schema.tables
    WHERE table_type = 'BASE TABLE' AND table_schema NOT IN ('pg_catalog', 'information_schema')
)
SELECT
    table_schema, table_name,
    CONCAT('"', table_schema, '"."', table_name, '"')::regclass::oid as oid
FROM tables
"""
        let result = try connection.query(sqlQuery)
        return result.rows.compactMap { row in
            guard row.data.count == 3,
                  let schema = row.data[0].value,
                  let name = row.data[1].value,
                  let oidString = row.data[2].value else {
                return nil
            }
            let oid = OId(oidString) ?? 0

            return PostgresTable(tableSchema: schema, name: name, oid: oid)
        }
    }

}
