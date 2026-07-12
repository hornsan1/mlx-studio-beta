import Foundation
import vMLXEngine

/// Persisted chat session.
struct ChatSession: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var modelPath: String?
    /// Stable display identity captured when the conversation is created.
    /// Kept separately from `modelPath` so reopening a chat can explain
    /// which model produced it even when that model was moved or deleted.
    var modelName: String?
    var isPinned: Bool
    /// Lightweight collection name. Nil means the unfiled/default group.
    var collectionName: String?
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         title: String = "New chat",
         modelPath: String? = nil,
         modelName: String? = nil,
         isPinned: Bool = false,
         collectionName: String? = nil,
         createdAt: Date = .now,
         updatedAt: Date = .now) {
        self.id = id
        self.title = title
        self.modelPath = modelPath
        self.modelName = modelName
        self.isPinned = isPinned
        self.collectionName = collectionName
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// `ChatViewModel` uses this to decide whether the first user prompt can
    /// replace the generic shell-created title. Keep the comparison
    /// case-insensitive because historic rows use both `New Chat` and
    /// `New chat`.
    var hasPlaceholderTitle: Bool {
        let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized.isEmpty || normalized == "new chat" || normalized == "untitled chat"
    }
}

/// Tool-call lifecycle state for the inline tool-call card UI. Mirrors
/// `StreamChunk.ToolStatus.Phase` but as a persisted enum on the chat
/// message so the card can re-render its pill after a reload.
enum ToolCallStatus: String, Codable, Hashable {
    case pending, running, done, error
}

/// Inline tool-call metadata surfaced in chat bubbles. Parsed from
/// `ChatMessage.toolCallsJSON` so persisted rows survive restart and the
/// renderer doesn't have to hand-decode JSON.
struct InlineToolCall: Identifiable, Hashable {
    var id: String        // tool_call.id
    var name: String      // function name
    var arguments: String // JSON args string (may be partial mid-stream)
    var status: ToolCallStatus
    var output: String?   // stdout/stderr once done
    var exitCode: Int?
}

/// Terminal generation outcome for assistant messages (export + relaunch).
enum ChatGenerationState: String, Codable, Hashable, Sendable {
    case complete
    case stopped
    case failed
    case interrupted
}

/// Persisted chat message.
struct ChatMessage: Identifiable, Codable, Hashable {
    enum Role: String, Codable { case system, user, assistant, tool }

    var id: UUID
    var sessionId: UUID
    var role: Role
    /// User-visible Markdown / plain text. Never includes injected retrieval.
    var content: String
    /// Document extraction/retrieval text injected for the model only.
    /// Kept out of the bubble body so preview/export do not present retrieved
    /// docs as user-authored text.
    var requestContext: String = ""
    var reasoning: String?
    var imageData: [Data]        // inline base64-decoded images
    /// Absolute `file://` URLs of attached videos. Stored as paths
    /// rather than inline bytes because a 30 s 1080p clip is ~30 MB
    /// and encoding inline into SQLite would 4x-bloat the DB. The
    /// engine path (ChatRequest → video_url ContentPart) consumes
    /// these as-is. Empty when no videos attached. Added iter-15.
    var videoPaths: [String] = []
    var toolCallsJSON: String?   // raw tool_calls array JSON
    /// Lifecycle phase keyed by `tool_call.id`. Updated from streaming
    /// `StreamChunk.ToolStatus` events. Persisted alongside the raw
    /// tool-calls JSON so InlineToolCallCard can re-render its pill after
    /// a reload.
    var toolStatuses: [String: ToolCallStatus] = [:]
    var createdAt: Date
    var isStreaming: Bool
    /// Assistant completion outcome. `nil` for non-assistant or legacy rows.
    var generationState: ChatGenerationState? = nil

    /// Per-message metrics surfaced by the metrics strip under each assistant
    /// turn. Transient — not persisted to SQLite (matches Electron behavior:
    /// metrics live only for the duration of the in-memory message). Manually
    /// excluded from Codable + Hashable to avoid a schema migration.
    var usage: StreamChunk.Usage? = nil

    enum CodingKeys: String, CodingKey {
        case id, sessionId, role, content, requestContext, reasoning, imageData, videoPaths
        case toolCallsJSON, toolStatuses, createdAt, isStreaming, generationState
        case displayContent
    }

