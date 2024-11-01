//
//  query.hxx
//  MyLibrary
//
//  Created by Illia Senchukov on 21.08.2024.
//

#pragma once

#include <vector>
#include <iostream>
#include <pqxx/pqxx>
#include <connection.hxx>
#include <result.hxx>

namespace postgres {

    struct PostgresField {
        std::string value;
        bool isNull;
    };

    using PostgresRow = std::vector<PostgresField>;
    using oid = unsigned int;

    struct PostgresColumn {
        std::string name;
        oid table;
        oid type;
    };

    struct PostgresQueryResult {
    public:
        std::vector<PostgresColumn> columns;
        std::vector<PostgresRow> rows;

        PostgresQueryResult(std::vector<PostgresColumn> columns, std::vector<PostgresRow> rows);
    };


    const Result<PostgresQueryResult> query(Connection* connection, const char* query);
    const Result<PostgresRow> queryOne(Connection* connection, const char* query);

}
