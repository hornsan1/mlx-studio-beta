import CryptoKit
import Foundation
import MLXStudioDomain
import MLXStudioPersistence

public enum QuickCompareError: Error, Equatable, LocalizedError, Sendable {
    case requiresTwoCandidates(Int)
    case duplicateCandidate(ModelArtifactID)
    case duplicateLabel(String)
    case invalidExecutionOrder
    case missingCompletedResult(ModelArtifactID, EvaluationCaseID)

    public var errorDescription: String? {
        switch self {
        case .requiresTwoCandidates(let count):
            return "Quick Compare requires exactly two candidates; found \(count)."
        case .duplicateCandidate(let id):
            return "Quick Compare candidate \(id.rawValue) is duplicated."
        case .duplicateLabel(let label):
            return "Quick Compare candidate label \(label) is duplicated."
        case .invalidExecutionOrder:
            return "Quick Compare execution order must contain each candidate exactly once."
        case .missingCompletedResult(let artifactID, let caseID):
            return "Candidate \(artifactID.rawValue) produced no completed result for case \(caseID.rawValue)."
        }
    }
}

public struct QuickCompareOutcome: Codable, Hashable, Sendable {
    public let manifest: EvaluationRunManifest
    public let result: EvaluationRunResult

    public init(manifest: EvaluationRunManifest, result: EvaluationRunResult) {
        self.manifest = manifest
        self.result = result
    }
}

