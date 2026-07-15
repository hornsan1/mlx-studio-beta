import Foundation

public struct OptimizationObjective: Codable, Hashable, Sendable {
    public var maximumArtifactSizeBytes: Int64?
    public var maximumPeakMemoryBytes: Int64?
    public var minimumQualityScore: Double?
    public var targetTokensPerSecond: Double?
    public var notes: String?

    public init(
        maximumArtifactSizeBytes: Int64? = nil,
        maximumPeakMemoryBytes: Int64? = nil,
        minimumQualityScore: Double? = nil,
        targetTokensPerSecond: Double? = nil,
        notes: String? = nil
    ) {
        self.maximumArtifactSizeBytes = maximumArtifactSizeBytes
        self.maximumPeakMemoryBytes = maximumPeakMemoryBytes
        self.minimumQualityScore = minimumQualityScore
        self.targetTokensPerSecond = targetTokensPerSecond
        self.notes = notes
    }
}

/// Predicted values. Completed build/runtime measurements use artifact and evaluation records instead.
public struct OptimizationEstimate: Codable, Hashable, Sendable {
    /// Predictions are never presented as measured build or evaluation results.
    public static let displayLabel = "Estimate"

    public var artifactSizeBytes: Int64?
    public var peakMemoryBytes: Int64?
    public var qualityScore: Double?
    public var tokensPerSecond: Double?
    public var confidence: Double?

    public init(
        artifactSizeBytes: Int64? = nil,
        peakMemoryBytes: Int64? = nil,
        qualityScore: Double? = nil,
        tokensPerSecond: Double? = nil,
        confidence: Double? = nil
    ) {
        self.artifactSizeBytes = artifactSizeBytes
        self.peakMemoryBytes = peakMemoryBytes
        self.qualityScore = qualityScore
        self.tokensPerSecond = tokensPerSecond
        self.confidence = confidence
    }

    public var displayLabel: String { Self.displayLabel }
}

public struct ExpertCoordinate: Codable, Hashable, Sendable {
    public let layerIndex: Int
    public let expertIndex: Int

    public init(layerIndex: Int, expertIndex: Int) {
        self.layerIndex = layerIndex
        self.expertIndex = expertIndex
    }
}

public enum ExpertDirectiveAction: String, Codable, CaseIterable, Hashable, Sendable {
    case automatic = "auto"
    case keep
    case remove
}

public struct ExpertDirective: Codable, Hashable, Sendable {
    public let coordinate: ExpertCoordinate
    public var action: ExpertDirectiveAction

    public init(coordinate: ExpertCoordinate, action: ExpertDirectiveAction) {
        self.coordinate = coordinate
        self.action = action
    }
}

public struct PruningConstraints: Codable, Hashable, Sendable {
    public var minimumSurvivorsPerLayer: Int
    public var maximumRemovalFraction: Double
    public var protectedExperts: Set<ExpertCoordinate>

    public init(
        minimumSurvivorsPerLayer: Int = 1,
        maximumRemovalFraction: Double = 0,
        protectedExperts: Set<ExpertCoordinate> = []
    ) {
        self.minimumSurvivorsPerLayer = minimumSurvivorsPerLayer
        self.maximumRemovalFraction = maximumRemovalFraction
        self.protectedExperts = protectedExperts
    }
}

public struct ExpertLayerTopology: Codable, Hashable, Sendable {
    public let layerIndex: Int
    public let expertCount: Int
    public let trainedTopK: Int

    public init(layerIndex: Int, expertCount: Int, trainedTopK: Int) {
        self.layerIndex = layerIndex
        self.expertCount = expertCount
        self.trainedTopK = trainedTopK
    }
}

public struct ModelExpertTopology: Codable, Hashable, Sendable {
    public let architecture: String
    public let layers: [ExpertLayerTopology]

    public init(architecture: String, layers: [ExpertLayerTopology]) {
        self.architecture = architecture
        self.layers = layers
    }
}

/// A normalized, serialization-stable mask. Expert indices are sorted and unique.
public struct StructuralExpertMask: Codable, Hashable, Sendable {
    public let removedExpertsByLayer: [Int: [Int]]

    public init(removedExpertsByLayer: [Int: [Int]]) {
        self.removedExpertsByLayer = removedExpertsByLayer.reduce(into: [:]) { result, entry in
            let experts = Array(Set(entry.value)).sorted()
            if !experts.isEmpty {
                result[entry.key] = experts
            }
        }
    }

    public func removedExperts(inLayer layerIndex: Int) -> Set<Int> {
        Set(removedExpertsByLayer[layerIndex] ?? [])
    }

    public var removalCount: Int {
        removedExpertsByLayer.values.reduce(0) { $0 + $1.count }
    }
}

public struct OptimizationPlanValidation: Codable, Hashable, Sendable {
    public let result: PlanValidationResult
    public let structuralMask: StructuralExpertMask?

    public init(result: PlanValidationResult, structuralMask: StructuralExpertMask?) {
        self.result = result
        self.structuralMask = structuralMask
    }

    public var isExecutable: Bool {
        result.status == .valid && structuralMask != nil
    }
}

public enum QuantizationTechnology: String, Codable, CaseIterable, Hashable, Sendable {
    case jang
    case jangTQ = "jangtq"
}

