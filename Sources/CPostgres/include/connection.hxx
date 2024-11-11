//
//  connection.hxx
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

#pragma once

#include <iostream>
#include <pqxx/pqxx>

#include "result.hxx"

const Result<pqxx::connection*> newConnection(const char* connectionString);
