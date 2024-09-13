//
//  Adapter.swift
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

import Foundation
import CPostgres
import SqlAdapterKit

public final class PostgresAdapter: SqlAdapter {

    let connection: Connection

    private let info: DbInfo

    init(connection: Connection) async {
        self.connection = connection
        self.info = .init(connection: connection)

        await info.collect()
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

}

extension PostgresAdapter {

    public func query(_ query: String) throws(QueryError) -> SqlAdapterKit.QueryResult {
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            print("Query took \(CFAbsoluteTimeGetCurrent() - start) seconds")
        }
        return try connection.query(query)
    }

    public func table(for column: any SqlAdapterKit.Column) -> (any SqlTable)? {
        guard let column = column as? PostgresColumn else { return nil }

        return info.oidToTable[column.tableOid]
    }

    public func fetchTables() throws(QueryError) -> [any SqlTable] {
        Array(info.oidToTable.values)
    }

}
