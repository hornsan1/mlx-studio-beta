import Foundation
import vMLXEngine

enum ChatImportError: LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case emptyConversation
    case invalidMessageRole(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "This conversation uses unsupported export version \(version)."
        case .emptyConversation:
            return "The selected file does not contain any conversation messages."
        case .invalidMessageRole(let role):
            return "The conversation contains an unsupported message role: \(role)."
        }
    }
}

/// Decoder for ChatExporter's stable JSON format and the legacy Studio Library
/// envelope. Import creates fresh UUIDs so bringing the same file in twice
/// never overwrites an existing chat. Supports versions 1–4; v4 carries
/// `displayContent` / `requestContext` and `generationState`; older versions
/// default content to GFM and empty context.
enum ChatImporter {
    private struct Envelope: Decodable {
        var version: Int
        var contentFormat: String?
        var session: SessionBlock
        var messages: [MessageBlock]
    }

    private struct SessionBlock: Decodable {
        var title: String
        var createdAt: String?
        /// Legacy v1/v2 display-name field.
        var model: String?
        var modelName: String?
        var modelPath: String?
        var isPinned: Bool?
        var collectionName: String?
    }

    private struct MessageBlock: Decodable {
        var role: String
        var content: String?
        var displayContent: String?
        var requestContext: String?
        var contentFormat: String?
        var reasoning: String?
        var toolCallsJSON: String?
        var imagesBase64: [String]?
        var videoPaths: [String]?
        var toolStatuses: [String: ToolCallStatus]?
        var generationState: String?
        var createdAt: String?
    }

    /// Library exports predating the unified SQLite path use
    /// `{schemaVersion, exportedAt, session: {turns: [...]}}`. Keep this
    /// decoder here so old exported conversations remain importable through
    /// the single Chat import surface.
    private struct StudioEnvelope: Decodable {
        var schemaVersion: Int
        var session: StudioChatSession
    }

    /// Settings that are intrinsic to the exported conversation rather than
    /// the importing app's global defaults. These become per-chat overrides
    /// so reopening an older Studio Library export does not silently change
    /// its response or prompt budget.
    struct ImportedChatSettings: Equatable {
        var maxTokens: Int?
        var maxPromptTokens: Int?

        var isEmpty: Bool {
            maxTokens == nil && maxPromptTokens == nil
        }

        func makeChatSettings() -> ChatSettings {
            var settings = ChatSettings()
            settings.maxTokens = maxTokens
            settings.maxPromptTokens = maxPromptTokens
            return settings
        }
    }

    struct ImportedConversation: Equatable {
        var session: ChatSession
        var messages: [ChatMessage]
        var chatSettings: ImportedChatSettings?
    }

    static func decode(_ data: Data, now: Date = Date()) throws -> ImportedConversation {
        if let envelope = try? JSONDecoder().decode(Envelope.self, from: data) {
            return try decodeCanonical(envelope, now: now)
        }

        let studioDecoder = JSONDecoder()
        studioDecoder.dateDecodingStrategy = .iso8601
        let studio = try studioDecoder.decode(StudioEnvelope.self, from: data)
        guard studio.schemaVersion == 1 else {
            throw ChatImportError.unsupportedVersion(studio.schemaVersion)
        }
        return try decodeStudio(studio.session, now: now)
    }

