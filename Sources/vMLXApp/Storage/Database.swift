import Foundation
import SQLite3

/// Minimal SQLite wrapper for sessions + messages. Uses the system `libsqlite3`
/// so we pick up zero third-party dependencies — important for App Store review
/// (fewer SBOM entries, no license audits, no transitive code). GRDB would have
/// been nicer ergonomically but adds a package and a larger binary surface, and
/// our query set here is tiny.
///
/// Storage location: `~/Library/Application Support/vMLX/vmlx.sqlite3`
/// WAL mode enabled to match the Electron app.
@MainActor
final class Database {
    static let shared = Database()

    /// Serialized composer state for a session.  Keeping this beside the
    /// conversation database (rather than in memory or UserDefaults) makes
    /// unsent text, media, and extracted document context recoverable after a
    /// quit or crash without imposing size limits on the draft.
    struct ChatDraftPayload: Codable, Equatable {
        var inputText: String
        var pendingImages: [Data]
        var pendingVideoPaths: [String]
        var pendingDocuments: [ChatDocumentAttachment]

        var isEmpty: Bool {
            inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && pendingImages.isEmpty
                && pendingVideoPaths.isEmpty
                && pendingDocuments.isEmpty
        }
    }

    private var db: OpaquePointer?

    private init() {
        open()
        migrate()
    }

    deinit {
        if db != nil { sqlite3_close(db) }
    }

