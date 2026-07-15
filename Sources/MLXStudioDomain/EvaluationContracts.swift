import Foundation

public enum EvaluationExpectationKind: String, Codable, CaseIterable, Hashable, Sendable {
    case exact
    case contains
    case regularExpression
    case unitTest
    case custom
}

public struct EvaluationExpectation: Codable, Hashable, Sendable {
    public let kind: EvaluationExpectationKind
    public let value: String?
    public let scorerIdentifier: String?

    public init(
        kind: EvaluationExpectationKind,
        value: String? = nil,
        scorerIdentifier: String? = nil
    ) {
        self.kind = kind
        self.value = value
        self.scorerIdentifier = scorerIdentifier
    }
}

public struct EvaluationCase: Codable, Hashable, Sendable {
    public let id: EvaluationCaseID
    public let ordinal: Int
    public var name: String
    public var messages: [GenerationMessage]
    public var domain: String?
    public var tags: Set<String>
    public var expectation: EvaluationExpectation?
    public var generationConfiguration: GenerationConfiguration
    public var weight: Double

    public init(
        id: EvaluationCaseID = .init(),
        ordinal: Int,
        name: String,
        messages: [GenerationMessage],
        domain: String? = nil,
        tags: Set<String> = [],
        expectation: EvaluationExpectation? = nil,
        generationConfiguration: GenerationConfiguration = .init(),
        weight: Double = 1
    ) {
        self.id = id
        self.ordinal = ordinal
        self.name = name
        self.messages = messages
        self.domain = domain
        self.tags = tags
        self.expectation = expectation
        self.generationConfiguration = generationConfiguration
        self.weight = weight
    }
}

public struct EvaluationSuite: Codable, Hashable, Sendable {
    public let id: EvaluationSuiteID
    public var name: String
    public var revision: String
    public var tags: Set<String>
    public var cases: [EvaluationCase]
    public var suiteHash: String

    public init(
        id: EvaluationSuiteID = .init(),
        name: String,
        revision: String,
        tags: Set<String> = [],
        cases: [EvaluationCase],
        suiteHash: String
    ) {
        self.id = id
        self.name = name
        self.revision = revision
        self.tags = tags
        self.cases = cases
        self.suiteHash = suiteHash
    }
}

public struct EvaluationCandidate: Codable, Hashable, Sendable {
    public let artifactID: ModelArtifactID
    public let blindLabel: String
    public let artifactHash: String?

    public init(
        artifactID: ModelArtifactID,
        blindLabel: String,
        artifactHash: String? = nil
    ) {
        self.artifactID = artifactID
        self.blindLabel = blindLabel
        self.artifactHash = artifactHash
    }
}

public struct EvaluationRunRequest: Codable, Hashable, Sendable {
    public let id: EvaluationRunID
    public let suite: EvaluationSuite
    public let candidates: [EvaluationCandidate]
    public let hardwareProfileID: HardwareProfileID?
    public let runtimeVersion: String?
    public let kernelVersion: String?
    public let executionOrder: [ModelArtifactID]
    public let createdAt: Date

    public init(
        id: EvaluationRunID = .init(),
        suite: EvaluationSuite,
        candidates: [EvaluationCandidate],
        hardwareProfileID: HardwareProfileID? = nil,
        runtimeVersion: String? = nil,
        kernelVersion: String? = nil,
        executionOrder: [ModelArtifactID],
        createdAt: Date = .init()
    ) {
        self.id = id
        self.suite = suite
        self.candidates = candidates
        self.hardwareProfileID = hardwareProfileID
        self.runtimeVersion = runtimeVersion
        self.kernelVersion = kernelVersion
        self.executionOrder = executionOrder
        self.createdAt = createdAt
    }
}

public struct EvaluationCaseManifest: Codable, Hashable, Sendable {
    public let caseID: EvaluationCaseID
    public let ordinal: Int
    public let messagesHash: String
    public let generationConfiguration: GenerationConfiguration

    public init(
        caseID: EvaluationCaseID,
        ordinal: Int,
        messagesHash: String,
        generationConfiguration: GenerationConfiguration
    ) {
        self.caseID = caseID
        self.ordinal = ordinal
        self.messagesHash = messagesHash
        self.generationConfiguration = generationConfiguration
    }
}

/// Immutable, reproducible description of one evaluation run.
public struct EvaluationRunManifest: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let runID: EvaluationRunID
    public let suiteID: EvaluationSuiteID
    public let suiteHash: String
    public let candidates: [EvaluationCandidate]
    public let executionOrder: [ModelArtifactID]
    public let hardwareProfileID: HardwareProfileID?
    public let runtimeVersion: String?
    public let kernelVersion: String?
    public let cases: [EvaluationCaseManifest]
    public let createdAt: Date
    public let manifestHash: String

    public init(
        schemaVersion: Int = 1,
        runID: EvaluationRunID,
        suiteID: EvaluationSuiteID,
        suiteHash: String,
        candidates: [EvaluationCandidate],
        executionOrder: [ModelArtifactID],
        hardwareProfileID: HardwareProfileID? = nil,
        runtimeVersion: String? = nil,
        kernelVersion: String? = nil,
        cases: [EvaluationCaseManifest],
        createdAt: Date,
        manifestHash: String
    ) {
        self.schemaVersion = schemaVersion
        self.runID = runID
        self.suiteID = suiteID
        self.suiteHash = suiteHash
        self.candidates = candidates
        self.executionOrder = executionOrder
        self.hardwareProfileID = hardwareProfileID
        self.runtimeVersion = runtimeVersion
        self.kernelVersion = kernelVersion
        self.cases = cases
        self.createdAt = createdAt
        self.manifestHash = manifestHash
    }
}

