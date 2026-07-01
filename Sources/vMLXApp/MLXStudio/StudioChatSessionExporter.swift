import Foundation

enum StudioChatSessionExportFormat {
    case markdown
    case json

    var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .json: return "json"
        }
    }
}

enum StudioChatSessionExporter {
    static func defaultFilename(
        for session: StudioChatSession,
        format: StudioChatSessionExportFormat
    ) -> String {
        "\(fileSafe(session.title)).\(format.fileExtension)"
    }

    static func defaultSummaryFilename(for session: StudioChatSession) -> String {
        let shortID = String(session.id.uuidString.prefix(8))
        return "\(fileSafe(session.title))-summary-\(shortID).md"
    }

    static func data(
        for session: StudioChatSession,
        format: StudioChatSessionExportFormat,
        exportedAt: Date = Date()
    ) throws -> Data {
        switch format {
        case .markdown:
            return Data(markdown(for: session).utf8)
        case .json:
            let envelope = JSONEnvelope(
                schemaVersion: 1,
                exportedAt: exportedAt,
                session: portableSession(for: session)
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            return try encoder.encode(envelope)
        }
    }

    static func summaryData(
        for session: StudioChatSession,
        exportedAt: Date = Date()
    ) -> Data {
        Data(summaryMarkdown(for: session, exportedAt: exportedAt).utf8)
    }

    static func markdown(for session: StudioChatSession) -> String {
        var lines: [String] = [
            "# \(session.title)",
            "",
            "- Model: \(session.modelName ?? "Unknown")",
            "- Created: \(dateFormatter.string(from: session.createdAt))",
            "- Updated: \(dateFormatter.string(from: session.updatedAt))",
            "- Turns: \(session.turnCount)",
            "- Pinned: \(session.isPinned ? "yes" : "no")",
            "",
        ]
        for turn in session.turns {
            lines.append("## \(turnHeading(for: turn))")
            lines.append("")
            lines.append(StudioChatText.cleanForDisplay(turn.content))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static func summaryMarkdown(
        for session: StudioChatSession,
        exportedAt: Date = Date()
    ) -> String {
        let failedTurns = session.turns.filter { $0.streamState == .failed }.count
        let lastPrompt = session.turns.reversed()
            .first { $0.role == .user && !StudioChatText.cleanForDisplay($0.content).isEmpty }
            .map { StudioChatText.cleanForDisplay($0.content) } ?? "No prompt recorded."
        let latestResponse = session.turns.reversed()
            .first { $0.role == .assistant && !StudioChatText.cleanForDisplay($0.content).isEmpty }
            .map { StudioChatText.cleanForDisplay($0.content) } ?? "No response recorded."
        let handoff = failedTurns > 0
            ? "Recover or explain \(failedTurns) failed turn\(failedTurns == 1 ? "" : "s") before treating this session as clean."
            : "Ready to continue from the latest response."

        return [
            "# \(session.title) Summary",
            "",
            "- Model: \(session.modelName ?? "Unknown")",
            "- Created: \(dateFormatter.string(from: session.createdAt))",
            "- Updated: \(dateFormatter.string(from: session.updatedAt))",
            "- Exported: \(dateFormatter.string(from: exportedAt))",
            "- Turns: \(session.turnCount)",
            "- Failed turns: \(failedTurns)",
            "- Pinned: \(session.isPinned ? "yes" : "no")",
            "",
            "## Purpose",
            "",
            lastPrompt,
            "",
            "## Latest Response",
            "",
            latestResponse,
            "",
            "## Handoff",
            "",
            handoff,
            "",
        ].joined(separator: "\n")
    }

    @discardableResult
    static func write(
        for session: StudioChatSession,
        format: StudioChatSessionExportFormat,
        directory: URL? = nil,
        exportedAt: Date = Date()
    ) throws -> URL {
        let targetDirectory = try directory ?? defaultExportDirectory()
        try FileManager.default.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: true
        )
        let url = targetDirectory.appendingPathComponent(defaultFilename(for: session, format: format))
        try data(for: session, format: format, exportedAt: exportedAt).write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    static func writeSummary(
        for session: StudioChatSession,
        directory: URL? = nil,
        exportedAt: Date = Date()
    ) throws -> URL {
        let targetDirectory = try directory ?? defaultSummaryDirectory()
        try FileManager.default.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: true
        )
        let url = targetDirectory.appendingPathComponent(defaultSummaryFilename(for: session))
        try summaryData(for: session, exportedAt: exportedAt).write(to: url, options: .atomic)
        return url
    }

    static func fileSafe(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let scalars = title.unicodeScalars.map { scalar in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "MLX Studio Chat" : cleaned
    }

    private static func portableSession(for session: StudioChatSession) -> StudioChatSession {
        var portable = session
        portable.summaryExportPath = nil
        portable.summaryExportedAt = nil
        return portable
    }

    private static func turnHeading(for turn: ChatTurn) -> String {
        let role = turn.role.rawValue.capitalized
        switch turn.streamState {
        case .complete:
            return role
        case .streaming:
            return "\(role) (Streaming)"
        case .failed:
            return "\(role) (Failed)"
        case .cancelled:
            return "\(role) (Stopped)"
        }
    }

    private static func defaultSummaryDirectory() throws -> URL {
        try defaultAppSupportDirectory()
            .appendingPathComponent("chat-summaries", isDirectory: true)
    }

    private static func defaultExportDirectory() throws -> URL {
        try defaultAppSupportDirectory()
            .appendingPathComponent("chat-exports", isDirectory: true)
    }

    private static func defaultAppSupportDirectory() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport
            .appendingPathComponent("vMLX", isDirectory: true)
    }

    private struct JSONEnvelope: Encodable {
        var schemaVersion: Int
        var exportedAt: Date
        var session: StudioChatSession
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
