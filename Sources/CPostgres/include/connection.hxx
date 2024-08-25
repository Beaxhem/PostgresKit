//
//  connection.hxx
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

#pragma once
#include <iostream>
#include <result.hxx>

struct Connection {
    void* connection;
    Connection(void* connection);
};

const Result<Connection> newConnection(const char* connectionString);
