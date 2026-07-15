import CryptoKit
import Foundation
import MLXStudioDomain
import MLXStudioPersistence

public enum PromptSuiteRunnerError: Error, Equatable, LocalizedError, Sendable {
    case emptySuite
    case requiresCandidate
    case duplicateCandidate(ModelArtifactID)
    case duplicateLabel(String)
    case invalidExecutionOrder
    case duplicateScorerIdentifier(String)
    case unknownScorer(String)
    case missingCompletedResult(ModelArtifactID, EvaluationCaseID)

    public var errorDescription: String? {
        switch self {
        case .emptySuite:
            return "Prompt suites must contain at least one case."
        case .requiresCandidate:
            return "Prompt-suite runs require at least one candidate."
        case .duplicateCandidate(let id):
            return "Prompt-suite candidate \(id.rawValue) is duplicated."
        case .duplicateLabel(let label):
            return "Prompt-suite candidate label \(label) is duplicated."
        case .invalidExecutionOrder:
            return "Prompt-suite execution order must contain each candidate exactly once."
        case .duplicateScorerIdentifier(let identifier):
            return "Evaluation scorer \(identifier) is registered more than once."
        case .unknownScorer(let identifier):
            return "Evaluation scorer \(identifier) is not registered."
        case .missingCompletedResult(let artifactID, let caseID):
            return "Candidate \(artifactID.rawValue) produced no completed result for case \(caseID.rawValue)."
        }
    }
}

/// Compatibility adapter for JANG Expert Lab's current `unit_test` contract:
/// the expected value is a regular expression matched against generated text.
public struct UnitTestRegularExpressionScorer: EvaluationScorer {
    public static let scorerIdentifier = "jang.unit-test-expected-regex.v1"
    public let identifier = scorerIdentifier

    public init() {}

    public func score(_ request: EvaluationScoringRequest) async throws -> EvaluationScore {
        guard let expectation = request.evaluationCase.expectation else {
            throw EvaluationPrimitiveError.missingExpectation
        }
        guard expectation.kind == .unitTest else {
            throw EvaluationPrimitiveError.unsupportedExpectation(expectation.kind)
        }
        guard let pattern = expectation.value, !pattern.isEmpty else {
            throw EvaluationPrimitiveError.missingExpectedValue
        }
        let expression: NSRegularExpression
        do {
            expression = try NSRegularExpression(pattern: pattern)
        } catch {
            throw EvaluationPrimitiveError.invalidRegularExpression(pattern)
        }
        let output = request.generationResult.text
        let range = NSRange(output.startIndex..<output.endIndex, in: output)
        let passed = expression.firstMatch(in: output, range: range) != nil
        return EvaluationScore(
            kind: EvaluationScoreKind(rawValue: EvaluationExpectationKind.unitTest.rawValue),
            value: passed ? 1 : 0,
            details: [
                "scorer": identifier,
                "compatibility_source": "JANG ExpertPromptEvaluator",
            ]
        )
    }
}

/// Preserves JANG Expert Lab's whitespace-normalized exact-match semantics for
/// imported suites while leaving MLX Studio's native exact scorer unchanged.
public struct JANGNormalizedExactScorer: EvaluationScorer {
    public static let scorerIdentifier = "jang.normalized-exact.v1"
    public let identifier = scorerIdentifier

    public init() {}

    public func score(_ request: EvaluationScoringRequest) async throws -> EvaluationScore {
        guard let expectation = request.evaluationCase.expectation else {
            throw EvaluationPrimitiveError.missingExpectation
        }
        guard let expected = expectation.value else {
            throw EvaluationPrimitiveError.missingExpectedValue
        }
        func normalized(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return EvaluationScore(
            kind: .init(rawValue: EvaluationExpectationKind.exact.rawValue),
            value: normalized(request.generationResult.text) == normalized(expected) ? 1 : 0,
            details: [
                "scorer": identifier,
                "compatibility_source": "JANG ExpertPromptEvaluator",
            ]
        )
    }
}

/// Routes built-in expectation kinds and versioned external scorer adapters.
/// Custom scorers must be named in the suite, preventing ambient executable
/// behavior from being smuggled through imported JSONL.
public struct EvaluationScorerRegistry: Sendable {
    private let builtIn = BuiltInEvaluationScorer()
    private let adapters: [String: any EvaluationScorer]

