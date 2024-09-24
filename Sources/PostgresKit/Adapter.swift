//
//  Adapter.swift
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

import Foundation
import CPostgres
import SqlAdapterKit

public final class PostgresAdapter: SqlAdapter, Sendable {

    let connection: Connection

    init(connection: Connection) async {
        self.connection = connection
    }

    public static func connect(configuration: SqlAdapterKit.Configuration) async throws(QueryError) -> PostgresAdapter {
        let result = configuration.connectionString.withCString { pointer in
            CPostgres.newConnection(pointer)
        }
        guard !result.hasError() else {
            let error = result.getError()
            throw .init(message: String(error.message))
        }

        guard let connection = result.getValue() else {
            throw .init(message: "Internal error")
        }

        return await .init(connection: connection)
    }

    public func metaInfo() async throws(QueryError) -> any MetaInfo {
        let info = DbInfo(connection: connection)

        await info.collect()

        return info
    }

}

public extension PostgresAdapter {

    func query(_ query: String) throws(QueryError) -> SqlAdapterKit.QueryResult {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            print("Query took \(CFAbsoluteTimeGetCurrent() - start) seconds")
        }
        return try connection.query(query)
    }

    func table(for column: any SqlAdapterKit.Column, meta: MetaInfo?) -> (any SqlTable)? {
        guard let column = column as? PostgresColumn,
              let meta = meta as? DbInfo else {
            return nil
        }

        return meta.oidToTable[column.tableOid]
    }

    func fetchTables(meta: MetaInfo?) throws(QueryError) -> [any SqlTable] {
        guard let meta = meta as? DbInfo else { return [] }
        return Array(meta.oidToTable.values)
    }

}
