//
//  connection.cxx
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

#include "connection.hxx"
#include <pqxx/pqxx>

const Result<pqxx::connection*> newConnection(const char* connectionString) {
    try {
        auto connection = new pqxx::connection(connectionString);
        return Result<pqxx::connection*>(connection);
    } catch (std::exception& ex) {
        return Result<pqxx::connection*>(Error(ex));
    } catch (...) {
        return Result<pqxx::connection*>(Error("Unknown error"));
    }
}