public enum QuickCompareSuiteFactory {
    public static func singlePrompt(
        name: String = "Quick Compare",
        systemPrompt: String? = nil,
        prompt: String,
        generationConfiguration: GenerationConfiguration,
        suiteID: EvaluationSuiteID? = nil,
        caseID: EvaluationCaseID? = nil
    ) throws -> EvaluationSuite {
        let messages = [
            systemPrompt.flatMap { value in
                value.isEmpty ? nil : GenerationMessage(role: .system, content: value)
            },
            GenerationMessage(role: .user, content: prompt),
        ].compactMap { $0 }
        let payload = QuickCompareSuiteHashPayload(
            schemaVersion: 1,
            messages: messages,
            generationConfiguration: generationConfiguration,
            templateIdentifier: QuickCompareRunner.templateIdentifier
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let hash = SHA256.hash(data: try encoder.encode(payload))
            .map { String(format: "%02x", $0) }.joined()
        let resolvedSuiteID = suiteID ?? deterministicID(
            EvaluationSuiteID.self,
            hex: String(hash.prefix(32))
        )
        let resolvedCaseID = caseID ?? deterministicID(
            EvaluationCaseID.self,
            hex: String(hash.suffix(32))
        )
        return EvaluationSuite(
            id: resolvedSuiteID,
            name: name,
            revision: hash,
            tags: ["quick-compare"],
            cases: [EvaluationCase(
                id: resolvedCaseID,
                ordinal: 0,
                name: "Quick Compare prompt",
                messages: messages,
                generationConfiguration: generationConfiguration
            )],
            suiteHash: hash
        )
    }

    /// Reuses an already-persisted content-equivalent suite. This keeps new
    /// content-addressed IDs compatible with suites written by early builds
    /// that assigned random IDs to the same suite hash.
    public static func resolvingPersistedSuite(
        _ proposed: EvaluationSuite,
        repository: EvaluationRepository
    ) throws -> EvaluationSuite {
        try repository.suites().first { $0.suiteHash == proposed.suiteHash } ?? proposed
    }

    private static func deterministicID<Tag: MLXStudioIDTag>(
        _ type: MLXStudioID<Tag>.Type,
        hex: String
    ) -> MLXStudioID<Tag> {
        let parts = [8, 4, 4, 4, 12]
        var offset = hex.startIndex
        let uuid = parts.map { length -> String in
            let end = hex.index(offset, offsetBy: length)
            defer { offset = end }
            return String(hex[offset..<end])
        }.joined(separator: "-")
        return MLXStudioID<Tag>(rawValue: uuid)!
    }
}

private struct QuickCompareSuiteHashPayload: Codable {
    let schemaVersion: Int
    let messages: [GenerationMessage]
    let generationConfiguration: GenerationConfiguration
    let templateIdentifier: String
}

/// Runs both candidates through one immutable suite and manifest. Execution is
/// deliberately sequential so comparisons remain available when two models do
/// not fit in memory together and each generation uses the same prompt,
/// configuration, and logical template contract.
public actor QuickCompareRunner {
    public static let templateIdentifier = "mlx-studio.quick-compare.v1"

    private let provider: any ModelInferenceProvider
    private let repository: EvaluationRepository
    private let scorer: any EvaluationScorer
    private let now: @Sendable () -> Date

    public init(
        provider: any ModelInferenceProvider,
        repository: EvaluationRepository,
        scorer: any EvaluationScorer = BuiltInEvaluationScorer(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.provider = provider
        self.repository = repository
        self.scorer = scorer
        self.now = now
    }

    public func run(_ request: EvaluationRunRequest) async throws -> QuickCompareOutcome {
        try Self.validate(request)
        let manifest = try EvaluationManifestBuilder.build(for: request)
        try repository.saveRun(request: request, manifest: manifest, status: .pending)
        try repository.setRunStatus(.running, runID: request.id)

        let startedAt = now()
        var lastResultAt = startedAt.addingTimeInterval(-0.001)
        var results: [EvaluationCaseResult] = []
        var encounteredFailure = false
        do {
            for artifactID in request.executionOrder {
                for evaluationCase in request.suite.cases.sorted(by: Self.caseOrder) {
                    try Task.checkCancellation()
                    let caseResult: EvaluationCaseResult
                    do {
                        let generationResult = try await generate(
                            artifactID: artifactID,
                            evaluationCase: evaluationCase,
                            runID: request.id
                        )
                        let score: EvaluationScore?
                        if evaluationCase.expectation != nil {
                            score = try await scorer.score(.init(
                                evaluationCase: evaluationCase,
                                generationResult: generationResult
                            ))
                        } else {
                            score = nil
                        }
                        caseResult = EvaluationCaseResult(
                            caseID: evaluationCase.id,
                            artifactID: artifactID,
                            generationResult: generationResult,
                            score: score
                        )
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        encounteredFailure = true
                        caseResult = EvaluationCaseResult(
                            caseID: evaluationCase.id,
                            artifactID: artifactID,
                            errorDescription: error.localizedDescription
                        )
                    }
                    let observedAt = now()
                    let createdAt = observedAt > lastResultAt
                        ? observedAt : lastResultAt.addingTimeInterval(0.000_001)
                    try repository.saveCaseResult(caseResult, runID: request.id, createdAt: createdAt)
                    lastResultAt = createdAt
                    results.append(caseResult)
                }
            }

            let endedAt = max(now(), lastResultAt)
            let status: EvaluationRunStatus = encounteredFailure ? .failed : .completed
            try repository.setRunStatus(status, runID: request.id, endedAt: endedAt)
            return QuickCompareOutcome(
                manifest: manifest,
                result: EvaluationRunResult(
                    runID: request.id,
                    suiteID: request.suite.id,
                    status: status,
                    caseResults: results,
                    startedAt: startedAt,
                    endedAt: endedAt
                )
            )
        } catch is CancellationError {
            try repository.setRunStatus(.cancelled, runID: request.id, endedAt: now())
            throw CancellationError()
        } catch {
            try? repository.setRunStatus(.failed, runID: request.id, endedAt: now())
            throw error
        }
    }

    public static func validate(_ request: EvaluationRunRequest) throws {
        guard request.candidates.count == 2 else {
            throw QuickCompareError.requiresTwoCandidates(request.candidates.count)
        }
        let candidateIDs = request.candidates.map(\.artifactID)
        if let duplicate = candidateIDs.first(where: { id in
            candidateIDs.filter { $0 == id }.count > 1
        }) {
            throw QuickCompareError.duplicateCandidate(duplicate)
        }
        let labels = request.candidates.map(\.blindLabel)
        if let duplicate = labels.first(where: { label in
            labels.filter { $0 == label }.count > 1
        }) {
            throw QuickCompareError.duplicateLabel(duplicate)
        }
        guard request.executionOrder.count == candidateIDs.count,
              Set(request.executionOrder) == Set(candidateIDs)
        else { throw QuickCompareError.invalidExecutionOrder }
    }

    private func generate(
        artifactID: ModelArtifactID,
        evaluationCase: EvaluationCase,
        runID: EvaluationRunID
    ) async throws -> GenerationResult {
        let request = GenerationRequest(
            artifactID: artifactID,
            messages: evaluationCase.messages,
            configuration: evaluationCase.generationConfiguration,
            metadata: [
                "evaluation_case_id": evaluationCase.id.rawValue,
                "evaluation_run_id": runID.rawValue,
                "evaluation_execution": "sequential-fallback",
                "evaluation_template_id": Self.templateIdentifier,
                "enable_thinking": "false",
            ]
        )
        var completed: GenerationResult?
        for try await event in provider.events(for: request) {
            try Task.checkCancellation()
            if case .completed(let result) = event { completed = result }
        }
        guard let completed else {
            throw QuickCompareError.missingCompletedResult(artifactID, evaluationCase.id)
        }
        return completed
    }

    private static func caseOrder(_ lhs: EvaluationCase, _ rhs: EvaluationCase) -> Bool {
        lhs.ordinal == rhs.ordinal
            ? lhs.id.rawValue < rhs.id.rawValue
            : lhs.ordinal < rhs.ordinal
    }
}
