import Foundation

public enum GenerationMessageRole: String, Codable, CaseIterable, Hashable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct GenerationAttachment: Codable, Hashable, Sendable {
    public let url: URL
    public let mediaType: String
    public let name: String?

    public init(url: URL, mediaType: String, name: String? = nil) {
        self.url = url
        self.mediaType = mediaType
        self.name = name
    }
}

public struct GenerationMessage: Codable, Hashable, Sendable {
    public let role: GenerationMessageRole
    public let content: String
    public let name: String?
    public let toolCallID: String?
    public let attachments: [GenerationAttachment]

    public init(
        role: GenerationMessageRole,
        content: String,
        name: String? = nil,
        toolCallID: String? = nil,
        attachments: [GenerationAttachment] = []
    ) {
        self.role = role
        self.content = content
        self.name = name
        self.toolCallID = toolCallID
        self.attachments = attachments
    }
}

public struct GenerationConfiguration: Codable, Hashable, Sendable {
    public var maximumTokenCount: Int
    public var temperature: Double
    public var topP: Double
    public var repetitionPenalty: Double?
    public var seed: UInt64?
    public var stopSequences: [String]

    public init(
        maximumTokenCount: Int = 512,
        temperature: Double = 0.7,
        topP: Double = 0.95,
        repetitionPenalty: Double? = nil,
        seed: UInt64? = nil,
        stopSequences: [String] = []
    ) {
        self.maximumTokenCount = maximumTokenCount
        self.temperature = temperature
        self.topP = topP
        self.repetitionPenalty = repetitionPenalty
        self.seed = seed
        self.stopSequences = stopSequences
    }
}

public struct InferenceTraceOptions: Codable, Hashable, Sendable {
    public var capturesExpertRouting: Bool
    public var capturesTokenScores: Bool

    public init(
        capturesExpertRouting: Bool = false,
        capturesTokenScores: Bool = false
    ) {
        self.capturesExpertRouting = capturesExpertRouting
        self.capturesTokenScores = capturesTokenScores
    }
}

public struct GenerationRequest: Codable, Hashable, Sendable {
    public let id: GenerationID
    public let artifactID: ModelArtifactID
    public var messages: [GenerationMessage]
    public var configuration: GenerationConfiguration
    public var traceOptions: InferenceTraceOptions
    public var metadata: [String: String]

    public init(
        id: GenerationID = .init(),
        artifactID: ModelArtifactID,
        messages: [GenerationMessage],
        configuration: GenerationConfiguration = .init(),
        traceOptions: InferenceTraceOptions = .init(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.artifactID = artifactID
        self.messages = messages
        self.configuration = configuration
        self.traceOptions = traceOptions
        self.metadata = metadata
    }
}

public struct RuntimeMetrics: Codable, Hashable, Sendable {
    public var promptTokenCount: Int
    public var generatedTokenCount: Int
    public var cachedTokenCount: Int
    public var timeToFirstTokenSeconds: Double?
    public var prefillDurationSeconds: Double?
    public var generationDurationSeconds: Double
    public var totalDurationSeconds: Double?
    public var tokensPerSecond: Double?
    public var promptTokensPerSecond: Double?
    public var peakMemoryBytes: Int64?
    public var cacheDetail: String?
    public var isPartial: Bool

    public init(
        promptTokenCount: Int = 0,
        generatedTokenCount: Int = 0,
        cachedTokenCount: Int = 0,
        timeToFirstTokenSeconds: Double? = nil,
        prefillDurationSeconds: Double? = nil,
        generationDurationSeconds: Double = 0,
        totalDurationSeconds: Double? = nil,
        tokensPerSecond: Double? = nil,
        promptTokensPerSecond: Double? = nil,
        peakMemoryBytes: Int64? = nil,
        cacheDetail: String? = nil,
        isPartial: Bool = false
    ) {
        self.promptTokenCount = promptTokenCount
        self.generatedTokenCount = generatedTokenCount
        self.cachedTokenCount = cachedTokenCount
        self.timeToFirstTokenSeconds = timeToFirstTokenSeconds
        self.prefillDurationSeconds = prefillDurationSeconds
        self.generationDurationSeconds = generationDurationSeconds
        self.totalDurationSeconds = totalDurationSeconds
        self.tokensPerSecond = tokensPerSecond
        self.promptTokensPerSecond = promptTokensPerSecond
        self.peakMemoryBytes = peakMemoryBytes
        self.cacheDetail = cacheDetail
        self.isPartial = isPartial
    }
}

public struct ExpertRoutingObservation: Codable, Hashable, Sendable {
    public let layerIndex: Int
    public let tokenIndex: Int
    public let selectedExpertIndices: [Int]
    public let gateWeights: [Double]

    public init(
        layerIndex: Int,
        tokenIndex: Int,
        selectedExpertIndices: [Int],
        gateWeights: [Double]
    ) {
        self.layerIndex = layerIndex
        self.tokenIndex = tokenIndex
        self.selectedExpertIndices = selectedExpertIndices
        self.gateWeights = gateWeights
    }
}

public struct InferenceTrace: Codable, Hashable, Sendable {
    public var expertRouting: [ExpertRoutingObservation]
    public var tokenScores: [Double]
    public var metadata: [String: String]

    public init(
        expertRouting: [ExpertRoutingObservation] = [],
        tokenScores: [Double] = [],
        metadata: [String: String] = [:]
    ) {
        self.expertRouting = expertRouting
        self.tokenScores = tokenScores
        self.metadata = metadata
    }
}

public struct GenerationResult: Codable, Hashable, Sendable {
    public let generationID: GenerationID
    public let artifactID: ModelArtifactID
    public let text: String
    public let reasoning: String?
    public let finishReason: GenerationFinishReason
    public let metrics: RuntimeMetrics
    public let trace: InferenceTrace?

    public init(
        generationID: GenerationID,
        artifactID: ModelArtifactID,
        text: String,
        reasoning: String? = nil,
        finishReason: GenerationFinishReason,
        metrics: RuntimeMetrics = .init(),
        trace: InferenceTrace? = nil
    ) {
        self.generationID = generationID
        self.artifactID = artifactID
        self.text = text
        self.reasoning = reasoning
        self.finishReason = finishReason
        self.metrics = metrics
        self.trace = trace
    }
}

public enum GenerationEvent: Codable, Hashable, Sendable {
    case started(GenerationID)
    case textDelta(String)
    case reasoningDelta(String)
    case trace(ExpertRoutingObservation)
    case metrics(RuntimeMetrics)
    case completed(GenerationResult)
}

/// The sole production inference boundary consumed by Chat, Evaluate, validation, and Serve.
public protocol ModelInferenceProvider: Sendable {
    func events(for request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error>
}