    public init(
        adapters: [any EvaluationScorer] = [
            UnitTestRegularExpressionScorer(),
            JANGNormalizedExactScorer(),
        ]
    ) throws {
        var byIdentifier: [String: any EvaluationScorer] = [:]
        for adapter in adapters {
            guard byIdentifier[adapter.identifier] == nil else {
                throw PromptSuiteRunnerError.duplicateScorerIdentifier(adapter.identifier)
            }
            byIdentifier[adapter.identifier] = adapter
        }
        self.adapters = byIdentifier
    }

    public func score(_ request: EvaluationScoringRequest) async throws -> EvaluationScore {
        guard let expectation = request.evaluationCase.expectation else {
            throw EvaluationPrimitiveError.missingExpectation
        }
        if let identifier = expectation.scorerIdentifier {
            guard let adapter = adapters[identifier] else {
                throw PromptSuiteRunnerError.unknownScorer(identifier)
            }
            return try await adapter.score(request)
        }
        switch expectation.kind {
        case .exact, .contains, .regularExpression:
            return try await builtIn.score(request)
        case .unitTest:
            guard let adapter = adapters[UnitTestRegularExpressionScorer.scorerIdentifier] else {
                throw PromptSuiteRunnerError.unknownScorer(
                    UnitTestRegularExpressionScorer.scorerIdentifier
                )
            }
            return try await adapter.score(request)
        case .custom:
            throw PromptSuiteRunnerError.unknownScorer("custom expectation without scorerIdentifier")
        }
    }
}

public struct PromptSuiteOutcome: Codable, Hashable, Sendable {
    public let manifest: EvaluationRunManifest
    public let result: EvaluationRunResult
    public let scorecards: [EvaluationScorecard]
    public let resumedCaseResultCount: Int

