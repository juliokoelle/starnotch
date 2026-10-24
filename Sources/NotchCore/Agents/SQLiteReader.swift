import Foundation
import SQLite3

/// A read-only SQLite connection (`mode=ro`): never writes, never creates, never migrates.
public final class SQLiteReader {
    private var db: OpaquePointer?

    public init?(path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var url = URLComponents()
        url.scheme = "file"
        url.path = path
        url.queryItems = [URLQueryItem(name: "mode", value: "ro")]
        guard let uri = url.string,
              sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 200)
    }

    deinit { sqlite3_close(db) }

    /// Column names of a table; empty when it doesn't exist.
    public func columns(of table: String) -> Set<String> {
        Set(rows("PRAGMA table_info(\(table))").compactMap { $0["name"] ?? nil })
    }

    /// Every row as column name → text (NULL as nil).
    public func rows(_ sql: String, _ arguments: [String] = []) -> [[String: String?]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, argument) in arguments.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), argument, -1, transient)
        }
        var result: [[String: String?]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            var row: [String: String?] = [:]
            for column in 0..<sqlite3_column_count(statement) {
                let name = String(cString: sqlite3_column_name(statement, column))
                row[name] = sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            result.append(row)
        }
        return result
    }
}
