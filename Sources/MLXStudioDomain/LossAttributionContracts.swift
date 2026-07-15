import Foundation

public enum LossAttributionVariant: String, Codable, CaseIterable, Hashable, Sendable {
    case baseOriginalPrecision = "a_base_original_precision"
    case baseQuantized = "b_base_quantized"
    case prunedOriginalPrecision = "c_pruned_original_precision"
    case prunedQuantized = "d_pruned_quantized"

    public var code: String {
        switch self {
        case .baseOriginalPrecision: "A"
        case .baseQuantized: "B"
        case .prunedOriginalPrecision: "C"
        case .prunedQuantized: "D"
        }
    }

    public var displayName: String {
        switch self {
        case .baseOriginalPrecision: "Base, original precision"
        case .baseQuantized: "Base, quantized"
        case .prunedOriginalPrecision: "Pruned, original precision"
        case .prunedQuantized: "Pruned and quantized"
        }
    }
}

public struct LossAttributionArtifact: Codable, Hashable, Sendable {
    public let variant: LossAttributionVariant
    public let artifactID: ModelArtifactID
    public let artifactHash: String?

    public init(
        variant: LossAttributionVariant,
        artifactID: ModelArtifactID,
        artifactHash: String? = nil
    ) {
        self.variant = variant
        self.artifactID = artifactID
        self.artifactHash = artifactHash
    }
}

public enum LossAttributionComparisonKind: String, Codable, CaseIterable, Hashable, Sendable {
    case baseQuantization = "a_vs_b_quantization"
    case pruning = "a_vs_c_pruning"
    case quantizationAfterPruning = "c_vs_d_quantization_after_pruning"
    case totalDeployment = "a_vs_d_total_deployment"

    public var sourceVariant: LossAttributionVariant {
        switch self {
        case .baseQuantization, .pruning, .totalDeployment: .baseOriginalPrecision
        case .quantizationAfterPruning: .prunedOriginalPrecision
        }
    }

    public var targetVariant: LossAttributionVariant {
        switch self {
        case .baseQuantization: .baseQuantized
        case .pruning: .prunedOriginalPrecision
        case .quantizationAfterPruning, .totalDeployment: .prunedQuantized
        }
    }

    public var displayName: String {
        switch self {
        case .baseQuantization: "A vs B — quantization effect"
        case .pruning: "A vs C — pruning effect"
        case .quantizationAfterPruning: "C vs D — quantization after pruning"
        case .totalDeployment: "A vs D — total deployment effect"
        }
    }
}

public enum LossAttributionMeasurementState: String, Codable, Hashable, Sendable {
    case measured
    case notEvaluated
    case missingSource
    case missingTarget
    case missingBoth
}

public struct LossAttributionComparisonPlan: Codable, Hashable, Sendable {
    public let kind: LossAttributionComparisonKind
    public let state: LossAttributionMeasurementState

    public init(
        kind: LossAttributionComparisonKind,
        state: LossAttributionMeasurementState
    ) {
        self.kind = kind
        self.state = state
    }
}

public struct LossAttributionExperimentPlan: Codable, Hashable, Sendable {
    public let artifacts: [LossAttributionArtifact]
    public let comparisons: [LossAttributionComparisonPlan]
    public let missingVariants: [LossAttributionVariant]
    public let usesFullMatrix: Bool

    public init(
        artifacts: [LossAttributionArtifact],
        comparisons: [LossAttributionComparisonPlan],
        missingVariants: [LossAttributionVariant],
        usesFullMatrix: Bool
    ) {
        self.artifacts = artifacts
        self.comparisons = comparisons
        self.missingVariants = missingVariants
        self.usesFullMatrix = usesFullMatrix
    }
}

