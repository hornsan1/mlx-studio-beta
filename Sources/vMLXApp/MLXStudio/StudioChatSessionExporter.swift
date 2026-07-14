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

/// Option A bridge: map legacy Library `StudioChatSession` / `ChatTurn` onto
/// production `ChatSession` + `[ChatMessage]` so Markdown export can reuse
/// `ChatExporter.exportToMarkdown` and `ChatExporter.fenced`.
///
/// Studio **JSON** stays `schemaVersion: 1` (this bridge is Markdown-only).
enum StudioChatExportBridge {
    /// Map Studio session → production `ChatSession` for transcript helpers.
    static func chatSession(from studio: StudioChatSession) -> ChatSession {
        ChatSession(
            id: studio.id,
            title: studio.title,
            modelPath: nil,
            modelName: studio.modelName,
            isPinned: studio.isPinned,
            collectionName: nil,
            createdAt: studio.createdAt,
            updatedAt: studio.updatedAt
        )
    }

    /// Map Studio turns → production messages (cleaned display text; no requestContext).
    static func messages(from studio: StudioChatSession) -> [ChatMessage] {
        studio.turns.map { turn in
            ChatMessage(
                id: turn.id,
                sessionId: studio.id,
                role: role(from: turn.role),
                content: StudioChatText.cleanForDisplay(turn.content),
                requestContext: "",
                createdAt: turn.createdAt,
                // generationState is an assistant-terminal outcome in production chat.
                generationState: turn.role == .assistant
                    ? generationState(from: turn.streamState)
                    : nil
            )
        }
    }

    /// Full non-lossless transcript via production `ChatExporter`.
    static func markdownTranscript(for studio: StudioChatSession) -> String {
        ChatExporter.exportToMarkdown(
            chatSession(from: studio),
            messages: messages(from: studio)
        )
    }

    private static func role(from role: ChatTurn.Role) -> ChatMessage.Role {
        switch role {
        case .user: return .user
        case .assistant: return .assistant
        case .system: return .system
        }
    }

    /// Map Studio stream state → production generation state for export.
    /// A live Library export cannot resume its engine, so retain partial output
    /// as interrupted rather than silently omitting its state.
    private static func generationState(from streamState: ChatTurn.StreamState) -> ChatGenerationState? {
        switch streamState {
        case .complete:
            return .complete
        case .streaming:
            return .interrupted
        case .failed:
            return .failed
        case .cancelled:
            return .stopped
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

    /// Library Markdown export: bridges to production `ChatExporter` transcript
    /// (dynamic fences for reasoning/tool bodies; non-lossless header).
    ///
    /// **Format note:** uses the ChatExporter non-lossless shape (Created/Model/
    /// Messages). Legacy Library-only fields (Updated, Pinned, ISO8601+fractional
    /// timestamps, `"Unknown"` model fallback) are intentionally dropped; prefer
    /// Studio JSON (`schemaVersion: 1`) for machine-readable metadata.
    static func markdown(for session: StudioChatSession) -> String {
        StudioChatExportBridge.markdownTranscript(for: session)
    }

    /// Studio-specific Purpose / Latest Response / Handoff summary.
    /// Multi-line and backtick-containing model text is embedded via
    /// `ChatExporter.fenced` so headings/`---`/triple-backticks cannot break
    /// the summary structure.
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
            embedBody(lastPrompt),
            "",
            "## Latest Response",
            "",
            embedBody(latestResponse),
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

    /// Embed model text into summary MD. Multi-line bodies and any text with
    /// backticks are fenced via `ChatExporter.fenced` so nested ``` / headings /
    /// horizontal rules cannot disturb Purpose / Latest Response structure.
    /// Single-line plain placeholders stay unfenced for readability.
    private static func embedBody(_ body: String) -> String {
        if body.contains("`") || body.contains("\n") {
            return ChatExporter.fenced("text", body).trimmingCharacters(in: .newlines)
        }
        return body
    }

    private static func portableSession(for session: StudioChatSession) -> StudioChatSession {
        var portable = session
        portable.summaryExportPath = nil
        portable.summaryExportedAt = nil
        return portable
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
