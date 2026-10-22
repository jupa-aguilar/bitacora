import Foundation
import SQLite3

public enum TextSource: String, Codable, Sendable {
    case accessibility
    case ocr
    case none
}

/// A frame about to be stored.
public struct NewFrame: Sendable {
    public var capturedAt: Date
    public var trigger: TriggerKind
    public var appName: String?
    public var bundleID: String?
    public var windowTitle: String?
    public var url: String?
    public var text: String
    public var textSource: TextSource
    public var imagePath: String?
    public var visualDifference: Double?

    public init(
        capturedAt: Date, trigger: TriggerKind, appName: String? = nil, bundleID: String? = nil,
        windowTitle: String? = nil, url: String? = nil, text: String, textSource: TextSource,
        imagePath: String? = nil, visualDifference: Double? = nil
    ) {
        self.capturedAt = capturedAt
        self.trigger = trigger
        self.appName = appName
        self.bundleID = bundleID
        self.windowTitle = windowTitle
        self.url = url
        self.text = text
        self.textSource = textSource
        self.imagePath = imagePath
        self.visualDifference = visualDifference
    }
}

public struct FrameRecord: Codable, Sendable {
    public let id: Int64
    public let capturedAt: Date
    public let trigger: String
    public let appName: String?
    public let bundleID: String?
    public let windowTitle: String?
    public let url: String?
    public let textSource: String
    public let imagePath: String?
    public let visualDifference: Double?
    /// Full text for single-frame lookups, or a highlighted excerpt in search results.
    public let text: String
}

public struct SearchQuery: Sendable {
    public var text: String
    public var app: String?
    public var from: Date?
    public var to: Date?
    public var limit: Int

    public init(text: String, app: String? = nil, from: Date? = nil, to: Date? = nil, limit: Int = 20) {
        self.text = text
        self.app = app
        self.from = from
        self.to = to
        self.limit = limit
    }

    /// Turns free text into a safe FTS5 expression: every word is quoted and matched as a prefix,
    /// so `reunión pres` finds "Reunion presupuesto" and user input can never inject FTS syntax.
    public static func ftsExpression(from text: String) -> String? {
        let tokens = text
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.replacingOccurrences(of: "\"", with: "\"\"") }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0)\"*" }.joined(separator: " ")
    }
}

public enum StorageError: Error, CustomStringConvertible {
    case sqlite(String)

    public var description: String {
        switch self {
        case .sqlite(let message): "SQLite: \(message)"
        }
    }
}

