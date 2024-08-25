//
//  result.hxx
//  PostgresAdapter
//
//  Created by Illia Senchukov on 23.08.2024.
//

#pragma once

#include <swift/bridging>
#include <variant>
#include <exception>
#include <string>
#include <type_traits>

struct Error {
    std::string message;

    Error(const std::string& msg) : message(msg) {}
    Error(const std::exception& ex) : message(ex.what()) {}
};

template <typename T>
struct Result {
private:
    std::optional<T> value;
    std::optional<Error> error;

public:
    Result(const T& value) {
        this->value = value;
    }
    Result(const Error& error) {
        this->error = error;
    }

    bool isSuccess() const {
        return value.has_value();
    }

    bool hasError() const {
        return error.has_value();
    }

    T getValue() const SWIFT_RETURNS_INDEPENDENT_VALUE {
        return value.value();
    }

    Error getError() const {
        return error.value();
    }
};

template <typename T, typename Func>
Result<T> runWithCatching(Func func) {
    try {
        return Result<T>(func());
    } catch (const std::exception& ex) {
        return Result<T>(Error(ex));
    } catch (...) {
        return Result<T>(Error("Unknown error"));
    }
}
