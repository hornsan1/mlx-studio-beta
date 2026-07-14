import Foundation

/// Stable model identity captured when a launch source already resolved a
/// concrete local model. Loading remains an explicit action; carrying this
/// value only keeps the conversation tied to the user's selection.
struct ModelIdentity: Sendable, Equatable {
    var name: String
    var path: String?
    var repo: String?
}

/// One answer to the starter-model question shared by onboarding and Chat.
/// Setup resolves this contract once so launch callers do not invent another
/// handoff or infer availability from a directory name alone.
enum StarterModelResolution: Sendable, Equatable {
    case included(ModelIdentity)
    case local(ModelIdentity)
    case downloadRequired(repo: String, bytes: Int64, freeBytes: Int64)
    case incompatible(name: String, reason: String)
    case unavailable(reason: String)

    var resolvedIdentity: ModelIdentity? {
        switch self {
        case .included(let identity), .local(let identity):
            return identity
        case .downloadRequired, .incompatible, .unavailable:
            return nil
        }
    }
}

/// The sole cross-screen entry point into the production SQLite chat runtime.
/// Setup, menu commands, and Chat deep links enqueue this value;
/// `ChatViewModel` consumes it exactly once. Library and install completion
/// can adopt the same contract after their migrations are proven.
struct ChatLaunchIntent: Sendable, Equatable {
    enum Action: Sendable, Equatable {
        case newConversation
        case reopenLastClosed
        case openSession(UUID)
    }

    var action: Action
    var initialTitle: String?
    var initialDraft: String?
    var model: StarterModelResolution?

    init(
        action: Action,
        initialTitle: String? = nil,
        initialDraft: String? = nil,
        model: StarterModelResolution? = nil
    ) {
        self.action = action
        self.initialTitle = initialTitle
        self.initialDraft = initialDraft
        self.model = model
    }

    init(handoff: StudioChatPromptHandoff) {
        self.init(
            action: .newConversation,
            initialTitle: handoff.title,
            initialDraft: handoff.prompt
        )
    }

    func withModel(_ resolution: StarterModelResolution?) -> ChatLaunchIntent {
        var copy = self
        copy.model = resolution
        return copy
    }

    /// Parses only Chat routes. Other `vmlx://` destinations remain owned by
    /// the root URL router. The historical `mlxstudio://` spelling stays
    /// accepted so existing Shortcuts do not break during the transition.
    static func chatURL(_ url: URL) -> ChatLaunchIntent? {
        guard url.scheme == "vmlx" || url.scheme == "mlxstudio",
              url.host == "chat"
        else { return nil }

        let path = url.pathComponents.filter { $0 != "/" }
        guard let first = path.first else { return nil }
        if first == "new" {
            return ChatLaunchIntent(action: .newConversation)
        }
        guard let id = UUID(uuidString: first) else { return nil }
        return ChatLaunchIntent(action: .openSession(id))
    }
}