    public init(
        manifest: EvaluationRunManifest,
        result: EvaluationRunResult,
        scorecards: [EvaluationScorecard],
        resumedCaseResultCount: Int
    ) {
        self.manifest = manifest
        self.result = result
        self.scorecards = scorecards
        self.resumedCaseResultCount = resumedCaseResultCount
    }
}

public enum PromptSuiteFactory {
    public static func customPrompts(
        name: String = "Custom prompts",
        prompts: [String],
        generationConfiguration: GenerationConfiguration
    ) throws -> EvaluationSuite {
        let normalized = prompts.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
        guard !normalized.isEmpty else { throw PromptSuiteRunnerError.emptySuite }
        let payload = PromptSuiteHashPayload(
            schemaVersion: 1,
            prompts: normalized,
            generationConfiguration: generationConfiguration
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let hash = sha256(try encoder.encode(payload))
        let cases = normalized.enumerated().map { ordinal, prompt in
            let caseHash = sha256(Data("\(hash):\(ordinal):\(prompt)".utf8))
            return EvaluationCase(
                id: deterministicID(EvaluationCaseID.self, hex: String(caseHash.prefix(32))),
                ordinal: ordinal,
                name: "Custom prompt \(ordinal + 1)",
                messages: [GenerationMessage(role: .user, content: prompt)],
                domain: "custom",
                tags: ["custom-prompt"],
                generationConfiguration: generationConfiguration
            )
        }
        return EvaluationSuite(
            id: deterministicID(EvaluationSuiteID.self, hex: String(hash.prefix(32))),
            name: name,
            revision: hash,
            tags: ["prompt-suite", "custom"],
            cases: cases,
            suiteHash: hash
        )
    }

    public static func resolvingPersistedSuite(
        _ proposed: EvaluationSuite,
        repository: EvaluationRepository
    ) throws -> EvaluationSuite {
        try repository.suites().first { $0.suiteHash == proposed.suiteHash } ?? proposed
    }
}

public enum PromptSuiteImportError: Error, Equatable, LocalizedError, Sendable {
    case emptyInput
    case unsupportedExpertExpectation(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "The prompt-suite import is empty."
        case .unsupportedExpertExpectation(let kind):
            return "JANG Expert prompt expectation \(kind) is not supported."
        }
    }
}

/// Imports either MLX Studio's complete versioned JSONL records or the authored
/// JANG Expert Lab prompt JSONL shape. Legacy imports become canonical suites
/// on export; no JANG-only persistence authority is introduced.
public enum PromptSuiteImport {
    public static func decode(_ data: Data, name: String = "Imported prompt suite") throws
        -> EvaluationSuite
    {
        guard let firstLine = data.split(separator: 0x0A).first(where: {
            !String(decoding: $0, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            throw PromptSuiteImportError.emptyInput
        }
        if let object = try JSONSerialization.jsonObject(with: Data(firstLine)) as? [String: Any],
           object["schemaVersion"] != nil || object["suiteID"] != nil
        {
            return try EvaluationJSONL.decode(data)
        }
        let decoder = JSONDecoder()
        let records = try data.split(separator: 0x0A)
            .filter {
                !String(decoding: $0, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .map { try decoder.decode(JANGExpertPromptRecord.self, from: Data($0)) }
        guard !records.isEmpty else { throw PromptSuiteImportError.emptyInput }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let hash = sha256(try encoder.encode(records))
        let cases = try records.enumerated().map { ordinal, record in
            let expectation: EvaluationExpectation?
            switch record.expectedKind {
            case "freeform", "judge":
                expectation = nil
            case "exact":
                expectation = .init(
                    kind: .exact,
                    value: record.expected,
                    scorerIdentifier: JANGNormalizedExactScorer.scorerIdentifier
                )
            case "regex":
                expectation = .init(kind: .regularExpression, value: record.expected)
            case "unit_test":
                expectation = .init(
                    kind: .unitTest,
                    value: record.expected,
                    scorerIdentifier: UnitTestRegularExpressionScorer.scorerIdentifier
                )
            default:
                throw PromptSuiteImportError.unsupportedExpertExpectation(record.expectedKind)
            }
            let caseHash = sha256(Data("\(hash):\(ordinal):\(record.id)".utf8))
            return EvaluationCase(
                id: deterministicID(EvaluationCaseID.self, hex: String(caseHash.prefix(32))),
                ordinal: ordinal,
                name: record.id,
                messages: [GenerationMessage(role: .user, content: record.prompt)],
                domain: record.domain,
                tags: Set(record.tags),
                expectation: expectation,
                generationConfiguration: GenerationConfiguration(
                    maximumTokenCount: max(1, record.maxNewTokens ?? 64),
                    temperature: record.temperature ?? 0,
                    topP: 1
                ),
                weight: record.weight
            )
        }
        return EvaluationSuite(
            id: deterministicID(EvaluationSuiteID.self, hex: String(hash.prefix(32))),
            name: name,
            revision: hash,
            tags: ["prompt-suite", "jang-expert-import"],
            cases: cases,
            suiteHash: hash
        )
    }
}

/// Sequential, resumable execution of one or more candidates over a complete
/// suite. Every result is committed before the next generation starts. A
/// resumed run reads those durable keys and never regenerates completed work.
public actor PromptSuiteRunner {
    public static let templateIdentifier = "mlx-studio.prompt-suite.v1"

    private let provider: any ModelInferenceProvider
    private let repository: EvaluationRepository
    private let scorers: EvaluationScorerRegistry
    private let now: @Sendable () -> Date

    public init(
        provider: any ModelInferenceProvider,
        repository: EvaluationRepository,
        scorers: EvaluationScorerRegistry? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) throws {
        self.provider = provider
        self.repository = repository
        self.scorers = try scorers ?? EvaluationScorerRegistry()
        self.now = now
    }

    public func run(_ request: EvaluationRunRequest) async throws -> PromptSuiteOutcome {
        try Self.validate(request)
        let generatedManifest = try EvaluationManifestBuilder.build(for: request)
        let stored = try repository.run(id: request.id)
        let manifest: EvaluationRunManifest
        if let stored {
            // The repository's canonical millisecond JSON encoding is the
            // immutability authority. Re-saving the same payload validates it
            // without comparing sub-millisecond in-memory Date values.
            try repository.saveRun(
                request: request,
                manifest: generatedManifest,
                status: stored.status
            )
            manifest = stored.manifest
        } else {
            try repository.saveRun(
                request: request,
                manifest: generatedManifest,
                status: .pending
            )
            manifest = generatedManifest
        }

        var results = try repository.caseResults(runID: request.id)
        let resumedCount = results.count
        let completedKeys = Set(results.map(ResultKey.init))
        let expectedResultCount = request.candidates.count * request.suite.cases.count
        if stored?.status == .completed, completedKeys.count == expectedResultCount {
            return Self.outcome(
                request: request,
                manifest: manifest,
                results: results,
                status: .completed,
                endedAt: stored?.endedAt,
                resumedCount: resumedCount
            )
        }

        try repository.setRunStatus(.running, runID: request.id)
        var lastResultAt = now().addingTimeInterval(-0.001)
        var encounteredFailure = results.contains { $0.errorDescription != nil }
        do {
            for artifactID in request.executionOrder {
                for evaluationCase in request.suite.cases.sorted(by: Self.caseOrder) {
                    let key = ResultKey(artifactID: artifactID, caseID: evaluationCase.id)
                    guard !completedKeys.contains(key) else { continue }
                    try Task.checkCancellation()
                    let caseResult: EvaluationCaseResult
                    do {
                        let generation = try await generate(
                            artifactID: artifactID,
                            evaluationCase: evaluationCase,
                            runID: request.id
                        )
                        let score: EvaluationScore?
                        if evaluationCase.expectation != nil {
                            score = try await scorers.score(.init(
                                evaluationCase: evaluationCase,
                                generationResult: generation
                            ))
                        } else {
                            score = nil
                        }
                        caseResult = EvaluationCaseResult(
                            caseID: evaluationCase.id,
                            artifactID: artifactID,
                            generationResult: generation,
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
            return Self.outcome(
                request: request,
                manifest: manifest,
                results: results,
                status: status,
                endedAt: endedAt,
                resumedCount: resumedCount
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
        guard !request.suite.cases.isEmpty else { throw PromptSuiteRunnerError.emptySuite }
        if let duplicate = duplicate(in: request.suite.cases.map(\.id)) {
            throw EvaluationPrimitiveError.duplicateCaseIdentifier(duplicate)
        }
        if let duplicate = duplicate(in: request.suite.cases.map(\.ordinal)) {
            throw EvaluationPrimitiveError.duplicateOrdinal(duplicate)
        }
        guard !request.candidates.isEmpty else { throw PromptSuiteRunnerError.requiresCandidate }
        let candidateIDs = request.candidates.map(\.artifactID)
        if let duplicate = duplicate(in: candidateIDs) {
            throw PromptSuiteRunnerError.duplicateCandidate(duplicate)
        }
        let labels = request.candidates.map(\.blindLabel)
        if let duplicate = duplicate(in: labels) {
            throw PromptSuiteRunnerError.duplicateLabel(duplicate)
        }
        guard request.executionOrder.count == candidateIDs.count,
              Set(request.executionOrder) == Set(candidateIDs)
        else { throw PromptSuiteRunnerError.invalidExecutionOrder }
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
                "evaluation_execution": "sequential-resumable",
                "evaluation_template_id": Self.templateIdentifier,
                "enable_thinking": "false",
            ]
        )
        var completed: GenerationResult?
        for try await event in provider.events(for: request) {
            try Task.checkCancellation()
            if case .completed(let result) = event { completed = result }
        }
        try Task.checkCancellation()
        guard let completed else {
            throw PromptSuiteRunnerError.missingCompletedResult(artifactID, evaluationCase.id)
        }
        return completed
    }

    private static func outcome(
        request: EvaluationRunRequest,
        manifest: EvaluationRunManifest,
        results: [EvaluationCaseResult],
        status: EvaluationRunStatus,
        endedAt: Date?,
        resumedCount: Int
    ) -> PromptSuiteOutcome {
        PromptSuiteOutcome(
            manifest: manifest,
            result: EvaluationRunResult(
                runID: request.id,
                suiteID: request.suite.id,
                status: status,
                caseResults: results,
                startedAt: request.createdAt,
                endedAt: endedAt
            ),
            scorecards: EvaluationScorecardBuilder.build(
                runID: request.id,
                suite: request.suite,
                candidates: request.candidates,
                results: results
            ),
            resumedCaseResultCount: resumedCount
        )
    }

    private static func caseOrder(_ lhs: EvaluationCase, _ rhs: EvaluationCase) -> Bool {
        lhs.ordinal == rhs.ordinal
            ? lhs.id.rawValue < rhs.id.rawValue
            : lhs.ordinal < rhs.ordinal
    }
}

public enum EvaluationScorecardBuilder {
    public static func build(
        runID: EvaluationRunID,
        suite: EvaluationSuite,
        candidates: [EvaluationCandidate],
        results: [EvaluationCaseResult]
    ) -> [EvaluationScorecard] {
        let casesByID = Dictionary(uniqueKeysWithValues: suite.cases.map { ($0.id, $0) })
        return candidates.map { candidate in
            let candidateResults = results.filter { $0.artifactID == candidate.artifactID }
            let grouped = Dictionary(grouping: candidateResults) { result in
                casesByID[result.caseID]?.domain?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty ?? "Uncategorized"
            }
            let domains = grouped.keys.sorted().map { domain in
                aggregate(domain: domain, results: grouped[domain] ?? [], casesByID: casesByID)
            }
            return EvaluationScorecard(
                runID: runID,
                artifactID: candidate.artifactID,
                overall: aggregate(
                    domain: "Overall",
                    results: candidateResults,
                    casesByID: casesByID
                ),
                domains: domains,
                generatedTokenCount: candidateResults.reduce(0) {
                    $0 + ($1.generationResult?.metrics.generatedTokenCount ?? 0)
                },
                totalDurationSeconds: candidateResults.reduce(0) {
                    $0 + ($1.generationResult?.metrics.totalDurationSeconds
                        ?? $1.generationResult?.metrics.generationDurationSeconds ?? 0)
                }
            )
        }
    }

    private static func aggregate(
        domain: String,
        results: [EvaluationCaseResult],
        casesByID: [EvaluationCaseID: EvaluationCase]
    ) -> EvaluationDomainScore {
        let scored = results.compactMap { result -> (Double, Double)? in
            guard let score = result.score else { return nil }
            return (score.value, max(0, casesByID[result.caseID]?.weight ?? 1))
        }
        let totalWeight = scored.reduce(0) { $0 + $1.1 }
        let weightedScore = totalWeight > 0
            ? scored.reduce(0) { $0 + ($1.0 * $1.1) } / totalWeight : nil
        return EvaluationDomainScore(
            domain: domain,
            caseCount: results.count,
            scoredCaseCount: scored.count,
            passedCaseCount: scored.filter { $0.0 >= 0.5 }.count,
            failedCaseCount: scored.filter { $0.0 < 0.5 }.count,
            unscoredCaseCount: results.filter {
                $0.score == nil && $0.errorDescription == nil
            }.count,
            errorCaseCount: results.filter { $0.errorDescription != nil }.count,
            weightedScore: weightedScore
        )
    }
}

private struct ResultKey: Hashable {
    let artifactID: ModelArtifactID
    let caseID: EvaluationCaseID

    init(artifactID: ModelArtifactID, caseID: EvaluationCaseID) {
        self.artifactID = artifactID
        self.caseID = caseID
    }

    init(_ result: EvaluationCaseResult) {
        self.init(artifactID: result.artifactID, caseID: result.caseID)
    }
}

private struct PromptSuiteHashPayload: Codable {
    let schemaVersion: Int
    let prompts: [String]
    let generationConfiguration: GenerationConfiguration
}

private struct JANGExpertPromptRecord: Codable {
    let id: String
    let domain: String
    let prompt: String
    let expectedKind: String
    let expected: String?
    let maxNewTokens: Int?
    let temperature: Double?
    let tags: [String]
    let weight: Double

    private enum CodingKeys: String, CodingKey {
        case id, domain, prompt, text, expected, temperature, tags, weight
        case expectedKind = "expected_kind"
        case maxNewTokens = "max_new_tokens"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        domain = try container.decodeIfPresent(String.self, forKey: .domain) ?? "general"
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
            ?? container.decode(String.self, forKey: .text)
        expectedKind = try container.decodeIfPresent(String.self, forKey: .expectedKind)
            ?? "freeform"
        expected = try container.decodeIfPresent(String.self, forKey: .expected)
        maxNewTokens = try container.decodeIfPresent(Int.self, forKey: .maxNewTokens)
        temperature = try container.decodeIfPresent(Double.self, forKey: .temperature)
        tags = try container.decodeIfPresent([String].self, forKey: .tags) ?? []
        weight = try container.decodeIfPresent(Double.self, forKey: .weight) ?? 1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(domain, forKey: .domain)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(expectedKind, forKey: .expectedKind)
        try container.encodeIfPresent(expected, forKey: .expected)
        try container.encodeIfPresent(maxNewTokens, forKey: .maxNewTokens)
        try container.encodeIfPresent(temperature, forKey: .temperature)
        try container.encode(tags, forKey: .tags)
        try container.encode(weight, forKey: .weight)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}

private func duplicate<Value: Hashable>(in values: [Value]) -> Value? {
    var seen: Set<Value> = []
    return values.first { !seen.insert($0).inserted }
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func deterministicID<Tag: MLXStudioIDTag>(
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
