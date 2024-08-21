//
//  test.h
//  MyLibrary
//
//  Created by Illia Senchukov on 21.08.2024.
//

#include <iostream>
#include <pqxx/pqxx>

using std::chrono::high_resolution_clock;
using std::chrono::duration_cast;
using std::chrono::duration;
using std::chrono::milliseconds;

struct Field {
    pqxx::oid type;
    std::string_view value;
};

using Row = std::vector<Field>;

struct QueryResult {
    std::vector<Row> rows;
    std::vector<std::string_view> columns;
};

int main(int argc, char *argv[]) {
    try {
        pqxx::connection c("postgresql://illiasenchukov:@localhost:5432");

        pqxx::work w(c);
        std::vector<Row> results = {};

        auto t1 = high_resolution_clock::now();
        pqxx::result res = w.exec("SELECT * from netflix_shows");
        std::vector<Row> result = {};
        result.reserve(res.size());

        std::vector<std::string_view> columns;
        columns.reserve(res.size());

        for (int i = 0; i < res.columns(); ++i) {
            columns.emplace_back(res.column_name(i));
        }

        auto t2 = high_resolution_clock::now();

        for (pqxx::row r : res) {
            Row row = {};
            row.reserve(r.size());

            for (pqxx::field f : r) {
                row.emplace_back(f.type(), f.view());
            }

            result.emplace_back(std::move(row));
        }

        std::cout << "Columns: " << columns.size()  << '\n';
        std::cout << "Collected " << result.size() << " rows" << '\n';
        auto t3 = high_resolution_clock::now();


        // Commit your transaction.  If an exception occurred before this
        // point, execution will have left the block, and the transaction will
        // have been destroyed along the way.  In that case, the failed
        // transaction would implicitly abort instead of getting to this point.
        w.commit();

        auto exec_ms_int = duration_cast<milliseconds>(t2 - t1);
        auto mapping_ms_int = duration_cast<milliseconds>(t3 - t2);
        auto all_ms_int = duration_cast<milliseconds>(t3 - t1);

        std::cout << "Exec: " << exec_ms_int.count() << "ms\n";
        std::cout << "Mapping: " << mapping_ms_int.count() << "ms\n";
        std::cout << "All: " << all_ms_int.count() << "ms\n";

    } catch (std::exception const &e) {
        std::cerr << e.what() << std::endl;
        return 1;
    }

}
