import Foundation

enum StudioChatHistoryStore {
    static let legacyKey = "mlxstudio.chat.history"
    static let sessionsKey = "mlxstudio.chat.sessions"
    static let selectedSessionKey = "mlxstudio.chat.selectedSessionID"

    static func loadSessions(defaults: UserDefaults = .standard) -> [StudioChatSession] {
        if let data = defaults.data(forKey: sessionsKey),
           let sessions = try? JSONDecoder().decode([StudioChatSession].self, from: data) {
            return sorted(sessions)
                .map(clean)
                .filter { !$0.turns.isEmpty }
        }

        let migratedTurns = loadLegacyTurns(defaults: defaults)
        guard !migratedTurns.isEmpty else { return [] }
        let migrated = StudioChatSession(
            title: title(from: migratedTurns),
            modelName: nil,
            turns: migratedTurns,
            createdAt: migratedTurns.first?.createdAt ?? Date(),
            updatedAt: migratedTurns.last?.createdAt ?? Date()
        )
        saveSessions([migrated], defaults: defaults)
        return [migrated]
    }

    static func saveSessions(
        _ sessions: [StudioChatSession],
        defaults: UserDefaults = .standard
    ) {
        let trimmed = Array(sorted(sessions)
            .filter { !$0.turns.isEmpty }
            .prefix(100)
            .map(clean))
        if let selected = loadSelectedSessionID(defaults: defaults),
           !trimmed.contains(where: { $0.id == selected }) {
            saveSelectedSessionID(nil, defaults: defaults)
        }
        guard let data = try? JSONEncoder().encode(trimmed) else { return }
        defaults.set(data, forKey: sessionsKey)
    }

    static func deleteSession(
        _ id: UUID,
        defaults: UserDefaults = .standard
    ) {
        let wasSelected = loadSelectedSessionID(defaults: defaults) == id
        let remaining = loadSessions(defaults: defaults).filter { $0.id != id }
        saveSessions(remaining, defaults: defaults)
        if wasSelected {
            saveSelectedSessionID(sorted(remaining).first?.id, defaults: defaults)
        }
    }

    static func updateSessionModelName(
        _ id: UUID,
        modelName: String,
        updatedAt: Date = Date(),
        defaults: UserDefaults = .standard
    ) {
        var sessions = loadSessions(defaults: defaults)
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        if sessions[index].modelName != modelName {
            sessions[index].summaryExportPath = nil
            sessions[index].summaryExportedAt = nil
        }
        sessions[index].modelName = modelName
        sessions[index].updatedAt = updatedAt
        saveSessions(sessions, defaults: defaults)
    }

    static func updateSessionTitle(
        _ id: UUID,
        title rawTitle: String,
        defaults: UserDefaults = .standard
    ) {
        var sessions = loadSessions(defaults: defaults)
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let resolvedTitle = title(rawTitle)
        if sessions[index].title != resolvedTitle {
            sessions[index].summaryExportPath = nil
            sessions[index].summaryExportedAt = nil
        }
        sessions[index].title = resolvedTitle
        saveSessions(sessions, defaults: defaults)
    }

    static func loadSelectedSessionID(defaults: UserDefaults = .standard) -> UUID? {
        guard let raw = defaults.string(forKey: selectedSessionKey) else { return nil }
        return UUID(uuidString: raw)
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

    static func sorted(_ sessions: [StudioChatSession]) -> [StudioChatSession] {
        sessions.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned {
                return lhs.isPinned && !rhs.isPinned
            }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    static func title(_ text: String) -> String {
        let cleaned = StudioChatText.cleanForDisplay(text)
            .replacingOccurrences(of: "\n", with: " ")
        guard !cleaned.isEmpty else { return "New Chat" }
        if cleaned.count <= 48 { return cleaned }
        let end = cleaned.index(cleaned.startIndex, offsetBy: 48)
        return String(cleaned[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func title(from turns: [ChatTurn]) -> String {
        turns.first(where: { $0.role == .user && !StudioChatText.cleanForDisplay($0.content).isEmpty })
            .map { title($0.content) }
            ?? "New Chat"
    }

    private static func clean(_ session: StudioChatSession) -> StudioChatSession {
        var cleaned = session
        cleaned.turns = session.turns.map { turn in
            var next = turn
            next.content = StudioChatText.clean(next.content)
            if next.streamState == .streaming {
                next.streamState = .cancelled
                if next.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    next.content = "Stopped before completion."
                }
            }
            return next
        }
        cleaned.title = title(session.title)
        if cleaned.title == "New Chat" {
            cleaned.title = title(from: cleaned.turns)
        }
        return cleaned
    }

    private static func loadLegacyTurns(defaults: UserDefaults) -> [ChatTurn] {
        guard let data = defaults.data(forKey: legacyKey),
              let turns = try? JSONDecoder().decode([ChatTurn].self, from: data)
        else { return [] }
        return turns.map { turn in
            var cleaned = turn
            cleaned.content = StudioChatText.clean(cleaned.content)
            return cleaned
        }
    }
}
