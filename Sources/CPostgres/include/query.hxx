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
    bool isNull;
};

using Row = std::vector<Field>;

struct Column {
    std::string name;
    unsigned int table; // oid
};

struct QueryResult {
public:
    std::vector<Column> columns;
    std::vector<Row> rows;

    QueryResult(std::vector<Column> columns, std::vector<Row> rows);
};


const Result<QueryResult> query(Connection* connection, const char* query);
const Result<Row> queryOne(Connection* connection, const char* query);