    /// Text sent to the model: display content plus optional request context.
    var modelPayloadContent: String {
        let display = content
        let ctx = requestContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if ctx.isEmpty { return display }
        if display.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return ctx }
        return display + "\n\n" + ctx
    }

    /// Alias for plan language: raw user Markdown bytes.
    var displayContent: String {
        get { content }
        set { content = newValue }
    }

    static func == (lhs: ChatMessage, rhs: ChatMessage) -> Bool {
        lhs.id == rhs.id && lhs.sessionId == rhs.sessionId && lhs.role == rhs.role &&
        lhs.content == rhs.content && lhs.requestContext == rhs.requestContext &&
        lhs.reasoning == rhs.reasoning &&
        lhs.imageData == rhs.imageData && lhs.videoPaths == rhs.videoPaths &&
        lhs.toolCallsJSON == rhs.toolCallsJSON &&
        lhs.toolStatuses == rhs.toolStatuses &&
        lhs.createdAt == rhs.createdAt && lhs.isStreaming == rhs.isStreaming &&
        lhs.generationState == rhs.generationState
    }
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(content)
        hasher.combine(requestContext)
        hasher.combine(isStreaming)
        hasher.combine(generationState)
    }

    init(id: UUID = UUID(),
         sessionId: UUID,
         role: Role,
         content: String = "",
         requestContext: String = "",
         reasoning: String? = nil,
         imageData: [Data] = [],
         videoPaths: [String] = [],
         toolCallsJSON: String? = nil,
         toolStatuses: [String: ToolCallStatus] = [:],
         createdAt: Date = .now,
         isStreaming: Bool = false,
         generationState: ChatGenerationState? = nil) {
        self.id = id
        self.sessionId = sessionId
        self.role = role
        self.content = content
        self.requestContext = requestContext
        self.reasoning = reasoning
        self.imageData = imageData
        self.videoPaths = videoPaths
        self.toolCallsJSON = toolCallsJSON
        self.toolStatuses = toolStatuses
        self.createdAt = createdAt
        self.isStreaming = isStreaming
        self.generationState = generationState
    }

    // Backward-compat decoder: pre-iter-15 rows have no `videoPaths`
    // key. Default to empty without throwing so existing chats load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id          = try c.decode(UUID.self, forKey: .id)
        self.sessionId   = try c.decode(UUID.self, forKey: .sessionId)
        self.role        = try c.decode(Role.self, forKey: .role)
        if let display = try c.decodeIfPresent(String.self, forKey: .displayContent) {
            self.content = display
        } else {
            self.content = try c.decode(String.self, forKey: .content)
        }
        self.requestContext = try c.decodeIfPresent(String.self, forKey: .requestContext) ?? ""
        self.reasoning   = try c.decodeIfPresent(String.self, forKey: .reasoning)
        self.imageData   = try c.decodeIfPresent([Data].self, forKey: .imageData) ?? []
        self.videoPaths  = try c.decodeIfPresent([String].self, forKey: .videoPaths) ?? []
        self.toolCallsJSON = try c.decodeIfPresent(String.self, forKey: .toolCallsJSON)
        self.toolStatuses  = try c.decodeIfPresent([String: ToolCallStatus].self, forKey: .toolStatuses) ?? [:]
        self.createdAt   = try c.decode(Date.self, forKey: .createdAt)
        self.isStreaming = try c.decodeIfPresent(Bool.self, forKey: .isStreaming) ?? false
        self.generationState = try c.decodeIfPresent(ChatGenerationState.self, forKey: .generationState)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
        if !requestContext.isEmpty {
            try c.encode(requestContext, forKey: .requestContext)
        }
        try c.encodeIfPresent(reasoning, forKey: .reasoning)
        try c.encode(imageData, forKey: .imageData)
        try c.encode(videoPaths, forKey: .videoPaths)
        try c.encodeIfPresent(toolCallsJSON, forKey: .toolCallsJSON)
        try c.encode(toolStatuses, forKey: .toolStatuses)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(isStreaming, forKey: .isStreaming)
        try c.encodeIfPresent(generationState, forKey: .generationState)
    }

    /// Decoded tool-call list for inline cards. Empty when nothing is set.
    var inlineToolCalls: [InlineToolCall] {
        guard let json = toolCallsJSON,
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return arr.compactMap { raw in
            guard let id = raw["id"] as? String else { return nil }
            let fn = (raw["function"] as? [String: Any]) ?? [:]
            let name = (fn["name"] as? String) ?? "function"
            let args: String
            if let s = fn["arguments"] as? String {
                args = s
            } else if let obj = fn["arguments"] {
                args = (try? String(data: JSONSerialization.data(withJSONObject: obj), encoding: .utf8)) ?? ""
            } else {
                args = ""
            }
            let status = toolStatuses[id] ?? .pending
            return InlineToolCall(
                id: id, name: name, arguments: args,
                status: status, output: nil, exitCode: nil
            )
        }
    }
}