/// SQLite database with an FTS5 index over the captured text. Safe to share between threads.
public final class Storage: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    static let schemaVersion: Int32 = 1

    public init(path: String) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close(db)
            throw StorageError.sqlite(message)
        }
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA journal_mode = WAL;")
        try execute("PRAGMA foreign_keys = ON;")
        try migrate()
    }

    public static func inMemory() throws -> Storage {
        try Storage(path: ":memory:")
    }

    deinit {
        sqlite3_close(db)
    }

    private func migrate() throws {
        guard try userVersion() < Self.schemaVersion else { return }
        try execute("""
            CREATE TABLE IF NOT EXISTS frames (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                captured_at REAL NOT NULL,
                trigger TEXT NOT NULL,
                app_name TEXT,
                bundle_id TEXT,
                window_title TEXT,
                url TEXT,
                text TEXT NOT NULL DEFAULT '',
                text_source TEXT NOT NULL,
                image_path TEXT,
                visual_difference REAL
            );
            CREATE INDEX IF NOT EXISTS frames_captured_at ON frames(captured_at);
            CREATE INDEX IF NOT EXISTS frames_app_name ON frames(app_name);

            CREATE VIRTUAL TABLE IF NOT EXISTS frames_fts USING fts5(
                text, app_name, window_title,
                content = 'frames', content_rowid = 'id',
                tokenize = 'unicode61 remove_diacritics 2'
            );

            CREATE TRIGGER IF NOT EXISTS frames_ai AFTER INSERT ON frames BEGIN
                INSERT INTO frames_fts(rowid, text, app_name, window_title)
                VALUES (new.id, new.text, new.app_name, new.window_title);
            END;
            CREATE TRIGGER IF NOT EXISTS frames_ad AFTER DELETE ON frames BEGIN
                INSERT INTO frames_fts(frames_fts, rowid, text, app_name, window_title)
                VALUES ('delete', old.id, old.text, old.app_name, old.window_title);
            END;

            PRAGMA user_version = \(Self.schemaVersion);
            """)
    }

    // MARK: - Writes

    @discardableResult
    public func insert(_ frame: NewFrame) throws -> Int64 {
        try locked {
            let sql = """
                INSERT INTO frames (captured_at, trigger, app_name, bundle_id, window_title, url,
                                    text, text_source, image_path, visual_difference)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """
            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }
            bind(statement, 1, frame.capturedAt.timeIntervalSince1970)
            bind(statement, 2, frame.trigger.rawValue)
            bind(statement, 3, frame.appName)
            bind(statement, 4, frame.bundleID)
            bind(statement, 5, frame.windowTitle)
            bind(statement, 6, frame.url)
            bind(statement, 7, frame.text)
            bind(statement, 8, frame.textSource.rawValue)
            bind(statement, 9, frame.imagePath)
            bind(statement, 10, frame.visualDifference)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            return sqlite3_last_insert_rowid(db)
        }
    }

    // MARK: - Reads

    public func search(_ query: SearchQuery) throws -> [FrameRecord] {
        try locked {
            let limit = max(1, min(query.limit, 500))
            let statement: OpaquePointer?
            if let expression = SearchQuery.ftsExpression(from: query.text) {
                statement = try prepare("""
                    SELECT f.id, f.captured_at, f.trigger, f.app_name, f.bundle_id, f.window_title, f.url,
                           f.text_source, f.image_path, f.visual_difference,
                           snippet(frames_fts, 0, '«', '»', '…', 16)
                    FROM frames_fts JOIN frames f ON f.id = frames_fts.rowid
                    WHERE frames_fts MATCH ?1
                      AND (?2 IS NULL OR f.app_name = ?2 COLLATE NOCASE)
                      AND (?3 IS NULL OR f.captured_at >= ?3)
                      AND (?4 IS NULL OR f.captured_at <= ?4)
                    ORDER BY bm25(frames_fts)
                    LIMIT ?5;
                    """)
                bind(statement, 1, expression)
            } else {
                statement = try prepare("""
                    SELECT id, captured_at, trigger, app_name, bundle_id, window_title, url,
                           text_source, image_path, visual_difference, substr(text, 1, 200)
                    FROM frames
                    WHERE (?2 IS NULL OR app_name = ?2 COLLATE NOCASE)
                      AND (?3 IS NULL OR captured_at >= ?3)
                      AND (?4 IS NULL OR captured_at <= ?4)
                    ORDER BY captured_at DESC
                    LIMIT ?5;
                    """)
            }
            defer { sqlite3_finalize(statement) }
            bind(statement, 2, query.app)
            bind(statement, 3, query.from?.timeIntervalSince1970)
            bind(statement, 4, query.to?.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 5, Int64(limit))
            var results: [FrameRecord] = []
            while true {
                let rc = sqlite3_step(statement)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw lastError() }
                results.append(readRecord(statement))
            }
            return results
        }
    }

    public func frame(id: Int64) throws -> FrameRecord? {
        try locked {
            let statement = try prepare("""
                SELECT id, captured_at, trigger, app_name, bundle_id, window_title, url,
                       text_source, image_path, visual_difference, text
                FROM frames WHERE id = ?1;
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)
            switch sqlite3_step(statement) {
            case SQLITE_ROW: return readRecord(statement)
            case SQLITE_DONE: return nil
            default: throw lastError()
            }
        }
    }

    public func count() throws -> Int {
        try locked {
            let statement = try prepare("SELECT COUNT(*) FROM frames;")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    public func lastCaptureDate() throws -> Date? {
        try locked {
            let statement = try prepare("SELECT MAX(captured_at) FROM frames;")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
    }

    /// Number of frames per app, most captured first.
    public func framesPerApp(limit: Int = 10) throws -> [(app: String, count: Int)] {
        try locked {
            let statement = try prepare("""
                SELECT COALESCE(app_name, '?'), COUNT(*) FROM frames
                GROUP BY 1 ORDER BY 2 DESC LIMIT ?1;
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, Int64(limit))
            var rows: [(String, Int)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                rows.append((columnString(statement, 0) ?? "?", Int(sqlite3_column_int64(statement, 1))))
            }
            return rows
        }
    }

    // MARK: - Retention

    /// Frames captured before `date` that still reference a screenshot.
    public func framesWithImages(before date: Date) throws -> [(id: Int64, path: String)] {
        try locked {
            let statement = try prepare("""
                SELECT id, image_path FROM frames
                WHERE captured_at < ?1 AND image_path IS NOT NULL ORDER BY id;
                """)
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            var rows: [(Int64, String)] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let path = columnString(statement, 1) { rows.append((sqlite3_column_int64(statement, 0), path)) }
            }
            return rows
        }
    }

    /// Forgets the screenshot of these frames (their text stays indexed).
    public func clearImagePaths(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        try locked {
            try execute("BEGIN;")
            do {
                let statement = try prepare("UPDATE frames SET image_path = NULL WHERE id = ?1;")
                defer { sqlite3_finalize(statement) }
                for id in ids {
                    sqlite3_reset(statement)
                    sqlite3_bind_int64(statement, 1, id)
                    guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
                }
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        }
    }

    public func countFrames(before date: Date) throws -> Int {
        try locked {
            let statement = try prepare("SELECT COUNT(*) FROM frames WHERE captured_at < ?1;")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// Deletes frames (rows and search index entries) captured before `date`.
    @discardableResult
    public func deleteFrames(before date: Date) throws -> Int {
        try locked {
            let statement = try prepare("DELETE FROM frames WHERE captured_at < ?1;")
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
            return Int(sqlite3_changes(db))
        }
    }

    // MARK: - SQLite helpers

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(error)
            throw StorageError.sqlite(message)
        }
    }

    private func userVersion() throws -> Int32 {
        let statement = try prepare("PRAGMA user_version;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return sqlite3_column_int(statement, 0)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw lastError() }
        return statement
    }

    private func lastError() -> StorageError {
        StorageError.sqlite(String(cString: sqlite3_errmsg(db)))
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func bind(_ statement: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let value {
            sqlite3_bind_double(statement, index, value)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func columnString(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func columnDouble(_ statement: OpaquePointer?, _ index: Int32) -> Double? {
        sqlite3_column_type(statement, index) == SQLITE_NULL ? nil : sqlite3_column_double(statement, index)
    }

    private func readRecord(_ statement: OpaquePointer?) -> FrameRecord {
        FrameRecord(
            id: sqlite3_column_int64(statement, 0),
            capturedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            trigger: columnString(statement, 2) ?? "",
            appName: columnString(statement, 3),
            bundleID: columnString(statement, 4),
            windowTitle: columnString(statement, 5),
            url: columnString(statement, 6),
            textSource: columnString(statement, 7) ?? TextSource.none.rawValue,
            imagePath: columnString(statement, 8),
            visualDifference: columnDouble(statement, 9),
            text: columnString(statement, 10) ?? ""
        )
    }
}
