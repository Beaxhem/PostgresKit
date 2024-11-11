//
//  query.cpp
//  MyLibrary
//
//  Created by Illia Senchukov on 21.08.2024.
//

#include "query.hxx"
#include <swift/bridging>
#include <stdexcept>

namespace postgres {

    const Result<PostgresQueryResult> query(pqxx::connection* connection, const char* query) SWIFT_RETURNS_INDEPENDENT_VALUE {
        try {
            pqxx::nontransaction w(*connection);

            pqxx::result result = w.exec(query);

            std::vector<PostgresRow> rows = {};
            rows.reserve(result.size());

            std::vector<PostgresColumn> columns;
            columns.reserve(result.columns());

            for (int column = 0; column < result.columns(); ++column) {
                std::string column_name = result.column_name(column);
                pqxx::oid table_oid = result.column_table(column);
                pqxx::oid type = result.column_type(column);

                columns.emplace_back(column_name, table_oid, type);
            }

            for (pqxx::row r : result) {
                PostgresRow row = {};
                row.reserve(r.size());

                for (pqxx::field f : r) {
                    row.emplace_back(std::string(f.view()), f.is_null());
                }

                rows.emplace_back(std::move(row));
            }

            w.commit();

            return Result<PostgresQueryResult>(PostgresQueryResult(columns, rows));
        } catch (std::exception const &e) {
            return Result<PostgresQueryResult>(Error(e));
        } catch (...) {
            return Result<PostgresQueryResult>(Error("Unknown error"));
        }
    }

    const Result<PostgresRow> queryOne(pqxx::connection* connection, const char* query) SWIFT_RETURNS_INDEPENDENT_VALUE {
        try {
            pqxx::work w(*connection);

            pqxx::row result = w.exec1(query);
            PostgresRow row = {};

            for (int column = 0; column < result.size(); column ++) {
                for (pqxx::field f : result) {
                    row.emplace_back(std::string(f.view()), f.is_null());
                }
            }
            w.commit();

            return Result<PostgresRow>(row);
        } catch (std::exception const &e) {
            return Result<PostgresRow>(Error(e));
        } catch (...) {
            return Result<PostgresRow>(Error("Unknown error"));
        }
    }

    PostgresQueryResult::PostgresQueryResult(std::vector<PostgresColumn> columns, std::vector<PostgresRow> rows) {
        this->columns = columns;
        this->rows = rows;
    }

}
