//
//  connection.hxx
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

#pragma once

#include <iostream>
#include <result.hxx>
#include <swift/bridging>

class Connection {
public:
    void* connection;
    size_t count = 0;

    Connection(void* connection);
    Connection(const Connection &) = delete;
    ~Connection();
} SWIFT_SHARED_REFERENCE(retainConnection, releaseConnection);

inline void retainConnection(Connection* connection) {
    connection->count++;
}

inline void releaseConnection(Connection* connection) {
    connection->count--;
    if (connection->count == 0) {
        delete connection;
    }
}

const Result<Connection*> newConnection(const char* connectionString);