/// Measured values for one artifact variant. Optional fields stay unavailable
/// rather than being inferred from unrelated proxies.
public struct LossAttributionObservation: Codable, Hashable, Sendable {
    public let variant: LossAttributionVariant
    public let artifactID: ModelArtifactID
    public let qualityScore: Double?
    public let artifactSizeBytes: Int64?
    public let peakMemoryBytes: Int64?
    public let generatedTokensPerSecond: Double?

    public init(
        variant: LossAttributionVariant,
        artifactID: ModelArtifactID,
        qualityScore: Double? = nil,
        artifactSizeBytes: Int64? = nil,
        peakMemoryBytes: Int64? = nil,
        generatedTokensPerSecond: Double? = nil
    ) {
        self.variant = variant
        self.artifactID = artifactID
        self.qualityScore = qualityScore
        self.artifactSizeBytes = artifactSizeBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.generatedTokensPerSecond = generatedTokensPerSecond
    }
}

public struct LossAttributionQualityReport: Codable, Hashable, Sendable {
    public let sourceScore: Double
    public let targetScore: Double
    public let change: Double
    public let loss: Double

    public init(sourceScore: Double, targetScore: Double) {
        self.sourceScore = sourceScore
        self.targetScore = targetScore
        self.change = targetScore - sourceScore
        self.loss = max(0, sourceScore - targetScore)
    }
}

public struct LossAttributionPerformanceReport: Codable, Hashable, Sendable {
    public let storageSavingsFraction: Double?
    public let peakMemorySavingsFraction: Double?
    public let generationRateChangeFraction: Double?

    public init(
        storageSavingsFraction: Double? = nil,
        peakMemorySavingsFraction: Double? = nil,
        generationRateChangeFraction: Double? = nil
    ) {
        self.storageSavingsFraction = storageSavingsFraction
        self.peakMemorySavingsFraction = peakMemorySavingsFraction
        self.generationRateChangeFraction = generationRateChangeFraction
    }
}

public struct LossAttributionHumanPreferenceReport: Codable, Hashable, Sendable {
    public let sourcePreferredCount: Int
    public let targetPreferredCount: Int
    public let tieCount: Int
    public let bothFailedCount: Int

    public init(
        sourcePreferredCount: Int = 0,
        targetPreferredCount: Int = 0,
        tieCount: Int = 0,
        bothFailedCount: Int = 0
    ) {
        self.sourcePreferredCount = sourcePreferredCount
        self.targetPreferredCount = targetPreferredCount
        self.tieCount = tieCount
        self.bothFailedCount = bothFailedCount
    }

    public var judgmentCount: Int {
        sourcePreferredCount + targetPreferredCount + tieCount + bothFailedCount
    }
}

public struct LossAttributionComparisonReport: Codable, Hashable, Sendable {
    public let kind: LossAttributionComparisonKind
    public let state: LossAttributionMeasurementState
    public let quality: LossAttributionQualityReport?
    public let performance: LossAttributionPerformanceReport?
    public let humanPreference: LossAttributionHumanPreferenceReport

    public init(
        kind: LossAttributionComparisonKind,
        state: LossAttributionMeasurementState,
        quality: LossAttributionQualityReport? = nil,
        performance: LossAttributionPerformanceReport? = nil,
        humanPreference: LossAttributionHumanPreferenceReport = .init()
    ) {
        self.kind = kind
        self.state = state
        self.quality = quality
        self.performance = performance
        self.humanPreference = humanPreference
    }
}

public struct LossAttributionReport: Codable, Hashable, Sendable {
    public let runID: EvaluationRunID
    public let plan: LossAttributionExperimentPlan
    public let comparisons: [LossAttributionComparisonReport]
    public let qualityInteractionEffect: Double?

    public init(
        runID: EvaluationRunID,
        plan: LossAttributionExperimentPlan,
        comparisons: [LossAttributionComparisonReport],
        qualityInteractionEffect: Double? = nil
    ) {
        self.runID = runID
        self.plan = plan
        self.comparisons = comparisons
        self.qualityInteractionEffect = qualityInteractionEffect
    }
}
