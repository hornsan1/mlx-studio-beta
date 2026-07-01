import Foundation
import vMLXEngine

enum ExperienceMode: String, Codable, CaseIterable, Identifiable {
    case beginner
    case advanced

    static let storageKey = "mlxstudio.experienceMode"
    static let onboardingCompleteKey = "mlxstudio.onboardingComplete"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .beginner: return "Beginner"
        case .advanced: return "Advanced"
        }
    }

    var onboardingTitle: String {
        switch self {
        case .beginner: return "I just want local AI that works."
        case .advanced: return "I want full control over models and local APIs."
        }
    }

    static var persisted: ExperienceMode {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let mode = ExperienceMode(rawValue: raw)
        else { return .beginner }
        return mode
    }

    static func persist(_ mode: ExperienceMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: storageKey)
    }
}

typealias JobID = UUID

struct ModelRef: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var displayName: String
    var repo: String?
    var localURL: URL?

    var isLocal: Bool { localURL != nil }
}

struct ModelSummary: Identifiable, Hashable, Sendable {
    var id: String
    var ref: ModelRef
    var family: String
    var modality: String
    var sizeBytes: Int64
    var labels: [String]
    var isLoaded: Bool
}

enum StudioLibraryModelSearch {
    struct Summary: Equatable, Sendable {
        var loadStateLabel: String
        var searchTokens: [String]
    }

    static func summary(for model: ModelSummary) -> Summary {
        let loadStateLabel = model.isLoaded ? "Loaded" : "Not loaded"
        let path = model.ref.localURL?.path
        let repo = model.ref.repo

        return Summary(
            loadStateLabel: loadStateLabel,
            searchTokens: [
                model.ref.displayName,
                model.family,
                model.modality,
                model.labels.joined(separator: " "),
                loadStateLabel,
                model.isLoaded ? "loaded model" : "not loaded model",
                model.isLoaded ? "active model" : "downloaded model",
                model.isLoaded ? "ready in memory" : "available on disk",
                "\(model.sizeBytes)",
                formattedBytes(model.sizeBytes),
                repo ?? "",
                repo.map { "repo \($0)" } ?? "",
                path ?? "",
                path.map { "local path \($0)" } ?? "",
                model.ref.localURL?.lastPathComponent ?? "",
            ] + model.labels
        )
    }
}

enum StudioLibraryModelArchive {
    static func spotlightModel(in models: [ModelSummary], selectedModelPath: URL?) -> ModelSummary? {
        guard !models.isEmpty else { return nil }

        if let selectedModelPath,
           let selectedModel = models.first(where: { isSameLocalPath($0.ref.localURL, selectedModelPath) }) {
            return selectedModel
        }

        if let loadedModel = models.first(where: \.isLoaded) {
            return loadedModel
        }

        if let chatModel = models.first(where: isChatCapable) {
            return chatModel
        }

        return models.first
    }

    private static func isSameLocalPath(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs else { return false }
        return normalizedPath(lhs) == normalizedPath(rhs)
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private static func isChatCapable(_ model: ModelSummary) -> Bool {
        !model.modality.localizedCaseInsensitiveContains("image")
    }
}

enum StudioModelRouteReadiness {
    enum Level: Equatable {
        case chatReady
        case imageNeedsProof
        case imageProvenReady
    }

    struct Summary: Equatable {
        var level: Level
        var badge: String
        var routeName: String
        var routeValue: String
        var actionTitle: String
        var decisionCaption: String
        var selectedTitle: String
        var readyTitle: String
        var selectedCaption: String
        var readyCaption: String
        var loadTitle: String
        var loadDisabledReason: String?
    }

    static func summary(
        for model: ModelSummary,
        proofDirectory: URL? = nil
    ) -> Summary {
        guard isImageModel(model) else {
            return Summary(
                level: .chatReady,
                badge: "Chat-ready",
                routeName: "Chat",
                routeValue: "Ready",
                actionTitle: "Chat",
                decisionCaption: model.isLoaded
                    ? "Loaded in memory and ready for a conversation."
                    : "Ready on disk. Select it, load it once, then start a chat.",
                selectedTitle: "Chat is selected",
                readyTitle: "Chat route",
                selectedCaption: "Load once, then chat",
                readyCaption: "Select, load, or chat",
                loadTitle: model.isLoaded ? "Loaded" : "Load",
                loadDisabledReason: model.isLoaded ? "Model is already loaded." : nil
            )
        }

        if let catalogModel = catalogModel(for: model),
           let modelPath = model.ref.localURL?.path,
           ImageRuntimeProofStore.isVerified(
                runtimeName: catalogModel.runtimeName,
                modelPath: modelPath,
                directory: proofDirectory
           ) {
            return Summary(
                level: .imageProvenReady,
                badge: "Proven ready",
                routeName: "Canvas",
                routeValue: "Proven",
                actionTitle: "Create",
                decisionCaption: model.isLoaded
                    ? "Runtime proof exists for this image model. Open Create for a canvas-first generation flow."
                    : "Files and local PNG runtime proof are verified. Open Create when you want a canvas-first generation flow.",
                selectedTitle: "Canvas is selected",
                readyTitle: "Canvas route",
                selectedCaption: "Open Create when ready",
                readyCaption: "Select or create",
                loadTitle: "Canvas only",
                loadDisabledReason: "Image models open in Create; Chat Load only applies to chat-capable models."
            )
        }

        return Summary(
            level: .imageNeedsProof,
            badge: "Needs proof",
            routeName: "Canvas",
            routeValue: "Proof needed",
            actionTitle: "Verify in Create",
            decisionCaption: "Image files are present, but Create still needs a path-matched nonblank PNG proof before this is ready to generate.",
            selectedTitle: "Canvas needs proof",
            readyTitle: "Proof required",
            selectedCaption: "Open Create and generate once",
            readyCaption: "Open Create to verify",
            loadTitle: "Canvas only",
            loadDisabledReason: "Image models must be verified in Create; Chat Load only applies to chat-capable models."
        )
    }

    private static func isImageModel(_ model: ModelSummary) -> Bool {
        model.modality.localizedCaseInsensitiveContains("image")
    }

    private static func catalogModel(for model: ModelSummary) -> ImageCatalogModel? {
        let candidates = [
            model.ref.displayName,
            model.ref.repo ?? "",
            model.ref.id,
            model.ref.localURL?.path ?? "",
        ]
        .map { $0.lowercased() }

        return ImageCatalog.all.first { catalogModel in
            let needles = [
                catalogModel.id,
                catalogModel.displayName,
                catalogModel.repo,
                catalogModel.runtimeName,
                catalogModel.libraryMatchFragment,
            ]
            .map { $0.lowercased() }
            return needles.contains { needle in
                !needle.isEmpty && candidates.contains { candidate in
                    !candidate.isEmpty && (candidate.contains(needle) || needle.contains(candidate))
                }
            }
        }
    }
}

enum StudioModelActionCopy {
    static func selectAccessibilityTitle(for model: ModelSummary, selected: Bool) -> String {
        let verb = selected ? "Selected model" : "Select model"
        return "\(verb) \(model.ref.displayName)"
    }

    static func loadAccessibilityTitle(
        for model: ModelSummary,
        readiness: StudioModelRouteReadiness.Summary
    ) -> String {
        if let reason = readiness.loadDisabledReason {
            return "\(readiness.loadTitle) - Load model unavailable \(model.ref.displayName): \(reason)"
        }
        return "\(readiness.loadTitle) - Load model \(model.ref.displayName)"
    }

    static func routeAccessibilityTitle(
        for model: ModelSummary,
        readiness: StudioModelRouteReadiness.Summary,
        isImage: Bool
    ) -> String {
        if isImage {
            return "\(readiness.actionTitle) \(model.ref.displayName)"
        }
        return "Chat with \(model.ref.displayName)"
    }
}

enum StudioModelDeleteCopy {
    static let actionTitle = "Delete Files"
    static let confirmationTitle = "Delete model files?"

    static func accessibilityTitle(for model: ModelSummary) -> String {
        "Delete model files \(model.ref.displayName)"
    }

    static func confirmationButtonTitle(for model: ModelSummary) -> String {
        "Delete files for \(model.ref.displayName)"
    }

    static let recordWarning = "This is not just a Library record."

    static func diskRemovalMessage(for model: ModelSummary) -> String {
        let path = model.ref.localURL?.path ?? "the selected model folder"
        return "This removes the model folder from disk: \(path)"
    }

    static func confirmationMessage(for model: ModelSummary) -> String {
        "\(diskRemovalMessage(for: model)). \(recordWarning)"
    }

    static func successStatus(for model: ModelSummary) -> String {
        "Deleted model files for \(model.ref.displayName)"
    }

    static func disabledReason(for model: ModelSummary) -> String? {
        model.isLoaded ? "Stop this loaded model before deleting its files." : nil
    }
}

enum StudioServerModelCompatibility {
    static func isChatCapable(_ model: ModelSummary) -> Bool {
        !looksImageOnly(
            displayName: model.ref.displayName,
            modality: model.modality,
            family: model.family,
            path: model.ref.localURL?.path
        )
    }

