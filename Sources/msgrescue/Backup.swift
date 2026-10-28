import Foundation
import SQLite3

enum RescueError: Error, CustomStringConvertible {
    case message(String)
    var description: String { if case .message(let m) = self { return m }; return "" }
}

/// Read-only access to an unencrypted Finder backup. Every file is stored flat
/// under its SHA-1 fileID; Manifest.db maps those back to device paths.
struct Backup {
    let root: URL
    let deviceName: String
    private let manifest: SQLiteDB

    static func locate(_ explicit: String?) throws -> Backup {
        let root: URL
        if let explicit {
            root = URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath)
        } else {
            let base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MobileSync/Backup")
            let found = (try? FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: nil)) ?? []
            let backups = found.filter { FileManager.default.fileExists(
                atPath: $0.appendingPathComponent("Manifest.db").path) }
            guard backups.count == 1 else {
                throw RescueError.message(backups.isEmpty
                    ? "No backup found in \(base.path)"
                    : "Several backups found, pick one with --backup:\n"
                        + backups.map(\.path).joined(separator: "\n"))
            }
            root = backups[0]
        }

        let manifestPlist = NSDictionary(contentsOf: root.appendingPathComponent("Manifest.plist"))
        if (manifestPlist?["IsEncrypted"] as? Bool) == true {
            throw RescueError.message("This backup is encrypted. Turn off encryption in Finder and back up again.")
        }
        let info = NSDictionary(contentsOf: root.appendingPathComponent("Info.plist"))
        let name = info?["Device Name"] as? String ?? "iPhone"

        return Backup(root: root, deviceName: name,
                      manifest: try SQLiteDB(readOnly: root.appendingPathComponent("Manifest.db")))
    }

    func url(forFileID id: String) -> URL {
        root.appendingPathComponent(String(id.prefix(2))).appendingPathComponent(id)
    }

    /// Regular files (flags = 1) in a domain whose device path matches a LIKE pattern.
    func files(domain: String, pathLike: String) throws -> [(path: String, id: String)] {
        var out: [(String, String)] = []
        try manifest.rows("""
            SELECT relativePath, fileID FROM Files
            WHERE flags = 1 AND domain = ? AND relativePath LIKE ?
            """, [domain, pathLike]) { row in
            out.append((row.string(0) ?? "", row.string(1) ?? ""))
        }
        return out
    }

    func fileID(domain: String, path: String) throws -> String? {
        var id: String?
        try manifest.rows("SELECT fileID FROM Files WHERE flags = 1 AND domain = ? AND relativePath = ?",
                          [domain, path]) { id = $0.string(0) }
        return id
    }
}

/// Minimal SQLite reader. Opened immutable so nothing is ever written next to
/// the backup, not even a -wal or -shm file.
final class SQLiteDB {
    private var handle: OpaquePointer?

    init(readOnly url: URL) throws {
        let uri = url.absoluteString + "?immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            throw RescueError.message("Could not open \(url.path)")
        }
    }

    deinit { sqlite3_close(handle) }

    struct Row {
        let stmt: OpaquePointer
        func string(_ i: Int32) -> String? {
            sqlite3_column_text(stmt, i).map { String(cString: $0) }
        }
        func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    }

    func rows(_ sql: String, _ args: [String] = [], _ body: (Row) -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw RescueError.message("SQL error: \(String(cString: sqlite3_errmsg(handle)))")
        }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, arg) in args.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), arg, -1, transient)
        }
        while sqlite3_step(stmt) == SQLITE_ROW { body(Row(stmt: stmt)) }
    }
}