    private func open() {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["MLX_STUDIO_CHAT_DB_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty
        {
            let url = URL(fileURLWithPath: override).standardizedFileURL
            try? fm.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if sqlite3_open(url.path, &db) != SQLITE_OK {
                NSLog("vMLX: sqlite3_open failed at E2E override \(url.path)")
            }
            configureConnection()
            return
        }
        let appSup = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
        let dir = (appSup ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("vMLX", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("vmlx.sqlite3").path
        if sqlite3_open(path, &db) != SQLITE_OK {
            NSLog("vMLX: sqlite3_open failed at \(path)")
        }
        configureConnection()
    }

    private func configureConnection() {
        runSQL("PRAGMA journal_mode=WAL;")
        runSQL("PRAGMA foreign_keys=ON;")
        // Iter-28: `synchronous=NORMAL` is the SQLite-documented
        // partner to WAL mode. Default is FULL which fsync's every
        // commit — on the streaming chat path we upsertMessage every
        // token, so 435 tok/s on Llama-1B was 435 fsyncs/sec of the
        // WAL file. NORMAL keeps full durability within the last ~1s
        // (WAL checkpoints to the main DB file), which for chat
        // history data is plenty. Losing the last half-second of
        // streaming text on a power-cut is a trivially acceptable
        // tradeoff; losing it already happens because MLX state is
        // non-persisted anyway. See SQLite docs:
        // https://www.sqlite.org/pragma.html#pragma_synchronous
        runSQL("PRAGMA synchronous=NORMAL;")
        // Bigger cache (default 2MB → 32MB) — chat messages table
        // fits entirely in RAM for any practical history, so reads
        // stop hitting the page cache on session-switch. Negative
        // value means KiB; `-32000` == 32 MB.
        runSQL("PRAGMA cache_size=-32000;")
        // Temp tables in RAM instead of disk. Relevant for
        // transactions + group-by queries that SQLite materializes.
        runSQL("PRAGMA temp_store=MEMORY;")
    }

    private func migrate() {
        runSQL("""
        CREATE TABLE IF NOT EXISTS sessions (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            model_path TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        """)
        runSQL("""
        CREATE TABLE IF NOT EXISTS messages (
            id TEXT PRIMARY KEY,
            session_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL,
            reasoning TEXT,
            tool_calls_json TEXT,
            created_at REAL NOT NULL,
            FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
        );
        """)
        runSQL("CREATE INDEX IF NOT EXISTS ix_messages_session ON messages(session_id, created_at);")
        runSQL("""
        CREATE TABLE IF NOT EXISTS api_keys (
            id TEXT PRIMARY KEY,
            label TEXT NOT NULL,
            value TEXT NOT NULL,
            created_at REAL NOT NULL,
            last_used_at REAL
        );
        """)

        // Schema version bump: add `is_streaming` column to messages so
        // we can recover from mid-stream force-quits. We check PRAGMA
        // user_version to decide whether to ALTER — SQLite doesn't
        // support `ADD COLUMN IF NOT EXISTS`.
        let version = currentUserVersion()
        if version < 1 {
            // ALTER may fail (column already exists from a prior test
            // run on an unbumped version) — ignore the failure, the
            // column-existence check below is cheap.
            runSQL("ALTER TABLE messages ADD COLUMN is_streaming INTEGER NOT NULL DEFAULT 0;")
            runSQL("PRAGMA user_version = 1;")
        }
        if version < 2 {
            // Unified Chat schema. These columns absorb the redesigned
            // StudioChatScreen's parallel UserDefaults model and make the
            // capable SQLite chat path the single source of truth.
            runSQL("ALTER TABLE sessions ADD COLUMN model_name TEXT;")
            runSQL("ALTER TABLE sessions ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0;")
            runSQL("ALTER TABLE sessions ADD COLUMN collection_name TEXT;")
            runSQL("ALTER TABLE messages ADD COLUMN image_data BLOB;")
            runSQL("ALTER TABLE messages ADD COLUMN video_paths BLOB;")
            runSQL("ALTER TABLE messages ADD COLUMN tool_statuses BLOB;")
            runSQL("PRAGMA user_version = 2;")
        }
        if version < 3 {
            // Composer recovery must be durable: process termination during a
            // draft should not silently discard a user's unsent text, media,
            // or extracted PDF/DOCX/TXT context.  The session FK means a
            // permanent chat delete also removes its draft automatically.
            runSQL("""
            CREATE TABLE IF NOT EXISTS chat_drafts (
                session_id TEXT PRIMARY KEY,
                input_text TEXT NOT NULL DEFAULT '',
                image_data BLOB,
                video_paths BLOB,
                document_data BLOB,
                updated_at REAL NOT NULL,
                FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
            );
            """)
            runSQL("PRAGMA user_version = 3;")
        }
        if version < 4 {
            // Split user-visible Markdown (`content`) from model-only document
            // injection (`request_context`) and persist assistant generation
            // completion state for export/import fidelity.
            runSQL("ALTER TABLE messages ADD COLUMN request_context TEXT NOT NULL DEFAULT '';")
            runSQL("ALTER TABLE messages ADD COLUMN generation_state TEXT;")
            runSQL("PRAGMA user_version = 4;")
        }
    }

    private func currentUserVersion() -> Int {
        var stmt: OpaquePointer?
        var value: Int = 0
        if sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                value = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return value
    }

    /// Recover from force-quit mid-stream: any messages left with
    /// `is_streaming = 1` get flipped back to 0 and tagged with an
    /// ` [interrupted]` suffix so the user sees what happened. Call
    /// exactly once on app launch, BEFORE any session loads. Mirrors
    /// Electron's `sessions.ts::markInterrupted` on startup.
    func markAllStreamingAsInterrupted() {
        runSQL("""
        UPDATE messages
           SET is_streaming = 0,
               content = content || ' [interrupted]',
               generation_state = 'interrupted'
         WHERE is_streaming = 1;
        """)
    }

    // MARK: - API keys (used by APIKeyManager)

    struct APIKeyRow: Identifiable, Hashable, Sendable {
        let id: String
        var label: String
        var value: String
        var createdAt: Date
        var lastUsedAt: Date?
    }

    func allAPIKeys() -> [APIKeyRow] {
        var out: [APIKeyRow] = []
        var stmt: OpaquePointer?
        let sql = "SELECT id, label, value, created_at, last_used_at FROM api_keys ORDER BY created_at DESC"
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = cstr(stmt, 0)
                let label = cstr(stmt, 1)
                let value = cstr(stmt, 2)
                let created = sqlite3_column_double(stmt, 3)
                let lastUsed: Date? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                out.append(APIKeyRow(id: id, label: label, value: value,
                                     createdAt: Date(timeIntervalSince1970: created),
                                     lastUsedAt: lastUsed))
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    func insertAPIKey(_ row: APIKeyRow) {
        let sql = """
        INSERT INTO api_keys (id, label, value, created_at, last_used_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            label=excluded.label,
            value=excluded.value,
            last_used_at=excluded.last_used_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, row.id, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, row.label, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, row.value, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 4, row.createdAt.timeIntervalSince1970)
        if let lu = row.lastUsedAt {
            sqlite3_bind_double(stmt, 5, lu.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, 5)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func deleteAPIKey(id: String) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM api_keys WHERE id=?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func touchAPIKey(id: String, at: Date = Date()) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE api_keys SET last_used_at=? WHERE id=?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, at.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func runSQL(_ sql: String) {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "?"
            NSLog("vMLX sqlite failed: \(msg)")
            sqlite3_free(err)
        }
    }

    /// Run `body` inside a SQLite transaction. Commits on clean
    /// return, rolls back on thrown error. Used by bulk-insert
    /// paths (chat clearAllSessions undo, chat-fork message copy)
    /// so N upserts hit one fsync instead of N. Iter-27: pre-fix a
    /// 20-chat x 50-msg undo was O(1000) synchronous fsyncs —
    /// visible as a multi-second UI hiccup on rotational storage.
    /// Not re-entrant; nested calls collapse to the outer txn's
    /// fate.
    func withTransaction(_ body: () throws -> Void) rethrows {
        runSQL("BEGIN IMMEDIATE TRANSACTION;")
        do {
            try body()
            runSQL("COMMIT;")
        } catch {
            runSQL("ROLLBACK;")
            throw error
        }
    }

    // MARK: - Sessions

    func allSessions() -> [ChatSession] {
        var results: [ChatSession] = []
        let sql = """
        SELECT id, title, model_path, model_name, is_pinned, collection_name,
               created_at, updated_at
          FROM sessions
         ORDER BY is_pinned DESC, updated_at DESC
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = UUID(uuidString: cstr(stmt, 0)) ?? UUID()
                let title = cstr(stmt, 1)
                let mp = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : cstr(stmt, 2)
                let modelName = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : cstr(stmt, 3)
                let isPinned = sqlite3_column_int(stmt, 4) != 0
                let collection = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : cstr(stmt, 5)
                let c = sqlite3_column_double(stmt, 6)
                let u = sqlite3_column_double(stmt, 7)
                results.append(ChatSession(
                    id: id, title: title, modelPath: mp, modelName: modelName,
                    isPinned: isPinned, collectionName: collection,
                    createdAt: Date(timeIntervalSince1970: c),
                    updatedAt: Date(timeIntervalSince1970: u)
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    func upsertSession(_ s: ChatSession) {
        let sql = """
        INSERT INTO sessions
            (id, title, model_path, model_name, is_pinned, collection_name, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title=excluded.title,
            model_path=excluded.model_path,
            model_name=excluded.model_name,
            is_pinned=excluded.is_pinned,
            collection_name=excluded.collection_name,
            updated_at=excluded.updated_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, s.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, s.title, -1, SQLITE_TRANSIENT)
        if let mp = s.modelPath {
            sqlite3_bind_text(stmt, 3, mp, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        if let modelName = s.modelName {
            sqlite3_bind_text(stmt, 4, modelName, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_int(stmt, 5, s.isPinned ? 1 : 0)
        if let collection = s.collectionName {
            sqlite3_bind_text(stmt, 6, collection, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        sqlite3_bind_double(stmt, 7, s.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 8, s.updatedAt.timeIntervalSince1970)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    func deleteSession(_ id: UUID) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM sessions WHERE id=?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Composer drafts

    func draft(for sessionId: UUID) -> ChatDraftPayload? {
        let sql = """
        SELECT input_text, image_data, video_paths, document_data
          FROM chat_drafts
         WHERE session_id=?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId.uuidString, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let payload = ChatDraftPayload(
            inputText: cstr(stmt, 0),
            pendingImages: decodeBlob([Data].self, statement: stmt, column: 1) ?? [],
            pendingVideoPaths: decodeBlob([String].self, statement: stmt, column: 2) ?? [],
            pendingDocuments: decodeBlob([ChatDocumentAttachment].self, statement: stmt, column: 3) ?? []
        )
        return payload.isEmpty ? nil : payload
    }

    func upsertDraft(_ draft: ChatDraftPayload, for sessionId: UUID) {
        guard !draft.isEmpty else {
            deleteDraft(for: sessionId)
            return
        }
        let sql = """
        INSERT INTO chat_drafts
            (session_id, input_text, image_data, video_paths, document_data, updated_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(session_id) DO UPDATE SET
            input_text=excluded.input_text,
            image_data=excluded.image_data,
            video_paths=excluded.video_paths,
            document_data=excluded.document_data,
            updated_at=excluded.updated_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, sessionId.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, draft.inputText, -1, SQLITE_TRANSIENT)
        bindBlob(try? JSONEncoder().encode(draft.pendingImages), statement: stmt, index: 3)
        bindBlob(try? JSONEncoder().encode(draft.pendingVideoPaths), statement: stmt, index: 4)
        bindBlob(try? JSONEncoder().encode(draft.pendingDocuments), statement: stmt, index: 5)
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
        sqlite3_step(stmt)
    }

    func deleteDraft(for sessionId: UUID) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM chat_drafts WHERE session_id=?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, sessionId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - Messages

    func messages(for sessionId: UUID) -> [ChatMessage] {
        var results: [ChatMessage] = []
        let sql = """
        SELECT id, session_id, role, content, reasoning, tool_calls_json,
               created_at, is_streaming, image_data, video_paths, tool_statuses,
               request_context, generation_state
        FROM messages WHERE session_id=? ORDER BY created_at ASC
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, sessionId.uuidString, -1, SQLITE_TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = UUID(uuidString: cstr(stmt, 0)) ?? UUID()
                let sid = UUID(uuidString: cstr(stmt, 1)) ?? sessionId
                let role = ChatMessage.Role(rawValue: cstr(stmt, 2)) ?? .user
                let content = cstr(stmt, 3)
                let reasoning = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : cstr(stmt, 4)
                let tc = sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : cstr(stmt, 5)
                let ts = sqlite3_column_double(stmt, 6)
                let isStreaming = sqlite3_column_int(stmt, 7) != 0
                let images: [Data] = decodeBlob([Data].self, statement: stmt, column: 8) ?? []
                let videos: [String] = decodeBlob([String].self, statement: stmt, column: 9) ?? []
                let statuses: [String: ToolCallStatus] = decodeBlob(
                    [String: ToolCallStatus].self, statement: stmt, column: 10
                ) ?? [:]
                let requestContext = sqlite3_column_type(stmt, 11) == SQLITE_NULL
                    ? ""
                    : cstr(stmt, 11)
                let generationState: ChatGenerationState? = {
                    guard sqlite3_column_type(stmt, 12) != SQLITE_NULL else { return nil }
                    return ChatGenerationState(rawValue: cstr(stmt, 12))
                }()
                results.append(ChatMessage(
                    id: id, sessionId: sid, role: role, content: content,
                    requestContext: requestContext,
                    reasoning: reasoning, imageData: images, videoPaths: videos,
                    toolCallsJSON: tc, toolStatuses: statuses,
                    createdAt: Date(timeIntervalSince1970: ts),
                    isStreaming: isStreaming,
                    generationState: generationState
                ))
            }
        }
        sqlite3_finalize(stmt)
        return results
    }

    func upsertMessage(_ m: ChatMessage) {
        let sql = """
        INSERT INTO messages
            (id, session_id, role, content, reasoning, tool_calls_json, created_at,
             is_streaming, image_data, video_paths, tool_statuses,
             request_context, generation_state)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            content=excluded.content,
            reasoning=excluded.reasoning,
            tool_calls_json=excluded.tool_calls_json,
            image_data=excluded.image_data,
            video_paths=excluded.video_paths,
            tool_statuses=excluded.tool_statuses,
            is_streaming=excluded.is_streaming,
            request_context=excluded.request_context,
            generation_state=excluded.generation_state;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        sqlite3_bind_text(stmt, 1, m.id.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, m.sessionId.uuidString, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, m.role.rawValue, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, m.content, -1, SQLITE_TRANSIENT)
        if let r = m.reasoning {
            sqlite3_bind_text(stmt, 5, r, -1, SQLITE_TRANSIENT)
        } else { sqlite3_bind_null(stmt, 5) }
        if let tc = m.toolCallsJSON {
            sqlite3_bind_text(stmt, 6, tc, -1, SQLITE_TRANSIENT)
        } else { sqlite3_bind_null(stmt, 6) }
        sqlite3_bind_double(stmt, 7, m.createdAt.timeIntervalSince1970)
        sqlite3_bind_int(stmt, 8, m.isStreaming ? 1 : 0)
        bindBlob(try? JSONEncoder().encode(m.imageData), statement: stmt, index: 9)
        bindBlob(try? JSONEncoder().encode(m.videoPaths), statement: stmt, index: 10)
        bindBlob(try? JSONEncoder().encode(m.toolStatuses), statement: stmt, index: 11)
        sqlite3_bind_text(stmt, 12, m.requestContext, -1, SQLITE_TRANSIENT)
        if let state = m.generationState {
            sqlite3_bind_text(stmt, 13, state.rawValue, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 13)
        }
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)
    }

    private func bindBlob(_ data: Data?, statement: OpaquePointer?, index: Int32) {
        guard let data, !data.isEmpty else {
            sqlite3_bind_null(statement, index)
            return
        }
        data.withUnsafeBytes { bytes in
            _ = sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
        }
    }

    private func decodeBlob<T: Decodable>(
        _ type: T.Type,
        statement: OpaquePointer?,
        column: Int32
    ) -> T? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, column)
        else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        guard count > 0 else { return nil }
        return try? JSONDecoder().decode(type, from: Data(bytes: bytes, count: count))
    }

    func deleteMessage(_ id: UUID) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM messages WHERE id=?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    /// Return the `limit` most recent distinct user prompts across every
    /// chat session, newest first. Used by CachePanel's "Warm from recent"
    /// action to prefill the prefix cache without leaking session context
    /// (we only want distinct prompt strings, not the ordered history).
    func recentUserPrompts(limit: Int) -> [String] {
        let sql = """
            SELECT DISTINCT content FROM messages
            WHERE role = 'user' AND content != ''
            ORDER BY created_at DESC
            LIMIT ?
            """
        var stmt: OpaquePointer?
        var out: [String] = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int(stmt, 1, Int32(limit))
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cstr = sqlite3_column_text(stmt, 0) {
                    out.append(String(cString: cstr))
                }
            }
        }
        sqlite3_finalize(stmt)
        return out
    }

    func deleteMessages(after createdAt: Date, in sessionId: UUID) {
        let sql = "DELETE FROM messages WHERE session_id=? AND created_at>=?"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, sessionId.uuidString, -1, SQLITE_TRANSIENT)
            sqlite3_bind_double(stmt, 2, createdAt.timeIntervalSince1970)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - helpers

    private func cstr(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let p = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: p)
    }
}

// SQLite `SQLITE_TRANSIENT` constant isn't bridged; re-declare here.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