    static func resolveServerModelPath(
        selectedPath: URL?,
        localModels: [ModelSummary]
    ) throws -> URL {
        if let selectedPath {
            if let selected = localModels.first(where: { $0.ref.localURL == selectedPath }) {
                guard isChatCapable(selected) else {
                    throw StudioServiceError.serverModelNotChatCapable(selected.ref.displayName)
                }
                guard let url = selected.ref.localURL else { throw StudioServiceError.modelNotLocal }
                return url
            }

            guard !looksImageOnly(
                displayName: selectedPath.lastPathComponent,
                modality: "",
                family: "",
                path: selectedPath.path
            ) else {
                throw StudioServiceError.serverModelNotChatCapable(
                    cleanModelName(selectedPath.lastPathComponent)
                )
            }
            return selectedPath
        }

        if let fallback = localModels.first(where: isChatCapable), let url = fallback.ref.localURL {
            return url
        }
        throw StudioServiceError.noSelectedModel
    }

    private static func looksImageOnly(
        displayName: String,
        modality: String,
        family: String,
        path: String?
    ) -> Bool {
        let text = "\(displayName) \(modality) \(family) \(path ?? "")".lowercased()
        return text.contains("image")
            || text.contains("flux")
            || text.contains("z-image")
            || text.contains("stable-diffusion")
    }

    private static func cleanModelName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "models--", with: "")
            .replacingOccurrences(of: "--", with: "/")
    }
}

enum StudioChatModelSelection {
    static func chatCapableModels(in models: [ModelSummary]) -> [ModelSummary] {
        models.filter(StudioServerModelCompatibility.isChatCapable)
    }

    static func chatModel(matching savedModelName: String?, in models: [ModelSummary]) -> ModelSummary? {
        guard let savedName = normalizedName(savedModelName) else { return nil }
        return chatCapableModels(in: models).first { model in
            modelNameCandidates(for: model).contains(savedName)
        }
    }

    static func selectedModelID(
        currentID: String?,
        selectedPath: URL?,
        sessionModelName: String? = nil,
        models: [ModelSummary]
    ) -> String? {
        let chatModels = chatCapableModels(in: models)
        if let sessionModel = chatModel(matching: sessionModelName, in: models) {
            return sessionModel.id
        }
        if let selectedPath,
           let selected = chatModels.first(where: { $0.ref.localURL == selectedPath }) {
            return selected.id
        }
        if let currentID,
           chatModels.contains(where: { $0.id == currentID }) {
            return currentID
        }
        return chatModels.first?.id
    }

    private static func modelNameCandidates(for model: ModelSummary) -> Set<String> {
        var candidates = [
            model.ref.displayName,
            model.ref.repo,
            model.ref.id,
            model.ref.localURL?.lastPathComponent,
        ]
        if let pathComponent = model.ref.localURL?.lastPathComponent {
            candidates.append(cleanLocalModelName(pathComponent))
        }
        return Set(candidates.compactMap(normalizedName))
    }

    private static func normalizedName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private static func cleanLocalModelName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "models--", with: "")
            .replacingOccurrences(of: "--", with: "/")
    }
}

struct HuggingFaceGateStatus: Equatable {
    enum Level: Equatable {
        case open
        case stored
        case validating
        case verified
        case invalid
    }

    var level: Level
    var value: String
    var detail: String
    var gatedRepoHint: String
    var canAttemptGatedDownload: Bool

    static func evaluate(
        hasToken: Bool,
        validation: HuggingFaceAuth.ValidationState
    ) -> HuggingFaceGateStatus {
        guard hasToken else {
            return HuggingFaceGateStatus(
                level: .open,
                value: "Public only",
                detail: "Public Hub models search and download normally. Gated repos need a read token and Hub access approval.",
                gatedRepoHint: "Gated - add HF token before download",
                canAttemptGatedDownload: false
            )
        }

        switch validation {
        case .unknown:
            return HuggingFaceGateStatus(
                level: .stored,
                value: "Token stored",
                detail: "Models will use the Keychain token for Hub search and downloads. Gated repos still need Hub access approval.",
                gatedRepoHint: "Gated - token stored; access approval required",
                canAttemptGatedDownload: true
            )
        case .validating:
            return HuggingFaceGateStatus(
                level: .validating,
                value: "Checking token",
                detail: "A Keychain token is being verified. Gated repos still need Hub access approval.",
                gatedRepoHint: "Gated - checking stored token",
                canAttemptGatedDownload: true
            )
        case .valid(let username):
            return HuggingFaceGateStatus(
                level: .verified,
                value: "Signed in @\(username)",
                detail: "Models will use the Keychain token for Hub search and downloads. Gated repos still need Hub access approval.",
                gatedRepoHint: "Gated - token ready; access approval required",
                canAttemptGatedDownload: true
            )
        case .invalid(let reason):
            return HuggingFaceGateStatus(
                level: .invalid,
                value: "Token rejected",
                detail: "Public Hub models still work. Gated repos need a valid token before download: \(reason)",
                gatedRepoHint: "Gated - fix HF token before download",
                canAttemptGatedDownload: false
            )
        }
    }
}

enum StudioModelMemoryFit {
    enum Level: String, Equatable {
        case spacious
        case comfort
        case tight
        case risky
        case over
    }

    struct Result: Equatable {
        var title: String
        var level: Level
        var estimatedRuntimeBytes: UInt64
        var systemMemoryBytes: UInt64
    }

    static func classify(
        sizeBytes: Int64,
        modality: String,
        systemMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory
    ) -> Result {
        let runtimeBytes = estimatedRuntimeBytes(sizeBytes: sizeBytes, modality: modality)
        let memory = max(systemMemoryBytes, 1)
        let ratio = Double(runtimeBytes) / Double(memory)

        let level: Level
        let title: String
        if ratio <= 0.15 {
            level = .spacious
            title = "Spacious"
        } else if ratio <= 0.35 {
            level = .comfort
            title = "Comfort"
        } else if ratio <= 0.65 {
            level = .tight
            title = "Tight"
        } else if ratio <= 0.90 {
            level = .risky
            title = "Risky"
        } else {
            level = .over
            title = "Over"
        }

        return Result(
            title: title,
            level: level,
            estimatedRuntimeBytes: runtimeBytes,
            systemMemoryBytes: memory
        )
    }

    static func estimatedRuntimeBytes(sizeBytes: Int64, modality: String) -> UInt64 {
        let base = max(Double(sizeBytes), 0)
        let gib = 1_073_741_824.0
        let lower = modality.lowercased()
        let multiplier: Double
        let reserveGiB: Double

        if lower.contains("image") {
            multiplier = 1.85
            reserveGiB = 6
        } else if lower.contains("vision") {
            multiplier = 1.55
            reserveGiB = 4
        } else {
            multiplier = 1.35
            reserveGiB = 2
        }

        let estimate = base * multiplier + reserveGiB * gib
        return UInt64(min(estimate.rounded(.up), Double(UInt64.max)))
    }
}

struct RecommendedModel: Identifiable, Hashable, Sendable {
    var id: String { ref.id }
    var ref: ModelRef
    var summary: String
    var sizeHint: String
    var labels: [String]
}

enum StudioStarterChatModel {
    static let repo = "LiquidAI/LFM2.5-350M"
    static let displayName = repo

    static let recommended = RecommendedModel(
        ref: ModelRef(
            id: "hf:\(repo)",
            displayName: displayName,
            repo: repo,
            localURL: nil
        ),
        summary: "LiquidAI's compact LFM2.5 chat model for fast first-run local conversations.",
        sizeHint: "~0.7 GB",
        labels: ["Fast", "Chat", "Beginner", "LFM2.5"]
    )
}

struct HubModelCandidate: Identifiable, Hashable, Sendable {
    var id: String { ref.id }
    var ref: ModelRef
    var family: String
    var modality: String
    var format: String
    var sizeHint: String
    var weightHint: String
    var storageHint: String
    var updatedHint: String
    var libraryName: String
    var pipeline: String
    var downloads: Int
    var likes: Int
    var gated: Bool
    var labels: [String]
    var compatibilityNote: String
}

enum ModelInstallSource: String, Codable, Sendable {
    case recommended
    case huggingFace
    case onboarding
}

enum ModelInstallTarget: Hashable, Sendable {
    case chat
    case image(runtimeName: String?)
}

struct ModelInstallRequest: Hashable, Sendable {
    var repo: String
    var displayName: String
    var source: ModelInstallSource
    var openChatWhenReady: Bool
    var target: ModelInstallTarget = .chat
}

