import Foundation

/// One-time bridge from the redesigned Studio chat's parallel UserDefaults
/// history into the production SQLite chat store.
///
/// The migration deliberately keeps UUIDs and timestamps stable so Library
/// deep links and the selected conversation continue to work after the app
/// switches to the unified Chat runtime. It is idempotent: an existing SQLite
/// session always wins and the completion marker prevents repeated scans.
@MainActor
enum StudioChatHistoryMigration {
    static let completionKey = "mlxstudio.chat.unifiedSQLiteMigration.v1"
    static let preferredSessionKey = "mlxstudio.chat.unifiedPreferredSessionID"
    /// Durable selection for the consolidated SQLite chat runtime. Kept
    /// separate from `preferredSessionKey`, which is consumed once as part of
    /// the old Studio-history migration.
    static let selectedSessionKey = "mlxstudio.chat.unifiedSelectedSessionID"

    struct Plan: Equatable {
        var sessions: [ChatSession]
        var messages: [UUID: [ChatMessage]]
        var preferredSessionID: UUID?
    }

    nonisolated static func makePlan(
        sessions: [StudioChatSession],
        preferredSessionID: UUID?
    ) -> Plan {
        var mappedSessions: [ChatSession] = []
        var mappedMessages: [UUID: [ChatMessage]] = [:]

        for source in sessions where !source.turns.isEmpty {
            let session = ChatSession(
                id: source.id,
                title: source.title,
                modelPath: nil,
                modelName: source.modelName,
                isPinned: source.isPinned,
                collectionName: nil,
                createdAt: source.createdAt,
                updatedAt: source.updatedAt
            )
            mappedSessions.append(session)
            mappedMessages[source.id] = source.turns.map { turn in
                ChatMessage(
                    id: turn.id,
                    sessionId: source.id,
                    role: ChatMessage.Role(rawValue: turn.role.rawValue) ?? .assistant,
                    content: recoveredContent(for: turn),
                    createdAt: turn.createdAt,
                    isStreaming: false
                )
            }
        }

        let ids = Set(mappedSessions.map(\.id))
        return Plan(
            sessions: mappedSessions,
            messages: mappedMessages,
            preferredSessionID: preferredSessionID.flatMap { ids.contains($0) ? $0 : nil }
        )
    }

    @discardableResult
    static func migrateIfNeeded(defaults: UserDefaults = .standard) -> UUID? {
        migrateIfNeeded(defaults: defaults, database: .shared)
    }

    @discardableResult
    static func migrateIfNeeded(defaults: UserDefaults, database: Database) -> UUID? {
        if defaults.bool(forKey: completionKey) {
            return loadPreferredSessionID(defaults: defaults)
        }

        let source = StudioChatHistoryStore.loadSessions(defaults: defaults)
        let selected = StudioChatHistoryStore.loadSelectedSessionID(defaults: defaults)
        let plan = makePlan(sessions: source, preferredSessionID: selected)
        let existingIDs = Set(database.allSessions().map(\.id))

        database.withTransaction {
            for session in plan.sessions where !existingIDs.contains(session.id) {
                database.upsertSession(session)
                for message in plan.messages[session.id] ?? [] {
                    database.upsertMessage(message)
                }
            }
        }

        savePreferredSessionID(plan.preferredSessionID, defaults: defaults)
        defaults.set(true, forKey: completionKey)
        return plan.preferredSessionID
    }

    static func consumePreferredSessionID(defaults: UserDefaults = .standard) -> UUID? {
        let value = loadPreferredSessionID(defaults: defaults)
        defaults.removeObject(forKey: preferredSessionKey)
        return value
    }

    static func loadSelectedSessionID(defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: selectedSessionKey).flatMap(UUID.init(uuidString:))
    }

    static func saveSelectedSessionID(
        _ id: UUID?,
        defaults: UserDefaults = .standard
    ) {
        if let id {
            defaults.set(id.uuidString, forKey: selectedSessionKey)
        } else {
            defaults.removeObject(forKey: selectedSessionKey)
        }
    }

    /// The consolidated SQLite chat runtime owns the durable selection. The
    /// one-time Studio-history migration preference is only a fallback for a
    /// first launch after migration; it must never reopen an older legacy
    /// conversation over the chat the user most recently selected.
    nonisolated static func resolvedSelectionID(
        appSelection: UUID?,
        durableSelection: UUID?,
        migrationSelection: UUID?
    ) -> UUID? {
        appSelection ?? durableSelection ?? migrationSelection
    }

    nonisolated private static func recoveredContent(for turn: ChatTurn) -> String {
        let cleaned = StudioChatText.clean(turn.content)
        switch turn.streamState {
        case .complete:
            return cleaned
        case .streaming:
            return recoveryText(cleaned, marker: "[interrupted]")
        case .cancelled:
            return recoveryText(cleaned, marker: "[stopped]")
        case .failed:
            return recoveryText(cleaned, marker: "[generation failed]")
        }
    }

    nonisolated private static func recoveryText(_ content: String, marker: String) -> String {
        content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? marker
            : "\(content) \(marker)"
    }

    private static func savePreferredSessionID(_ id: UUID?, defaults: UserDefaults) {
        if let id {
            defaults.set(id.uuidString, forKey: preferredSessionKey)
        } else {
            defaults.removeObject(forKey: preferredSessionKey)
        }
    }

    private static func loadPreferredSessionID(defaults: UserDefaults) -> UUID? {
        defaults.string(forKey: preferredSessionKey).flatMap(UUID.init(uuidString:))
    }
}
