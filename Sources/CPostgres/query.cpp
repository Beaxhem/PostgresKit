//
//  query.cpp
//  MyLibrary
//
//  Created by Illia Senchukov on 21.08.2024.
//

#include "query.hxx"
#include <swift/bridging>
#include <stdexcept>

pqxx::connection* getConnection(Connection* connection) {
    return static_cast<pqxx::connection*>(connection->connection);
}

const Result<QueryResult> query(Connection* connection, const char* query) SWIFT_RETURNS_INDEPENDENT_VALUE {
    try {
        pqxx::connection* c = getConnection(connection);
        pqxx::work w(*c);

        pqxx::result result = w.exec(query);

        std::vector<Row> rows = {};
        rows.reserve(result.size());

        std::vector<Column> columns;
        columns.reserve(result.columns());

        for (int column = 0; column < result.columns(); ++column) {
            std::string column_name = result.column_name(column);
            pqxx::oid table_oid = result.column_table(column);

            columns.emplace_back(column_name, table_oid);
        }

        for (pqxx::row r : result) {
            Row row = {};
            row.reserve(r.size());

            for (pqxx::field f : r) {
                row.emplace_back(f.type(), std::string(f.view()), f.is_null());
            }

            rows.emplace_back(std::move(row));
        }

        w.commit();

        return Result<QueryResult>(QueryResult(columns, rows));
    } catch (std::exception const &e) {
        return Result<QueryResult>(Error(e));
    } catch (...) {
        return Result<QueryResult>(Error("Unknown error"));
    }
}

QueryResult::QueryResult(std::vector<Column> columns, std::vector<Row> rows) {
    this->columns = columns;
    this->rows = rows;
}