struct ModelInstallProgress: Sendable, Hashable {
    var jobID: JobID
    var receivedBytes: Int64
    var totalBytes: Int64
    var bytesPerSecond: Double
    var etaSeconds: Double?

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }

    var label: String {
        var parts: [String] = []
        if totalBytes > 0 {
            parts.append("\(formattedBytes(receivedBytes)) / \(formattedBytes(totalBytes))")
        } else if receivedBytes > 0 {
            parts.append(formattedBytes(receivedBytes))
        }
        if bytesPerSecond > 0 {
            parts.append("\(formattedBytes(Int64(bytesPerSecond)))/s")
        }
        if let etaSeconds, etaSeconds.isFinite, etaSeconds > 1 {
            parts.append("ETA \(Self.formatETA(etaSeconds))")
        }
        return parts.isEmpty ? "Downloading" : parts.joined(separator: " - ")
    }

    init(job: DownloadManager.Job) {
        self.jobID = job.id
        self.receivedBytes = job.receivedBytes
        self.totalBytes = job.totalBytes
        self.bytesPerSecond = job.bytesPerSecond
        self.etaSeconds = job.etaSeconds
    }

    private static func formatETA(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        let minutes = total / 60
        let secs = total % 60
        if minutes >= 60 {
            return String(format: "%d:%02d:%02d", minutes / 60, minutes % 60, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

enum ModelInstallEvent: Sendable {
    case queued(JobID)
    case downloading(ModelInstallProgress)
    case verifying(ModelInstallProgress)
    case installed(ModelSummary)
    case loading(ModelSummary)
    case ready(ModelSummary)
    case failed(String)
}

struct StudioChatRequest: Sendable {
    var model: ModelRef
    var messages: [ChatTurn]
    var maxTokens: Int = 512
    var enableThinking: Bool = false
}

struct ChatTurn: Identifiable, Codable, Hashable, Sendable {
    enum Role: String, Codable, Sendable {
        case user
        case assistant
        case system
    }

    enum StreamState: String, Codable, Sendable {
        case complete
        case streaming
        case failed
        case cancelled
    }

    var id: UUID = UUID()
    var role: Role
    var content: String
    var createdAt: Date = Date()
    var streamState: StreamState = .complete

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        createdAt: Date = Date(),
        streamState: StreamState = .complete
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.streamState = streamState
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case createdAt
        case streamState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        role = try container.decodeIfPresent(Role.self, forKey: .role) ?? .assistant
        content = try container.decodeIfPresent(String.self, forKey: .content) ?? ""
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        streamState = try container.decodeIfPresent(StreamState.self, forKey: .streamState) ?? .complete
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(streamState, forKey: .streamState)
    }
}

struct StudioChatSession: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var title: String
    var modelName: String?
    var turns: [ChatTurn]
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var isPinned: Bool = false
    var summaryExportPath: String?
    var summaryExportedAt: Date?

    init(
        id: UUID = UUID(),
        title: String,
        modelName: String? = nil,
        turns: [ChatTurn],
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isPinned: Bool = false,
        summaryExportPath: String? = nil,
        summaryExportedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.modelName = modelName
        self.turns = turns
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.summaryExportPath = summaryExportPath
        self.summaryExportedAt = summaryExportedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case modelName
        case turns
        case createdAt
        case updatedAt
        case isPinned
        case summaryExportPath
        case summaryExportedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? "New Chat"
        modelName = try container.decodeIfPresent(String.self, forKey: .modelName)
        turns = try container.decodeIfPresent([ChatTurn].self, forKey: .turns) ?? []
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        isPinned = try container.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        summaryExportPath = try container.decodeIfPresent(String.self, forKey: .summaryExportPath)
        summaryExportedAt = try container.decodeIfPresent(Date.self, forKey: .summaryExportedAt)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(modelName, forKey: .modelName)
        try container.encode(turns, forKey: .turns)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(isPinned, forKey: .isPinned)
        try container.encodeIfPresent(summaryExportPath, forKey: .summaryExportPath)
        try container.encodeIfPresent(summaryExportedAt, forKey: .summaryExportedAt)
    }

    var preview: String {
        turns.reversed()
            .map { StudioChatText.cleanForDisplay($0.content) }
            .first { !$0.isEmpty } ?? "Empty conversation"
    }

    var turnCount: Int {
        turns.count
    }

    var hasSummaryExport: Bool {
        guard let summaryExportPath else { return false }
        return !summaryExportPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var summaryExportFileExists: Bool {
        guard let summaryExportPath,
              !summaryExportPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        return FileManager.default.fileExists(atPath: summaryExportPath)
    }
}

enum StudioChatSessionStatus {
    struct Summary: Equatable, Sendable {
        var label: String
        var failedTurnCount: Int
        var stoppedTurnCount: Int
        var streamingTurnCount: Int
        var searchTokens: [String]

        var needsAttention: Bool {
            failedTurnCount > 0 || stoppedTurnCount > 0 || streamingTurnCount > 0
        }
    }

    static func summary(
        for session: StudioChatSession,
        summaryExportExists explicitSummaryExportExists: Bool? = nil
    ) -> Summary {
        let failed = session.turns.filter { $0.streamState == .failed }.count
        let stopped = session.turns.filter { $0.streamState == .cancelled }.count
        let streaming = session.turns.filter { $0.streamState == .streaming }.count
        let summaryTokens = summarySearchTokens(
            for: session,
            summaryExportExists: explicitSummaryExportExists ?? session.summaryExportFileExists
        )

        if failed > 0 {
            return Summary(
                label: "\(failed) failed",
                failedTurnCount: failed,
                stoppedTurnCount: stopped,
                streamingTurnCount: streaming,
                searchTokens: ["failed", "failure", "\(failed) failed", "needs attention"] + summaryTokens
            )
        }
        if stopped > 0 {
            return Summary(
                label: "\(stopped) stopped",
                failedTurnCount: failed,
                stoppedTurnCount: stopped,
                streamingTurnCount: streaming,
                searchTokens: ["stopped", "cancelled", "\(stopped) stopped", "needs attention"] + summaryTokens
            )
        }
        if streaming > 0 {
            return Summary(
                label: "\(streaming) in progress",
                failedTurnCount: failed,
                stoppedTurnCount: stopped,
                streamingTurnCount: streaming,
                searchTokens: ["streaming", "in progress", "\(streaming) in progress"] + summaryTokens
            )
        }
        return Summary(
            label: "Clean",
            failedTurnCount: 0,
            stoppedTurnCount: 0,
            streamingTurnCount: 0,
            searchTokens: ["clean", "ready"] + summaryTokens
        )
    }

    private static func summarySearchTokens(
        for session: StudioChatSession,
        summaryExportExists: Bool
    ) -> [String] {
        guard session.hasSummaryExport else {
            return ["summary not saved", "handoff ready"]
        }
        let path = session.summaryExportPath ?? ""
        let locationTokens = [
            path,
            URL(fileURLWithPath: path).lastPathComponent,
        ]
        if summaryExportExists {
            return ["summary saved", "handoff saved"] + locationTokens
        }
        return ["summary missing", "handoff missing", "summary file missing"] + locationTokens
    }
}

enum StudioImageRecordStatus {
    struct Summary: Equatable {
        var fileLabel: String
        var provenanceLabel: String
        var searchTokens: [String]
    }

    static func summary(
        for record: ImageGenerationRecord,
        fileExists explicitFileExists: Bool? = nil,
        sidecarStatus explicitSidecarStatus: ImageGenerationRecord.MetadataSidecarStatus? = nil
    ) -> Summary {
        let fileExists = explicitFileExists ?? recordOutputExists(record)
        let sidecarStatus = explicitSidecarStatus ?? record.metadataSidecarStatus
        let fileLabel = fileStateLabel(for: record, fileExists: fileExists)
        let provenanceLabel = provenanceStateLabel(for: sidecarStatus)
        let settingsTokens = settingsSearchTokens(for: record)

        return Summary(
            fileLabel: fileLabel,
            provenanceLabel: provenanceLabel,
            searchTokens: [
                "memory tile",
                "prompt captured",
                "prompt packet",
                "settings reusable",
                "reusable settings",
                "provenance",
                "provenance \(provenanceLabel)",
                provenanceLabel,
                "file \(fileLabel)",
                fileLabel,
            ] + fileSearchTokens(
                for: record,
                fileLabel: fileLabel,
                fileExists: fileExists
            ) + settingsTokens
        )
    }

    private static func recordOutputExists(_ record: ImageGenerationRecord) -> Bool {
        guard let outputPath = record.outputPath else { return false }
        return FileManager.default.fileExists(atPath: outputPath)
    }

    private static func fileStateLabel(
        for record: ImageGenerationRecord,
        fileExists: Bool
    ) -> String {
        if fileExists { return "On disk" }
        if record.outputPath != nil { return "Missing" }
        switch record.status {
        case .pending: return "Pending"
        case .completed: return "Missing"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private static func provenanceStateLabel(
        for status: ImageGenerationRecord.MetadataSidecarStatus
    ) -> String {
        switch status {
        case .saved:
            return "Sidecar saved"
        case .missing:
            return "Exportable"
        case .stale:
            return "Stale sidecar"
        }
    }

    private static func fileSearchTokens(
        for record: ImageGenerationRecord,
        fileLabel: String,
        fileExists: Bool
    ) -> [String] {
        if fileExists {
            return ["ready artifact", "file on disk", "on disk", "saved asset"]
        }
        if fileLabel == "Missing" {
            return ["missing file", "file missing"]
        }
        if record.status == .failed || fileLabel == "Failed" {
            return ["failed output", "file failed"]
        }
        return []
    }

    private static func settingsSearchTokens(for record: ImageGenerationRecord) -> [String] {
        guard let settings = try? JSONDecoder().decode(
            ImageGenSettings.self,
            from: Data(record.settingsJSON.utf8)
        ) else {
            return ["settings saved"]
        }
        let size = "\(settings.width)x\(settings.height)"
        let seed = settings.seed >= 0 ? "seed \(settings.seed)" : "random seed"
        return [
            size,
            "\(settings.steps) steps",
            seed,
            "\(size) - \(settings.steps) steps - \(seed)",
        ]
    }
}

enum StudioChatRecovery {
    struct RetryDraft: Equatable {
        var retainedTurns: [ChatTurn]
        var assistant: ChatTurn
    }

    static func retryDraft(
        from turnID: UUID,
        in turns: [ChatTurn],
        assistantID: UUID = UUID(),
        createdAt: Date = Date()
    ) -> RetryDraft? {
        guard let turnIndex = turns.firstIndex(where: { $0.id == turnID }) else { return nil }
        let userIndex: Int?
        if turns[turnIndex].role == .user {
            userIndex = turnIndex
        } else {
            userIndex = turns[..<turnIndex].lastIndex { $0.role == .user }
        }
        guard let userIndex else { return nil }

        return RetryDraft(
            retainedTurns: Array(turns.prefix(userIndex + 1)),
            assistant: ChatTurn(
                id: assistantID,
                role: .assistant,
                content: "",
                createdAt: createdAt,
                streamState: .streaming
            )
        )
    }
}

enum StudioChatRegenerateAvailability {
    static func disabledReason(
        hasSelectedModel: Bool,
        isStreaming: Bool,
        turnID: UUID,
        turns: [ChatTurn]
    ) -> String? {
        if isStreaming {
            return "Wait for the current response to finish."
        }
        if !hasSelectedModel {
            return "Select a chat model before regenerating."
        }
        if StudioChatRecovery.retryDraft(from: turnID, in: turns) == nil {
            return "No user prompt is available to regenerate from."
        }
        return nil
    }
}

struct StudioImageReuseRequest: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var prompt: String
    var modelAlias: String
    var settings: ImageGenSettings
}

struct StudioChatPromptHandoff: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var prompt: String
    var status: String
}

enum StudioDiagnosticSource: String, Codable, CaseIterable, Sendable {
    case chatLoad = "chat load"
    case chatStream = "chat stream"
    case imageGeneration = "image generation"
    case imageInstall = "image install"
    case modelInstall = "model install"
    case server = "server"
    case advancedModels = "advanced models"
    case diagnostics = "diagnostics"

    var label: String {
        rawValue.split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }
}

enum StudioDiagnosticSeverity: String, Codable, Sendable {
    case info
    case warning
    case error
}

struct StudioDiagnosticIssue: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var source: StudioDiagnosticSource
    var severity: StudioDiagnosticSeverity
    var title: String
    var message: String
    var context: String?
    var createdAt: Date = Date()

    var compactContext: String {
        let cleaned = context?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cleaned.isEmpty ? source.label : cleaned
    }

    var redactedTitle: String {
        StudioDiagnosticRedactor.redact(title)
    }

    var redactedMessage: String {
        StudioDiagnosticRedactor.redact(message)
    }

    var redactedCompactContext: String {
        StudioDiagnosticRedactor.redact(compactContext)
    }
}

struct StudioDiagnosticRecoveryStep: Identifiable, Equatable, Sendable {
    var id: String { number }
    var number: String
    var title: String
    var value: String
    var caption: String
    var isEvidence: Bool = false
}

enum StudioDiagnosticBriefFormatter {
    static let freshIssueInterval: TimeInterval = 30 * 60

    static func impactText(for issue: StudioDiagnosticIssue) -> String {
        switch issue.severity {
        case .error: return "Workflow blocked"
        case .warning: return "Needs attention"
        case .info: return "For awareness"
        }
    }

    static func nextMove(for source: StudioDiagnosticSource) -> String {
        switch source {
        case .chatLoad:
            return "Check selected model"
        case .chatStream:
            return "Retry or inspect logs"
        case .imageGeneration:
            return "Open Create proof"
        case .imageInstall, .modelInstall:
            return "Verify install files"
        case .server:
            return "Check binding"
        case .advancedModels:
            return "Review job output"
        case .diagnostics:
            return "Refresh snapshot"
        }
    }

    static func recordedAtText(for issue: StudioDiagnosticIssue) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: issue.createdAt)
    }

    static func freshnessLabel(
        for issue: StudioDiagnosticIssue,
        relativeTo referenceDate: Date = Date()
    ) -> String {
        isFresh(issue, relativeTo: referenceDate) ? "Fresh" : "Stale"
    }

    static func freshnessText(
        for issue: StudioDiagnosticIssue,
        relativeTo referenceDate: Date = Date()
    ) -> String {
        "\(freshnessLabel(for: issue, relativeTo: referenceDate)) - \(ageText(for: issue, relativeTo: referenceDate)) old"
    }

    static func isFresh(
        _ issue: StudioDiagnosticIssue,
        relativeTo referenceDate: Date = Date()
    ) -> Bool {
        ageSeconds(for: issue, relativeTo: referenceDate) <= freshIssueInterval
    }

    static func recoverySteps(for issue: StudioDiagnosticIssue) -> [StudioDiagnosticRecoveryStep] {
        [
            StudioDiagnosticRecoveryStep(
                number: "1",
                title: "Confirm impact",
                value: impactText(for: issue),
                caption: "Gate retry or continue"
            ),
            StudioDiagnosticRecoveryStep(
                number: "2",
                title: "Inspect evidence",
                value: issue.redactedCompactContext,
                caption: "Match source against logs",
                isEvidence: true
            ),
            StudioDiagnosticRecoveryStep(
                number: "3",
                title: "Execute move",
                value: nextMove(for: issue.source),
                caption: recoveryActionDetail(for: issue)
            ),
        ]
    }

    static func recoveryActionDetail(for issue: StudioDiagnosticIssue) -> String {
        switch issue.source {
        case .chatLoad:
            return "Manual only - reselect a model, press Load, then refresh"
        case .chatStream:
            return "Manual only - use Chat Retry; no prompt is resent here"
        case .imageGeneration:
            return "Manual only - reopen Create proof; no image is generated here"
        case .imageInstall:
            return "Manual only - verify image files in Models; no files move here"
        case .modelInstall:
            return "Manual only - verify model files in Models; no files move here"
        case .server:
            if let port = serverPort(from: issue.redactedCompactContext) {
                return "Safe command: lsof -nP -iTCP:\(port) -sTCP:LISTEN"
            }
            return "Manual only - run Health Probe; no binding changes here"
        case .advancedModels:
            return "Safe no-op - open Advanced Models job row; no model files are changed"
        case .diagnostics:
            return "Safe no-op - refresh snapshot; no runtime state changes"
        }
    }

    static func incidentBrief(for issue: StudioDiagnosticIssue, openIssueCount: Int) -> String {
        [
            "MLX Studio Diagnostics Brief",
            "Incident: \(issue.redactedTitle)",
            "Severity: \(issue.severity.rawValue)",
            "Source: \(issue.source.label)",
            "Recorded: \(recordedAtText(for: issue))",
            "Freshness: \(freshnessText(for: issue))",
            "Message: \(issue.redactedMessage)",
            "Impact: \(impactText(for: issue))",
            "Evidence: \(issue.redactedCompactContext)",
            "Next move: \(nextMove(for: issue.source))",
            "Recovery action: \(recoveryActionDetail(for: issue))",
            "Open issues: \(openIssueCount)",
            "",
            recoveryPath(for: issue),
        ].joined(separator: "\n")
    }

    static func recoveryPath(for issue: StudioDiagnosticIssue) -> String {
        let stepLines = recoverySteps(for: issue).map {
            "\($0.number). \($0.title): \($0.value) (\($0.caption))"
        }
        return ([
            "MLX Studio Recovery Path",
            "Incident: \(issue.redactedTitle)",
            "Source: \(issue.source.label)",
            "Recorded: \(recordedAtText(for: issue))",
            "Freshness: \(freshnessText(for: issue))",
        ] + stepLines).joined(separator: "\n")
    }

    private static func serverPort(from text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #":([0-9]{2,5})(?:\b|/)"#) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let portRange = Range(match.range(at: 1), in: text),
              let port = Int(text[portRange]),
              (1...65_535).contains(port)
        else {
            return nil
        }
        return port
    }

    private static func ageSeconds(
        for issue: StudioDiagnosticIssue,
        relativeTo referenceDate: Date
    ) -> TimeInterval {
        max(0, referenceDate.timeIntervalSince(issue.createdAt))
    }

    private static func ageText(
        for issue: StudioDiagnosticIssue,
        relativeTo referenceDate: Date
    ) -> String {
        let seconds = ageSeconds(for: issue, relativeTo: referenceDate)
        if seconds < 60 { return "under 1 min" }

        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min" }

        let hours = Int(seconds / 3_600)
        if hours < 48 { return "\(hours) hr" }

        let days = max(1, Int(seconds / 86_400))
        return "\(days) day\(days == 1 ? "" : "s")"
    }
}

