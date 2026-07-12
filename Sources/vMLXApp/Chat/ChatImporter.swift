import Foundation

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

/// Decoder for ChatExporter's stable JSON format. Import creates fresh UUIDs
/// so bringing the same file in twice never overwrites an existing chat.
/// Supports versions 1–4. v4 carries `displayContent` / `requestContext` and
/// `generationState`; older versions default content to GFM and empty context.
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

    struct ImportedConversation: Equatable {
        var session: ChatSession
        var messages: [ChatMessage]
    }

    static func decode(_ data: Data, now: Date = Date()) throws -> ImportedConversation {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
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
        return ImportedConversation(session: session, messages: messages)
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
