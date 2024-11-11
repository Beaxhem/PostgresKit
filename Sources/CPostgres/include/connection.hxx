//
//  connection.hxx
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

#pragma once

#include <iostream>
#include <result.hxx>
#include <pqxx/pqxx>

const Result<pqxx::connection*> newConnection(const char* connectionString);
