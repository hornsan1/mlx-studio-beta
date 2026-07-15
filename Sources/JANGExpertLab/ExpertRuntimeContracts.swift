import Foundation

public enum ExpertInferenceMetadataKey {
    public static let traceEnabled = "expert_lab.trace_enabled"
    public static let traceMaximumTokens = "expert_lab.trace_maximum_tokens"
    public static let topK = "expert_lab.top_k"
    public static let maskJSON = "expert_lab.mask_json"
    public static let maskApplied = "expert_lab.mask_applied"
    public static let backend = "expert_lab.backend"
    public static let runtimeMode = "expert_lab.runtime_mode"
    public static let deviceName = "expert_lab.device_name"
    public static let metalEnabled = "expert_lab.metal_enabled"
    public static let sourceModelPath = "expert_lab.source_model_path"
    public static let hookedMOELayers = "expert_lab.hooked_moe_layers"
    public static let expectedMOELayers = "expert_lab.expected_moe_layers"
    public static let hookCoverageComplete = "expert_lab.hook_coverage_complete"
}

public enum ExpertGenerationFinishReason: String, Codable, Equatable, Sendable {
    case stop
    case maxTokens
    case cancelled
    case error
}

public struct ExpertSamplingConfiguration: Codable, Equatable, Sendable {
    public var temperature: Double
    public var topP: Double
    public var topK: Int
    public var maxTokens: Int

    public init(
        temperature: Double = 0,
        topP: Double = 1,
        topK: Int = 0,
        maxTokens: Int = 200
    ) {
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.maxTokens = maxTokens
    }
}

public struct ExpertMask: Codable, Equatable, Sendable {
    public var layers: [Int: Set<Int>]
    public var lockedKeepByLayer: [Int: Set<Int>]
    public var topKOverride: Int?

    public init(
        layers: [Int: Set<Int>] = [:],
        lockedKeepByLayer: [Int: Set<Int>] = [:],
        topKOverride: Int? = nil
    ) {
        self.layers = layers
        self.lockedKeepByLayer = lockedKeepByLayer
        self.topKOverride = topKOverride
    }

    public var disabledExpertsByLayer: [Int: Set<Int>] {
        get { layers }
        set { layers = newValue }
    }

    public func disabledExperts(for layer: Int) -> Set<Int> {
        layers[layer] ?? []
    }

    public func lockedKeepExperts(for layer: Int) -> Set<Int> {
        lockedKeepByLayer[layer] ?? []
    }
}

public struct ExpertTraceConfiguration: Codable, Equatable, Sendable {
    public var mask: ExpertMask?
    public var emitTokenTrace: Bool
    public var maxTraceTokens: Int

    public init(
        mask: ExpertMask? = nil,
        emitTokenTrace: Bool = true,
        maxTraceTokens: Int = 512
    ) {
        self.mask = mask
        self.emitTokenTrace = emitTokenTrace
        self.maxTraceTokens = max(0, maxTraceTokens)
    }
}

public struct ExpertRouteRecord: Codable, Equatable, Sendable {
    public let tokenIndex: Int
    public let layer: Int
    public let selectedExperts: [Int]
    public let scores: [Float]
    public let disabledExperts: [Int]
    public let effectiveTopK: Int
    public let entropy: Float?

    public init(
        tokenIndex: Int,
        layer: Int,
        selectedExperts: [Int],
        scores: [Float],
        disabledExperts: [Int] = [],
        effectiveTopK: Int,
        entropy: Float? = nil
    ) {
        self.tokenIndex = tokenIndex
        self.layer = layer
        self.selectedExperts = selectedExperts
        self.scores = scores
        self.disabledExperts = disabledExperts
        self.effectiveTopK = effectiveTopK
        self.entropy = entropy
    }
}

public struct ExpertLayerStats: Codable, Equatable, Sendable {
    public let layer: Int
    public let tokenCount: Int
    public let hitCounts: [Int: Int]
    public let probabilityMass: [Int: Float]

    public init(
        layer: Int,
        tokenCount: Int,
        hitCounts: [Int: Int],
        probabilityMass: [Int: Float]
    ) {
        self.layer = layer
        self.tokenCount = tokenCount
        self.hitCounts = hitCounts
        self.probabilityMass = probabilityMass
    }
}

public struct ExpertModelRuntimeInfo: Codable, Equatable, Sendable {
    public let backend: String
    public let runtimeMode: String
    public let deviceName: String
    public let deviceRecommendedMaxWorkingSetGB: Double?
    public let metalEnabled: Bool
    public let jangToolsVersion: String?
    public let mlxVersion: String?
    public let mlxLMVersion: String?
    public let mlxVLMVersion: String?
    public let sourceModelPath: String?
    public let hookedMOELayers: Int?
    public let expectedMOELayers: Int?
    public let hookCoverageComplete: Bool?
    public let maskApplied: Bool?
    public let disabledExpertCount: Int?
    public let topKOverride: Int?
    public let notes: [String]

    public init(
        backend: String,
        runtimeMode: String,
        deviceName: String,
        deviceRecommendedMaxWorkingSetGB: Double? = nil,
        metalEnabled: Bool,
        jangToolsVersion: String? = nil,
        mlxVersion: String? = nil,
        mlxLMVersion: String? = nil,
        mlxVLMVersion: String? = nil,
        sourceModelPath: String? = nil,
        hookedMOELayers: Int? = nil,
        expectedMOELayers: Int? = nil,
        hookCoverageComplete: Bool? = nil,
        maskApplied: Bool? = nil,
        disabledExpertCount: Int? = nil,
        topKOverride: Int? = nil,
        notes: [String] = []
    ) {
        self.backend = backend
        self.runtimeMode = runtimeMode
        self.deviceName = deviceName
        self.deviceRecommendedMaxWorkingSetGB = deviceRecommendedMaxWorkingSetGB
        self.metalEnabled = metalEnabled
        self.jangToolsVersion = jangToolsVersion
        self.mlxVersion = mlxVersion
        self.mlxLMVersion = mlxLMVersion
        self.mlxVLMVersion = mlxVLMVersion
        self.sourceModelPath = sourceModelPath
        self.hookedMOELayers = hookedMOELayers
        self.expectedMOELayers = expectedMOELayers
        self.hookCoverageComplete = hookCoverageComplete
        self.maskApplied = maskApplied
        self.disabledExpertCount = disabledExpertCount
        self.topKOverride = topKOverride
        self.notes = notes
    }
}

public struct ExpertRunResult: Equatable, Sendable {
    public let text: String
    public let tokens: Int
    public let elapsedSeconds: Double
    public let tokensPerSecond: Double
    public let finishReason: ExpertGenerationFinishReason
    public let layerStats: [ExpertLayerStats]
    public let tokenTrace: [ExpertRouteRecord]?
    public let runtimeInfo: ExpertModelRuntimeInfo?

    public init(
        text: String,
        tokens: Int,
        elapsedSeconds: Double,
        tokensPerSecond: Double,
        finishReason: ExpertGenerationFinishReason,
        layerStats: [ExpertLayerStats],
        tokenTrace: [ExpertRouteRecord]?,
        runtimeInfo: ExpertModelRuntimeInfo? = nil
    ) {
        self.text = text
        self.tokens = tokens
        self.elapsedSeconds = elapsedSeconds
        self.tokensPerSecond = tokensPerSecond
        self.finishReason = finishReason
        self.layerStats = layerStats
        self.tokenTrace = tokenTrace
        self.runtimeInfo = runtimeInfo
    }
}