enum StudioDiagnosticIssueStore {
    static let storageKey = "mlxstudio.diagnostics.issues"

    static func load(limit: Int = 40) -> [StudioDiagnosticIssue] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let issues = try? JSONDecoder().decode([StudioDiagnosticIssue].self, from: data)
        else { return [] }
        return Array(issues.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
    }

    @discardableResult
    static func record(
        source: StudioDiagnosticSource,
        severity: StudioDiagnosticSeverity = .error,
        title: String,
        message: String,
        context: String? = nil
    ) -> StudioDiagnosticIssue {
        let issue = StudioDiagnosticIssue(
            source: source,
            severity: severity,
            title: StudioDiagnosticRedactor.redact(title),
            message: StudioDiagnosticRedactor.redact(StudioChatText.cleanForDisplay(message)),
            context: context.map(StudioDiagnosticRedactor.redact),
            createdAt: Date()
        )
        var issues = load(limit: 80)
        issues.insert(issue, at: 0)
        save(Array(issues.prefix(80)))
        return issue
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    private static func save(_ issues: [StudioDiagnosticIssue]) {
        guard let data = try? JSONEncoder().encode(issues) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

enum StudioAdvancedModelDiagnostic {
    @discardableResult
    static func recordFailure(
        kind: ModelJobKind,
        model: ModelRef,
        message: String
    ) -> StudioDiagnosticIssue {
        StudioDiagnosticIssueStore.record(
            source: .advancedModels,
            title: title(for: kind),
            message: message,
            context: context(for: model)
        )
    }

    static func title(for kind: ModelJobKind) -> String {
        switch kind {
        case .download:
            return "Advanced model download failed"
        case .inspect:
            return "Advanced model inspection failed"
        case .validate:
            return "Advanced model validation failed"
        case .benchmark:
            return "Advanced model benchmark failed"
        case .package:
            return "Advanced model report export failed"
        }
    }

    private static func context(for model: ModelRef) -> String {
        if let path = model.localURL?.path, !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(model.displayName) at \(path)"
        }
        if let repo = model.repo, !repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(model.displayName) from \(repo)"
        }
        return model.displayName
    }
}

enum StudioDiagnosticRedactor {
    static func redact(_ text: String) -> String {
        var output = text
        if let home = ProcessInfo.processInfo.environment["HOME"],
           !home.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            output = output.replacingOccurrences(of: home, with: "~")
        }
        output = replacingMatches(
            in: output,
            pattern: #"hf_[A-Za-z0-9_-]{8,}"#,
            with: "hf_[redacted]"
        )
        output = replacingMatches(
            in: output,
            pattern: #"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]{8,}"#,
            with: "$1[redacted]"
        )
        output = replacingMatches(
            in: output,
            pattern: #"(?i)\b(api[_-]?key|token)\s*[:=]\s*[^\s,;]+"#,
            with: "$1=[redacted]"
        )
        return output
    }

