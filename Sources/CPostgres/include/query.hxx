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

struct Field {
    unsigned int type;
    std::string value;
};

using Row = std::vector<Field>;

struct QueryResult {
public:
    std::vector<std::string> columns;
    std::vector<Row> rows;

    QueryResult(std::vector<std::string> columns, std::vector<Row> rows);
};

const Result<QueryResult> query(Connection connection, const char* query);