    private static func decodeCanonical(
        _ envelope: Envelope,
        now: Date
    ) throws -> ImportedConversation {
        guard (1...4).contains(envelope.version) else {
            throw ChatImportError.unsupportedVersion(envelope.version)
        }
        guard !envelope.messages.isEmpty else { throw ChatImportError.emptyConversation }

        let sessionID = UUID()
        let createdAt = parseDate(envelope.session.createdAt) ?? now
        let modelName = normalizedModelName(envelope.session.modelName ?? envelope.session.model)
        let session = ChatSession(
            id: sessionID,
            title: normalizedTitle(envelope.session.title),
            modelPath: normalizedModelPath(envelope.session.modelPath),
            modelName: modelName,
            isPinned: envelope.session.isPinned ?? false,
            collectionName: normalizedCollectionName(envelope.session.collectionName),
            createdAt: createdAt,
            updatedAt: now
        )
        let messages = try envelope.messages.enumerated().map { offset, source in
            guard let role = ChatMessage.Role(rawValue: source.role.lowercased()) else {
                throw ChatImportError.invalidMessageRole(source.role)
            }
            let display = source.displayContent ?? source.content ?? ""
            let requestContext = source.requestContext ?? ""
            let genState = source.generationState.flatMap(ChatGenerationState.init(rawValue:))
            return ChatMessage(
                sessionId: sessionID,
                role: role,
                content: display,
                requestContext: requestContext,
                reasoning: source.reasoning,
                imageData: (source.imagesBase64 ?? []).compactMap { Data(base64Encoded: $0) },
                videoPaths: source.videoPaths ?? [],
                toolCallsJSON: source.toolCallsJSON,
                toolStatuses: source.toolStatuses ?? [:],
                createdAt: parseDate(source.createdAt)
                    ?? createdAt.addingTimeInterval(Double(offset) * 0.000_001),
                isStreaming: false,
                generationState: genState
            )
        }
        return ImportedConversation(session: session, messages: messages, chatSettings: nil)
    }

    private static func decodeStudio(
        _ source: StudioChatSession,
        now: Date
    ) throws -> ImportedConversation {
        guard !source.turns.isEmpty else { throw ChatImportError.emptyConversation }

        let sessionID = UUID()
        let createdAt = source.createdAt
        let session = ChatSession(
            id: sessionID,
            title: normalizedTitle(source.title),
            modelPath: nil,
            modelName: normalizedModelName(source.modelName),
            isPinned: source.isPinned,
            collectionName: nil,
            createdAt: createdAt,
            updatedAt: now
        )
        let cleanedSystemPrompt = source.systemPrompt
            .map(StudioChatText.cleanForDisplay)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let alreadyHasSystemPrompt = source.turns.contains { turn in
            turn.role == .system
                && StudioChatText.cleanForDisplay(turn.content)
                    .trimmingCharacters(in: .whitespacesAndNewlines) == cleanedSystemPrompt
        }
        var messages: [ChatMessage] = []
        if let cleanedSystemPrompt, !cleanedSystemPrompt.isEmpty, !alreadyHasSystemPrompt {
            messages.append(
                ChatMessage(
                    sessionId: sessionID,
                    role: .system,
                    content: cleanedSystemPrompt,
                    createdAt: createdAt.addingTimeInterval(-0.000_001)
                )
            )
        }
        messages.append(contentsOf: source.turns.map { turn in
            let role: ChatMessage.Role
            switch turn.role {
            case .user: role = .user
            case .assistant: role = .assistant
            case .system: role = .system
            }
            let generationState: ChatGenerationState?
            if role == .assistant {
                switch turn.streamState {
                case .complete: generationState = .complete
                case .failed: generationState = .failed
                case .cancelled: generationState = .stopped
                // A live Library export cannot safely resume its engine.
                // Preserve the partial output as interrupted rather than
                // silently presenting it as completed.
                case .streaming: generationState = .interrupted
                }
            } else {
                generationState = nil
            }
            return ChatMessage(
                sessionId: sessionID,
                role: role,
                content: StudioChatText.cleanForDisplay(turn.content),
                createdAt: turn.createdAt,
                isStreaming: false,
                generationState: generationState
            )
        })
        let exportedSettings = ImportedChatSettings(
            maxTokens: source.maxResponseTokens,
            maxPromptTokens: source.contextLimitTokens
        )
        return ImportedConversation(
            session: session,
            messages: messages,
            chatSettings: exportedSettings.isEmpty ? nil : exportedSettings
        )
    }

    private static func normalizedTitle(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Imported chat" : trimmed
    }

    private static func normalizedModelName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "(unspecified)" ? nil : trimmed
    }

    private static func normalizedModelPath(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedCollectionName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: value) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: value)
    }
}