public struct EvaluationScore: Codable, Hashable, Sendable {
    public let kind: EvaluationScoreKind
    public let value: Double
    public let details: [String: String]

    public init(
        kind: EvaluationScoreKind,
        value: Double,
        details: [String: String] = [:]
    ) {
        self.kind = kind
        self.value = value
        self.details = details
    }
}

public struct EvaluationScoringRequest: Codable, Hashable, Sendable {
    public let evaluationCase: EvaluationCase
    public let generationResult: GenerationResult

    public init(evaluationCase: EvaluationCase, generationResult: GenerationResult) {
        self.evaluationCase = evaluationCase
        self.generationResult = generationResult
    }
}

public protocol EvaluationScorer: Sendable {
    var identifier: String { get }
    func score(_ request: EvaluationScoringRequest) async throws -> EvaluationScore
}

public struct EvaluationCaseResult: Codable, Hashable, Sendable {
    public let caseID: EvaluationCaseID
    public let artifactID: ModelArtifactID
    public let generationResult: GenerationResult?
    public let score: EvaluationScore?
    public let errorDescription: String?

    public init(
        caseID: EvaluationCaseID,
        artifactID: ModelArtifactID,
        generationResult: GenerationResult? = nil,
        score: EvaluationScore? = nil,
        errorDescription: String? = nil
    ) {
        self.caseID = caseID
        self.artifactID = artifactID
        self.generationResult = generationResult
        self.score = score
        self.errorDescription = errorDescription
    }
}

public enum EvaluationRunStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case running
    case completed
    case cancelled
    case failed
}

public struct EvaluationRunResult: Codable, Hashable, Sendable {
    public let runID: EvaluationRunID
    public let suiteID: EvaluationSuiteID
    public let status: EvaluationRunStatus
    public let caseResults: [EvaluationCaseResult]
    public let startedAt: Date
    public let endedAt: Date?

    public init(
        runID: EvaluationRunID,
        suiteID: EvaluationSuiteID,
        status: EvaluationRunStatus,
        caseResults: [EvaluationCaseResult],
        startedAt: Date,
        endedAt: Date? = nil
    ) {
        self.runID = runID
        self.suiteID = suiteID
        self.status = status
        self.caseResults = caseResults
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public enum BlindResponseChoice: String, Codable, CaseIterable, Hashable, Sendable {
    case responseA = "response_a"
    case responseB = "response_b"
    case tie
}

/// Immutable mapping between anonymous response labels and real artifacts for
/// one case. Presentation code must not expose either artifact ID before the
/// associated judgment has been submitted.
public struct BlindAssignment: Codable, Hashable, Sendable {
    public let responseAArtifactID: ModelArtifactID
    public let responseBArtifactID: ModelArtifactID
    public let assignmentSeed: UInt64
    public let ordinal: Int

    public init(
        responseAArtifactID: ModelArtifactID,
        responseBArtifactID: ModelArtifactID,
        assignmentSeed: UInt64,
        ordinal: Int
    ) {
        self.responseAArtifactID = responseAArtifactID
        self.responseBArtifactID = responseBArtifactID
        self.assignmentSeed = assignmentSeed
        self.ordinal = ordinal
    }

    public func artifactID(for choice: BlindResponseChoice) -> ModelArtifactID? {
        switch choice {
        case .responseA: responseAArtifactID
        case .responseB: responseBArtifactID
        case .tie: nil
        }
    }
}

public struct HumanJudgment: Codable, Hashable, Sendable {
    public let id: HumanJudgmentID
    public let runID: EvaluationRunID
    public let caseID: EvaluationCaseID
    public let assignment: BlindAssignment
    public var choice: BlindResponseChoice?
    public var notes: String?
    public var revealedAt: Date?
    public let createdAt: Date

    public init(
        id: HumanJudgmentID = .init(),
        runID: EvaluationRunID,
        caseID: EvaluationCaseID,
        assignment: BlindAssignment,
        choice: BlindResponseChoice? = nil,
        notes: String? = nil,
        revealedAt: Date? = nil,
        createdAt: Date = .init()
    ) {
        self.id = id
        self.runID = runID
        self.caseID = caseID
        self.assignment = assignment
        self.choice = choice
        self.notes = notes
        self.revealedAt = revealedAt
        self.createdAt = createdAt
    }
}