public struct QuantizationRecipe: Codable, Hashable, Sendable {
    public let id: QuantizationRecipeID
    public var name: String
    public var technology: QuantizationTechnology
    public var profile: String
    public var calibrationSuiteID: EvaluationSuiteID?
    public var tensorRoleRules: [String: String]
    public var schemaVersion: Int

    public init(
        id: QuantizationRecipeID = .init(),
        name: String,
        technology: QuantizationTechnology,
        profile: String,
        calibrationSuiteID: EvaluationSuiteID? = nil,
        tensorRoleRules: [String: String] = [:],
        schemaVersion: Int = 1
    ) {
        self.id = id
        self.name = name
        self.technology = technology
        self.profile = profile
        self.calibrationSuiteID = calibrationSuiteID
        self.tensorRoleRules = tensorRoleRules
        self.schemaVersion = schemaVersion
    }
}

public enum PlanValidationStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case unchecked
    case valid
    case invalid
}

public struct PlanValidationResult: Codable, Hashable, Sendable {
    public let status: PlanValidationStatus
    public let errors: [String]
    public let warnings: [String]

    public init(
        status: PlanValidationStatus,
        errors: [String] = [],
        warnings: [String] = []
    ) {
        self.status = status
        self.errors = errors
        self.warnings = warnings
    }
}

public enum StrategyMaturity: String, Codable, CaseIterable, Hashable, Sendable {
    case production
    case experimental
}

public struct StrategyDescriptor: Codable, Hashable, Sendable {
    public let identifier: StrategyIdentifier
    public let version: String
    public let maturity: StrategyMaturity
    public let supportedArchitectures: Set<String>

    public init(
        identifier: StrategyIdentifier,
        version: String,
        maturity: StrategyMaturity,
        supportedArchitectures: Set<String>
    ) {
        self.identifier = identifier
        self.version = version
        self.maturity = maturity
        self.supportedArchitectures = supportedArchitectures
    }
}

public struct OptimizationPlan: Codable, Hashable, Sendable {
    public let id: OptimizationPlanID
    public let projectID: ModelProjectID
    public let sourceArtifactID: ModelArtifactID
    public var objective: OptimizationObjective
    public var strategy: StrategyDescriptor?
    public var pruningConstraints: PruningConstraints
    /// Strategy-selected removals before Auto/Keep/Remove user directives are resolved.
    public var strategyProposedRemovals: Set<ExpertCoordinate>?
    public var expertDirectives: [ExpertDirective]
    public var quantizationRecipe: QuantizationRecipe?
    public var estimate: OptimizationEstimate?
    public var validation: PlanValidationResult
    public var schemaVersion: Int
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: OptimizationPlanID = .init(),
        projectID: ModelProjectID,
        sourceArtifactID: ModelArtifactID,
        objective: OptimizationObjective,
        strategy: StrategyDescriptor? = nil,
        pruningConstraints: PruningConstraints = .init(),
        strategyProposedRemovals: Set<ExpertCoordinate>? = nil,
        expertDirectives: [ExpertDirective] = [],
        quantizationRecipe: QuantizationRecipe? = nil,
        estimate: OptimizationEstimate? = nil,
        validation: PlanValidationResult = .init(status: .unchecked),
        schemaVersion: Int = 1,
        createdAt: Date = .init(),
        updatedAt: Date = .init()
    ) {
        self.id = id
        self.projectID = projectID
        self.sourceArtifactID = sourceArtifactID
        self.objective = objective
        self.strategy = strategy
        self.pruningConstraints = pruningConstraints
        self.strategyProposedRemovals = strategyProposedRemovals
        self.expertDirectives = expertDirectives
        self.quantizationRecipe = quantizationRecipe
        self.estimate = estimate
        self.validation = validation
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct StrategyAnalysisRequest: Codable, Hashable, Sendable {
    public let id: StrategyAnalysisID
    public let projectID: ModelProjectID
    public let artifactID: ModelArtifactID
    public let calibrationSuiteID: EvaluationSuiteID
    public let objective: OptimizationObjective
    public let constraints: PruningConstraints
    public let evidenceReferences: [String: String]

    public init(
        id: StrategyAnalysisID = .init(),
        projectID: ModelProjectID,
        artifactID: ModelArtifactID,
        calibrationSuiteID: EvaluationSuiteID,
        objective: OptimizationObjective,
        constraints: PruningConstraints,
        evidenceReferences: [String: String] = [:]
    ) {
        self.id = id
        self.projectID = projectID
        self.artifactID = artifactID
        self.calibrationSuiteID = calibrationSuiteID
        self.objective = objective
        self.constraints = constraints
        self.evidenceReferences = evidenceReferences
    }
}

public struct StrategyAnalysisResult: Codable, Hashable, Sendable {
    public let analysisID: StrategyAnalysisID
    public let descriptor: StrategyDescriptor
    public let candidatePlans: [OptimizationPlan]
    public let warnings: [String]

    public init(
        analysisID: StrategyAnalysisID,
        descriptor: StrategyDescriptor,
        candidatePlans: [OptimizationPlan],
        warnings: [String] = []
    ) {
        self.analysisID = analysisID
        self.descriptor = descriptor
        self.candidatePlans = candidatePlans
        self.warnings = warnings
    }
}

public protocol PruningStrategy: Sendable {
    var descriptor: StrategyDescriptor { get }
    func proposeCandidates(for request: StrategyAnalysisRequest) async throws -> StrategyAnalysisResult
}