    private static func replacingMatches(
        in text: String,
        pattern: String,
        with replacement: String
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: replacement
        )
    }
}

enum ChatEvent: Sendable {
    case token(String)
    case reasoning(String)
    case usage(StreamChunk.Usage)
    case finished(String?)
}

enum StudioChatText {
    static func clean(_ text: String) -> String {
        var output = text
        for marker in [
            "<|im_start|>",
            "<|im_end|>",
            "<|endoftext|>",
            "<|assistant|>",
            "<|system|>",
            "<|user|>",
        ] {
            output = output.replacingOccurrences(of: marker, with: "")
        }
        while output.contains("\n\n\n") {
            output = output.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return output
    }

    static func cleanForDisplay(_ text: String) -> String {
        clean(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct ServerConfig: Codable, Hashable, Sendable {
    var host: String = "127.0.0.1"
    var port: Int = 8000
    var apiKey: String = ""
}

struct ServerHealth: Equatable, Sendable {
    enum Status: String, Sendable {
        case stopped
        case loading
        case running
        case sleeping
        case failed
    }

    var status: Status
    var label: String
    var endpoint: String
    var apiKey: String = ""
}

enum StudioServerCommandFormatter {
    static func endpoint(host: String, port: Int) -> String {
        var normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedHost.hasPrefix("http://") {
            normalizedHost.removeFirst("http://".count)
        } else if normalizedHost.hasPrefix("https://") {
            normalizedHost.removeFirst("https://".count)
        }
        normalizedHost = normalizedHost.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        if normalizedHost.isEmpty {
            normalizedHost = "127.0.0.1"
        }
        return "http://\(normalizedHost):\(port)"
    }

    static func endpoint(config: ServerConfig, health: ServerHealth) -> String {
        health.status == .stopped
            ? endpoint(host: config.host, port: config.port)
            : health.endpoint
    }

    static func binding(config: ServerConfig, health: ServerHealth) -> String {
        var value = endpoint(config: config, health: health)
        if value.hasPrefix("http://") {
            value.removeFirst("http://".count)
        } else if value.hasPrefix("https://") {
            value.removeFirst("https://".count)
        }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func clientAPIKey(config: ServerConfig, health: ServerHealth) -> String {
        switch health.status {
        case .loading, .running, .sleeping:
            return health.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        case .stopped, .failed:
            return config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func clientProbeCommand(
        endpoint: String,
        model: String,
        apiKey: String
    ) -> String {
        let normalizedEndpoint = endpoint.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        let selectedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let body: [String: Any] = [
            "model": selectedModel.isEmpty ? "local-model" : selectedModel,
            "messages": [
                [
                    "role": "user",
                    "content": "Say ready in one sentence.",
                ],
            ],
            "stream": false,
        ]
        let bodyData = (try? JSONSerialization.data(
            withJSONObject: body,
            options: [.sortedKeys]
        )) ?? Data("{}".utf8)
        let bodyText = String(data: bodyData, encoding: .utf8) ?? "{}"
        let auth = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let authHeader = auth.isEmpty
            ? ""
            : " \\\n  -H \(shellSingleQuoted("Authorization: Bearer \(auth)"))"

        return """
        curl \(normalizedEndpoint)/v1/chat/completions \\
          -H 'Content-Type: application/json'\(authHeader) \\
          -d \(shellSingleQuoted(bodyText))
        """
    }

    static func healthProbeCommand(endpoint: String) -> String {
        let normalizedEndpoint = endpoint.trimmingCharacters(
            in: CharacterSet(charactersIn: "/")
        )
        return "curl \(normalizedEndpoint)/health"
    }

    private static func shellSingleQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

struct APIRoute: Identifiable, Hashable, Sendable {
    var id: String { "\(method) \(path)" }
    var method: String
    var path: String
    var family: String
    var summary: String
    var streams: Bool
}

struct ModelInspection: Codable, Hashable, Sendable {
    var model: ModelRef
    var family: String
    var modality: String
    var sizeBytes: Int64
    var configKeys: [String]
    var tokenizerPresent: Bool
    var safetensorShardCount: Int
    var notes: [String]
}

enum ValidationSuite: String, Codable, CaseIterable, Sendable {
    case loadAndShortChat
}

struct BenchmarkConfig: Codable, Hashable, Sendable {
    var suite: String = Engine.BenchSuite.decode256.rawValue
}

enum StudioAdvancedModelBenchmarkGate {
    static func unavailableReason(
        displayName: String,
        modality: String,
        isLoaded: Bool
    ) -> String? {
        if isImageModel(displayName: displayName, modality: modality) {
            return "Benchmark requires a loaded text model"
        }
        if !isLoaded {
            return "Load model before benchmark"
        }
        return nil
    }

    static func isImageModel(displayName: String, modality: String) -> Bool {
        let text = "\(displayName) \(modality)".lowercased()
        return text.contains("image")
            || text.contains("flux")
            || text.contains("z-image")
            || text.contains("stable-diffusion")
    }
}

enum StudioAdvancedModelValidationGate {
    static func unavailableReason(
        hasSelectedModel: Bool,
        hasTokenizer: Bool
    ) -> String? {
        if !hasSelectedModel {
            return "Select a local model"
        }
        if !hasTokenizer {
            return "Tokenizer required before validation"
        }
        return nil
    }
}

enum StudioAdvancedModelReportGate {
    static func unavailableReason(
        hasSelectedModel: Bool,
        hasInspection: Bool
    ) -> String? {
        if !hasSelectedModel {
            return "Select a local model"
        }
        if !hasInspection {
            return "Run Inspect before report export"
        }
        return nil
    }
}

struct PackageOptions: Codable, Hashable, Sendable {
    var includeConfigSummary: Bool = true
}

enum ModelJobKind: String, Codable, Sendable {
    case download
    case inspect
    case validate
    case benchmark
    case package
}

enum JobStatus: String, Codable, Sendable {
    case queued
    case running
    case completed
    case failed
    case cancelled
}

struct ModelJob: Identifiable, Codable, Sendable {
    let id: UUID
    var kind: ModelJobKind
    var inputModel: ModelRef
    var outputPath: URL?
    var status: JobStatus
    var progress: Double?
    var logPath: URL?
    var message: String
    var createdAt: Date
    var updatedAt: Date
}

enum JobEvent: Sendable {
    case updated(ModelJob)
    case log(String)
}

@MainActor
protocol ModelService {
    func listLocalModels() async throws -> [ModelSummary]
    func listRecommendedModels() async throws -> [RecommendedModel]
    func searchCompatibleHubModels(query: String) async throws -> [HubModelCandidate]
    func downloadModel(_ model: ModelRef) async throws -> JobID
    func deleteModel(_ model: ModelRef) async throws
}

@MainActor
protocol ModelInstallService {
    func install(_ request: ModelInstallRequest) -> AsyncThrowingStream<ModelInstallEvent, Error>
}

@MainActor
protocol ChatService {
    func loadModel(_ model: ModelRef) async throws
    func streamMessage(_ request: StudioChatRequest) async throws -> AsyncThrowingStream<ChatEvent, Error>
    func stopGeneration() async
}

@MainActor
protocol ServerService {
    func startServer(config: ServerConfig) async throws
    func stopServer() async throws
    func health() async throws -> ServerHealth
    func routeCatalog() -> [APIRoute]
}

@MainActor
protocol AdvancedModelService {
    func inspect(_ model: ModelRef) async throws -> ModelInspection
    func validate(_ model: ModelRef, suite: ValidationSuite) async throws -> JobID
    func benchmark(_ model: ModelRef, config: BenchmarkConfig) async throws -> JobID
    func package(_ model: ModelRef, options: PackageOptions) async throws -> JobID
}

@MainActor
protocol JobService {
    func listJobs() async throws -> [ModelJob]
    func events(for id: JobID) -> AsyncStream<JobEvent>
    func cancel(_ id: JobID) async throws
    func retry(_ id: JobID) async throws -> JobID
}

enum StudioServiceError: LocalizedError {
    case modelNotLocal
    case noSelectedModel
    case serverModelNotChatCapable(String)
    case serverStartFailed(String)
    case missingModelDirectory
    case installedModelNotFound(String)
    case downloadFailed(String)
    case installVerificationFailed(String)
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLocal:
            return "Download or select this model before loading it."
        case .noSelectedModel:
            return "Select a local model first."
        case .serverModelNotChatCapable(let name):
            return "\(name) is an image model. Select a chat-capable model before starting Server."
        case .serverStartFailed(let message):
            return "Server did not start: \(message)"
        case .missingModelDirectory:
            return "The model directory could not be found."
        case .installedModelNotFound(let repo):
            return "Downloaded \(repo), but MLX Studio could not find a runnable local model entry."
        case .downloadFailed(let message):
            return message
        case .installVerificationFailed(let message):
            return message
        case .validationFailed(let message):
            return message
        }
    }
}

enum StudioServerLifecycleGuard {
    static func startFailureMessage(
        sessionState: EngineState?,
        hasSessionProcess: Bool,
        httpRunning: Bool,
        httpError: String?
    ) -> String? {
        if let httpError, !httpError.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "HTTP listener failed: \(httpError)"
        }
        if hasSessionProcess && httpRunning {
            switch sessionState {
            case .running, .standby:
                return nil
            case .loading(let progress):
                return "HTTP listener started while the model is still loading: \(progress.label)"
            case .error(let message):
                return "Engine load failed: \(message)"
            case .stopped, nil:
                return "HTTP listener started without a running model."
            }
        }
        switch sessionState {
        case .error(let message):
            return "Engine load failed: \(message)"
        case .loading(let progress):
            return "Still loading: \(progress.label)"
        case .running, .standby:
            return "HTTP listener did not start."
        case .stopped:
            return "Server stopped before accepting requests."
        case nil:
            return "Server session was not created."
        }
    }
}

@MainActor
final class StudioModelService: ModelService {
    private let app: AppState

    init(app: AppState) {
        self.app = app
    }

    func listLocalModels() async throws -> [ModelSummary] {
        let entries = await app.engine.scanModels(force: false)
        let loadedPath = await app.engine.loadedModelPath
        return entries
            .filter { $0.modality != .embedding && $0.modality != .rerank }
            .map { entry in
                ModelSummary(
                    id: entry.id,
                    ref: entry.modelRef,
                    family: entry.family,
                    modality: entry.modality.rawValue,
                    sizeBytes: entry.totalSizeBytes,
                    labels: labels(for: entry),
                    isLoaded: loadedPath == entry.canonicalPath
                )
            }
            .sorted { $0.ref.displayName.localizedCaseInsensitiveCompare($1.ref.displayName) == .orderedAscending }
    }

    func listRecommendedModels() async throws -> [RecommendedModel] {
        [
            StudioStarterChatModel.recommended,
            RecommendedModel(
                ref: ModelRef(
                    id: "hf:mlx-community/gemma-3-4b-it-4bit",
                    displayName: "Gemma 3 4B Instruct 4-bit",
                    repo: "mlx-community/gemma-3-4b-it-4bit",
                    localURL: nil
                ),
                summary: "Balanced local assistant for everyday prompts on Apple Silicon.",
                sizeHint: "~3 GB",
                labels: ["Balanced", "Chat", "Coding"]
            )
        ]
    }

    func searchCompatibleHubModels(query: String) async throws -> [HubModelCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let search = HuggingFaceSearch(token: HuggingFaceAuth.shared.currentToken())
        let rows = try await search.searchRuntimeCompatible(query: trimmed, limit: 24)
        return rows.map { row in
            let compatibility = row.runtimeCompatibility
            let displayName = row.modelId.split(separator: "/").last.map(String.init) ?? row.modelId
            let format = compatibility.format?.rawValue ?? "MLX"
            let modelType = compatibility.modelType ?? row.resolvedModelType ?? "unknown"
            var labels = [format, modelType]
            switch compatibility.modality {
            case .text:
                labels.append("Chat")
            case .vision:
                labels.append("Vision")
            case .embedding:
                labels.append("Embedding")
            case .image:
                labels.append("Image")
            case .rerank:
                labels.append("Rerank")
            case .unknown:
                labels.append("Model")
            }
            labels.append(contentsOf: quantizationLabels(from: row.tags))
            if row.gated {
                labels.append("Gated")
            }
            return HubModelCandidate(
                ref: ModelRef(
                    id: "hf:\(row.modelId)",
                    displayName: displayName,
                    repo: row.modelId,
                    localURL: nil
                ),
                family: modelType,
                modality: compatibility.modality.rawValue,
                format: format,
                sizeHint: formattedHubSize(row.weightBytes ?? row.usedStorageBytes),
                weightHint: formattedHubSize(row.weightBytes),
                storageHint: formattedHubSize(row.usedStorageBytes),
                updatedHint: formattedHubDate(row.lastModified),
                libraryName: row.libraryName?.uppercased() ?? format,
                pipeline: row.pipeline ?? compatibility.modality.rawValue,
                downloads: row.downloads,
                likes: row.likes,
                gated: row.gated,
                labels: Array(labels.prefix(6)),
                compatibilityNote: compatibility.reason
            )
        }
    }

    func downloadModel(_ model: ModelRef) async throws -> JobID {
        guard let repo = model.repo else { throw StudioServiceError.modelNotLocal }
        return await app.downloadManager.enqueue(repo: repo, displayName: model.displayName)
    }

    func deleteModel(_ model: ModelRef) async throws {
        let library = await app.engine.modelLibrary
        _ = try await library.deleteEntry(byId: model.id)
    }

    func addLocalModelDirectory(_ url: URL) async {
        let library = await app.engine.modelLibrary
        await library.addUserDir(url)
        _ = await library.scan(force: true)
    }

    private func labels(for entry: ModelLibrary.ModelEntry) -> [String] {
        var out: [String] = []
        switch entry.modality {
        case .text:
            out.append("Chat")
        case .vision:
            out.append("Vision")
        case .image:
            out.append("Image")
        case .embedding:
            out.append("Embedding")
        case .rerank:
            out.append("Rerank")
        case .unknown:
            out.append("Model")
        }
        if entry.totalSizeBytes < 2_000_000_000 {
            out.append("Fast")
        } else if entry.totalSizeBytes < 8_000_000_000 {
            out.append("Balanced")
        } else {
            out.append("Powerful")
        }
        if entry.isJANG || entry.isMXTQ {
            out.append("Advanced")
        }
        return out
    }

    private func quantizationLabels(from tags: [String]) -> [String] {
        tags
            .filter { tag in
                let lower = tag.lowercased()
                return lower.hasSuffix("-bit") || lower.contains("mxfp") || lower.contains("mxtq")
            }
            .prefix(2)
            .map { $0.uppercased() }
    }
}

@MainActor
final class StudioChatService: ChatService {
    private let app: AppState

    init(app: AppState) {
        self.app = app
    }

    func loadModel(_ model: ModelRef) async throws {
        guard let url = model.localURL else { throw StudioServiceError.modelNotLocal }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw StudioServiceError.missingModelDirectory
        }

        app.selectedModelPath = url
        let id: UUID
        if let existing = app.sessionId(forModelPath: url) {
            id = existing
        } else {
            id = await app.createSession(forModel: url)
        }
        await app.startSession(id)
    }

    func streamMessage(_ request: StudioChatRequest) async throws -> AsyncThrowingStream<ChatEvent, Error> {
        let engine = app.engine
        let engineRequest = ChatRequest(
            model: request.model.displayName,
            messages: request.messages.map { turn in
                ChatRequest.Message(
                    role: turn.role.rawValue,
                    content: .string(turn.content)
                )
            },
            stream: true,
            maxTokens: request.maxTokens,
            enableThinking: request.enableThinking
        )
        let upstream = await engine.stream(request: engineRequest)

        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await chunk in upstream {
                        if let content = chunk.content, !content.isEmpty {
                            continuation.yield(.token(StudioChatText.clean(content)))
                        }
                        if let reasoning = chunk.reasoning, !reasoning.isEmpty {
                            continuation.yield(.reasoning(StudioChatText.clean(reasoning)))
                        }
                        if let usage = chunk.usage {
                            continuation.yield(.usage(usage))
                        }
                        if let finish = chunk.finishReason {
                            continuation.yield(.finished(finish))
                        }
                    }
                    continuation.yield(.finished(nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func stopGeneration() async {
        await app.engine.cancelStream()
    }
}

@MainActor
final class StudioModelInstallService: ModelInstallService {
    private let app: AppState

    init(app: AppState) {
        self.app = app
    }

    func install(_ request: ModelInstallRequest) -> AsyncThrowingStream<ModelInstallEvent, Error> {
        makeCoordinator().install(request)
    }

    private func makeCoordinator() -> StudioModelInstallCoordinator {
        let downloadManager = app.downloadManager
        return StudioModelInstallCoordinator(dependencies: .init(
            subscribeDownloads: { await downloadManager.subscribe() },
            resolveExistingModel: { repo in
                try? await self.resolveInstalledModel(repo: repo, localPath: nil)
            },
            enqueueDownload: { repo, displayName in
                await downloadManager.enqueue(repo: repo, displayName: displayName)
            },
            cancelDownload: { id in await downloadManager.cancel(id) },
            resolveInstalledModel: { repo, localPath in
                return try await self.resolveInstalledModel(repo: repo, localPath: localPath)
            },
            verifyInstallTarget: { target, repo, downloadPath, localPath, manifestFiles in
                try self.verifyInstallTarget(
                    target,
                    repo: repo,
                    downloadPath: downloadPath,
                    localPath: localPath,
                    manifestFiles: manifestFiles
                )
            },
            selectModel: { model in
                self.app.selectedModelPath = model.ref.localURL
            },
            loadChatModel: { model in
                try await StudioChatService(app: self.app).loadModel(model.ref)
            },
            routeToChat: {
                self.app.mode = .chat
            },
            recordFailure: { request, message, error in
                self.recordInstallFailure(request: request, message: message, error: error)
            }
        ))
    }

    private func resolveInstalledModel(repo: String, localPath: URL?) async throws -> ModelSummary {
        let library = await app.engine.modelLibrary
        _ = await library.scan(force: true)
        let models = try await StudioModelService(app: app).listLocalModels()

        if let localPath {
            let target = localPath.resolvingSymlinksInPath().standardizedFileURL.path
            if let match = models.first(where: { model in
                model.ref.localURL?.resolvingSymlinksInPath().standardizedFileURL.path == target
            }) {
                return match
            }
        }

        if let exact = models.first(where: { $0.ref.displayName == repo }) {
            return exact
        }

        let repoLeaf = repo.split(separator: "/").last.map(String.init) ?? repo
        if let leafMatch = models.first(where: {
            $0.ref.displayName == repoLeaf || $0.ref.displayName.hasSuffix("/\(repoLeaf)")
        }) {
            return leafMatch
        }

        let cacheSlug = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        if let cacheMatch = models.first(where: {
            $0.ref.localURL?.path.contains(cacheSlug) == true
        }) {
            return cacheMatch
        }

        throw StudioServiceError.installedModelNotFound(repo)
    }

    private func verifyInstallTarget(
        _ target: ModelInstallTarget,
        repo: String,
        downloadPath: URL?,
        localPath: URL?,
        manifestFiles: [HuggingFaceDownloadSafety.RemoteFile]
    ) throws {
        guard let localPath else {
            throw StudioServiceError.installVerificationFailed(
                "Downloaded \(repo), but MLX Studio could not resolve a local model directory."
            )
        }

        switch target {
        case .chat:
            try ModelInstallReadinessVerifier.validateChatModel(
                repo: repo,
                localPath: localPath,
                manifestFiles: manifestFiles,
                manifestRoot: downloadPath ?? localPath
            )
        case .image(let runtimeName):
            if !manifestFiles.isEmpty {
                try HuggingFaceDownloadSafety.verifyManifest(
                    files: manifestFiles,
                    under: downloadPath ?? localPath
                )
            }
            try ImageModelInstallVerifier.validate(
                runtimeName: runtimeName,
                repo: repo,
                localPath: localPath,
                manifestFiles: []
            )
        }
    }

    private func recordInstallFailure(
        request: ModelInstallRequest,
        message: String,
        error: Error
    ) {
        let source: StudioDiagnosticSource
        let title: String
        switch request.target {
        case .chat:
            source = .modelInstall
            title = isVerificationError(error) ? "Model verification failed" : "Model install failed"
        case .image:
            source = .imageInstall
            title = isVerificationError(error) ? "Image model verification failed" : "Image model install failed"
        }

        StudioDiagnosticIssueStore.record(
            source: source,
            title: title,
            message: message,
            context: request.displayName
        )
    }

    private func isVerificationError(_ error: Error) -> Bool {
        if case StudioServiceError.installVerificationFailed = error {
            return true
        }
        return error is HuggingFaceDownloadSafety.VerificationFailure
            || error is ModelInstallReadinessVerifier.VerificationFailure
            || error is ImageModelInstallVerifier.VerificationFailure
    }
}

@MainActor
final class StudioServerService: ServerService {
    private let app: AppState

    init(app: AppState) {
        self.app = app
    }

    func startServer(config: ServerConfig) async throws {
        let localModels = try await StudioModelService(app: app).listLocalModels()
        let modelPath = try StudioServerModelCompatibility.resolveServerModelPath(
            selectedPath: app.selectedModelPath,
            localModels: localModels
        )
        if app.selectedModelPath == nil {
            app.selectedModelPath = modelPath
        }
        let id: UUID
        if let existing = app.sessionId(forModelPath: modelPath) {
            id = existing
        } else {
            id = await app.createSession(forModel: modelPath)
        }
        let engine = app.engine(for: id)
        var settings = await engine.settings.session(id) ?? SessionSettings(modelPath: modelPath)
        settings.host = config.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "127.0.0.1"
            : config.host.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.port = config.port
        settings.apiKey = config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : config.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = await engine.applySessionSettings(id, settings)
        if let index = app.sessions.firstIndex(where: { $0.id == id }) {
            app.sessions[index].host = settings.host ?? "127.0.0.1"
            app.sessions[index].port = settings.port ?? config.port
        }
        await app.startSession(id)
        try await verifyStartedSession(id)
    }

    func stopServer() async throws {
        if let id = app.selectedServerSessionId ?? app.sessions.first?.id {
            await app.stopSession(id)
        } else {
            await app.engine.stop()
        }
    }

    func health() async throws -> ServerHealth {
        let session = app.sessions.first { $0.id == app.selectedServerSessionId }
            ?? app.sessions.first
        let endpoint = session.map {
            StudioServerCommandFormatter.endpoint(host: $0.host, port: $0.port)
        } ?? StudioServerCommandFormatter.endpoint(host: "127.0.0.1", port: 8000)
        let state = session?.state ?? app.engineState
        let activeAPIKey: String
        if let session {
            let resolved = await app.engine(for: session.id).settings.resolved(sessionId: session.id)
            activeAPIKey = (resolved.settings.apiKey ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            activeAPIKey = ""
        }

        switch state {
        case .stopped:
            return ServerHealth(status: .stopped, label: "Stopped", endpoint: endpoint, apiKey: activeAPIKey)
        case .loading(let progress):
            return ServerHealth(status: .loading, label: progress.label, endpoint: endpoint, apiKey: activeAPIKey)
        case .running:
            return ServerHealth(status: .running, label: "Running", endpoint: endpoint, apiKey: activeAPIKey)
        case .standby:
            return ServerHealth(status: .sleeping, label: "Sleeping", endpoint: endpoint, apiKey: activeAPIKey)
        case .error(let message):
            return ServerHealth(status: .failed, label: message, endpoint: endpoint, apiKey: activeAPIKey)
        }
    }

    func routeCatalog() -> [APIRoute] {
        RouteCatalog.all.map { route in
            APIRoute(
                method: route.method.rawValue,
                path: route.path,
                family: route.family.rawValue,
                summary: route.brief,
                streams: route.streams
            )
        }
    }

    private func verifyStartedSession(_ id: UUID) async throws {
        var latestFailure = "Server did not report a running listener."
        for _ in 0..<20 {
            let session = app.sessions.first { $0.id == id }
            let http = app.httpServers[id]
            let httpRunning: Bool
            let httpError: String?
            if let http {
                httpRunning = await http.isRunning
                httpError = await http.lastError
            } else {
                httpRunning = false
                httpError = nil
            }
            let failure = StudioServerLifecycleGuard.startFailureMessage(
                sessionState: session?.state,
                hasSessionProcess: session?.pid != nil,
                httpRunning: httpRunning,
                httpError: httpError
            )
            guard let failure else { return }
            latestFailure = failure
            if httpError != nil {
                break
            }
            if case .error = session?.state {
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        throw StudioServiceError.serverStartFailed(latestFailure)
    }
}

@MainActor
final class StudioAdvancedModelService: AdvancedModelService {
    private let app: AppState
    private let jobs: StudioJobService

    init(app: AppState, jobs: StudioJobService) {
        self.app = app
        self.jobs = jobs
    }

    func inspect(_ model: ModelRef) async throws -> ModelInspection {
        guard let url = model.localURL else { throw StudioServiceError.modelNotLocal }
        let data = Self.firstJSONData(named: ["config.json", "model_index.json"], under: url)
        let object = data.flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        } ?? [:]
        let keys = object.keys.sorted()
        let tokenizerPresent = Self.containsFile(
            named: ["tokenizer.json", "tokenizer.model", "vocab.json", "tokenizer_config.json"],
            under: url
        )
        let shardCount = Self.countFiles(withExtensions: ["safetensors"], under: url)
        let size = directorySize(url)
        let family = (object["model_type"] as? String)
            ?? ((object["text_config"] as? [String: Any])?["model_type"] as? String)
            ?? Self.inferredFamily(for: model)

        return ModelInspection(
            model: model,
            family: family,
            modality: Self.inferredModality(for: model),
            sizeBytes: size,
            configKeys: keys,
            tokenizerPresent: tokenizerPresent,
            safetensorShardCount: shardCount,
            notes: [
                tokenizerPresent ? "Tokenizer present" : "Tokenizer not found",
                shardCount > 0 ? "\(shardCount) safetensors shard(s)" : "No safetensors shards found"
            ]
        )
    }

    private static func firstJSONData(named names: Set<String>, under url: URL) -> Data? {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let item as URL in enumerator where names.contains(item.lastPathComponent) {
            if let data = try? Data(contentsOf: item) {
                return data
            }
        }
        return nil
    }

    private static func containsFile(named names: Set<String>, under url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        for case let item as URL in enumerator where names.contains(item.lastPathComponent) {
            return true
        }
        return false
    }

    private static func countFiles(withExtensions extensions: Set<String>, under url: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var count = 0
        for case let item as URL in enumerator where extensions.contains(item.pathExtension.lowercased()) {
            count += 1
        }
        return count
    }

    private static func inferredFamily(for model: ModelRef) -> String {
        let text = "\(model.displayName) \(model.repo ?? "") \(model.localURL?.path ?? "")".lowercased()
        if text.contains("flux") { return "flux" }
        if text.contains("qwen") { return "qwen" }
        if text.contains("llama") { return "llama" }
        if text.contains("mistral") { return "mistral" }
        return "unknown"
    }

    private static func inferredModality(for model: ModelRef) -> String {
        let text = "\(model.displayName) \(model.repo ?? "") \(model.localURL?.path ?? "")".lowercased()
        if text.contains("flux") || text.contains("z-image") || text.contains("stable-diffusion") {
            return "image"
        }
        return "text"
    }

    func validate(_ model: ModelRef, suite: ValidationSuite) async throws -> JobID {
        let id = jobs.start(kind: .validate, model: model, message: "Queued validation")
        Task { @MainActor in
            jobs.update(id, status: .running, progress: 0.2, message: "Inspecting model files")
            do {
                let inspection = try await inspect(model)
                guard inspection.tokenizerPresent else {
                    throw StudioServiceError.validationFailed(
                        "Validation failed: tokenizer required before validation."
                    )
                }
                jobs.update(id, status: .completed, progress: 1.0, message: "Validation passed")
            } catch {
                jobs.update(id, status: .failed, progress: 1.0, message: error.localizedDescription)
                StudioAdvancedModelDiagnostic.recordFailure(
                    kind: .validate,
                    model: model,
                    message: error.localizedDescription
                )
            }
        }
        return id
    }

    func benchmark(_ model: ModelRef, config: BenchmarkConfig) async throws -> JobID {
        let id = jobs.start(kind: .benchmark, model: model, message: "Queued benchmark")
        Task { @MainActor in
            jobs.update(id, status: .running, progress: 0.1, message: "Running decode benchmark")
            let suite = Engine.BenchSuite(rawValue: config.suite) ?? .decode256
            do {
                for try await event in await app.engine.benchmark(suite: suite) {
                    switch event {
                    case .progress(let fraction, let label):
                        jobs.update(id, status: .running, progress: fraction, message: label)
                    case .done(let report):
                        let output = try writeBenchmarkReport(report)
                        jobs.update(id, status: .completed, progress: 1.0, outputPath: output, message: "Benchmark complete")
                    case .failed(let message):
                        jobs.update(id, status: .failed, progress: 1.0, message: message)
                        StudioAdvancedModelDiagnostic.recordFailure(
                            kind: .benchmark,
                            model: model,
                            message: message
                        )
                    }
                }
            } catch {
                jobs.update(id, status: .failed, progress: 1.0, message: error.localizedDescription)
                StudioAdvancedModelDiagnostic.recordFailure(
                    kind: .benchmark,
                    model: model,
                    message: error.localizedDescription
                )
            }
        }
        return id
    }

    func package(_ model: ModelRef, options: PackageOptions) async throws -> JobID {
        let id = jobs.start(kind: .package, model: model, message: "Writing metadata report")
        do {
            let inspection = try await inspect(model)
            let output = try writeInspectionReport(inspection)
            jobs.update(id, status: .completed, progress: 1.0, outputPath: output, message: "Report exported")
        } catch {
            jobs.update(id, status: .failed, progress: 1.0, message: error.localizedDescription)
            StudioAdvancedModelDiagnostic.recordFailure(
                kind: .package,
                model: model,
                message: error.localizedDescription
            )
        }
        _ = options
        return id
    }

    private func writeInspectionReport(_ inspection: ModelInspection) throws -> URL {
        let dir = try reportsDirectory()
        let url = dir.appendingPathComponent("\(inspection.model.displayName.sanitizedFilename)-inspection.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(inspection).write(to: url)
        return url
    }

    private func writeBenchmarkReport(_ report: Engine.BenchReport) throws -> URL {
        let dir = try reportsDirectory()
        let url = dir.appendingPathComponent("\(report.modelId.sanitizedFilename)-\(report.suite.rawValue)-benchmark.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url)
        return url
    }

    private func reportsDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("MLX Studio/Reports", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

@MainActor
final class StudioJobService: JobService {
    private var jobs: [JobID: ModelJob] = [:]
    private var order: [JobID] = []
    private var continuations: [JobID: [UUID: AsyncStream<JobEvent>.Continuation]] = [:]

    func start(kind: ModelJobKind, model: ModelRef, message: String) -> JobID {
        let id = UUID()
        let now = Date()
        let job = ModelJob(
            id: id,
            kind: kind,
            inputModel: model,
            outputPath: nil,
            status: .queued,
            progress: 0,
            logPath: nil,
            message: message,
            createdAt: now,
            updatedAt: now
        )
        jobs[id] = job
        order.insert(id, at: 0)
        broadcast(id, .updated(job))
        return id
    }

    func update(
        _ id: JobID,
        status: JobStatus,
        progress: Double?,
        outputPath: URL? = nil,
        message: String
    ) {
        guard var job = jobs[id] else { return }
        job.status = status
        job.progress = progress
        job.outputPath = outputPath ?? job.outputPath
        job.message = message
        job.updatedAt = Date()
        jobs[id] = job
        broadcast(id, .updated(job))
        broadcast(id, .log(message))
    }

    func listJobs() async throws -> [ModelJob] {
        order.compactMap { jobs[$0] }
    }

    func events(for id: JobID) -> AsyncStream<JobEvent> {
        AsyncStream { continuation in
            let token = UUID()
            continuations[id, default: [:]][token] = continuation
            if let job = jobs[id] {
                continuation.yield(.updated(job))
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in
                    self?.continuations[id]?.removeValue(forKey: token)
                }
            }
        }
    }

    func cancel(_ id: JobID) async throws {
        update(id, status: .cancelled, progress: nil, message: "Cancelled")
    }

    func retry(_ id: JobID) async throws -> JobID {
        guard let job = jobs[id] else { throw StudioServiceError.noSelectedModel }
        return start(kind: job.kind, model: job.inputModel, message: "Retry queued")
    }

    private func broadcast(_ id: JobID, _ event: JobEvent) {
        guard let values = continuations[id]?.values else { return }
        for continuation in values {
            continuation.yield(event)
        }
    }
}

@MainActor
final class StudioDiagnosticsService {
    private let app: AppState

    init(app: AppState) {
        self.app = app
    }

    func logSnapshot() async -> [LogStore.Line] {
        await app.engine.logs.snapshot()
    }

    func logStream() async -> AsyncStream<LogStore.Line> {
        await app.engine.logs.subscribe(minLevel: .info)
    }

    func metricsStream() async -> AsyncStream<MetricsCollector.Snapshot> {
        await app.engine.metrics.subscribe()
    }

    func recentIssues() -> [StudioDiagnosticIssue] {
        StudioDiagnosticIssueStore.load()
    }

    func clearIssues() {
        StudioDiagnosticIssueStore.clear()
    }
}

private extension ModelLibrary.ModelEntry {
    var modelRef: ModelRef {
        ModelRef(
            id: id,
            displayName: displayName,
            repo: nil,
            localURL: canonicalPath
        )
    }
}

private func directorySize(_ url: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(
        at: url,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else { return 0 }

    var total: Int64 = 0
    var seenResolvedFiles: Set<URL> = []
    for case let fileURL as URL in enumerator {
        let originalValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let resolvedURL = originalValues?.isSymbolicLink == true
            ? fileURL.resolvingSymlinksInPath()
            : fileURL
        let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { continue }
        let canonical = resolvedURL.standardizedFileURL
        if seenResolvedFiles.insert(canonical).inserted {
            total += Int64(values?.fileSize ?? originalValues?.fileSize ?? 0)
        }
    }
    return total
}

private func formattedHubSize(_ bytes: Int64?) -> String {
    guard let bytes, bytes > 0 else { return "Size unknown" }
    return formattedBytes(bytes)
}

private func formattedBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB, .useKB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}

private func formattedHubDate(_ date: Date?) -> String {
    guard let date else { return "Updated unknown" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return "Updated \(formatter.localizedString(for: date, relativeTo: Date()))"
}

private extension String {
    var sanitizedFilename: String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let scalars = unicodeScalars.map { scalar in
            allowed.contains(scalar) ? scalar : UnicodeScalar("-")
        }
        return String(String.UnicodeScalarView(scalars))
    }
}
