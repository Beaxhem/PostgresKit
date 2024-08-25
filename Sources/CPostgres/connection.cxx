//
//  connection.cxx
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

#include <connection.hxx>
#include <pqxx/pqxx>

Connection::Connection(void* connection) {
    this->connection = connection;
}

const Result<Connection*> newConnection(const char* connectionString) {
    try {
        auto connection = new Connection(static_cast<void*>(new pqxx::connection(connectionString)));
        return Result<Connection*>(connection);
    } catch (std::exception& ex) {
        return Result<Connection*>(Error(ex));
    } catch (...) {
        return Result<Connection*>(Error("Unknown error"));
    }
}

Connection::~Connection() {
    auto pqxx_connection = static_cast<pqxx::connection*>(connection);
    pqxx_connection->close();
    delete pqxx_connection;
}
