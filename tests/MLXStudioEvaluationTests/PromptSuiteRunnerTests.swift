import Foundation
import MLXStudioDomain
import MLXStudioPersistence
import XCTest
@testable import MLXStudioEvaluation

final class PromptSuiteRunnerTests: XCTestCase {
    func testRegistryRoutesBuiltInsUnitCompatibilityAndNamedCustomAdapter() async throws {
        let artifactID = ModelArtifactID()
        let generation = GenerationResult(
            generationID: GenerationID(),
            artifactID: artifactID,
            text: "answer: 42",
            finishReason: .completed
        )
        let custom = FixedScorer(identifier: "tests.custom", value: 0.75)
        let registry = try EvaluationScorerRegistry(adapters: [
            UnitTestRegularExpressionScorer(), JANGNormalizedExactScorer(), custom,
        ])

        let exact = try await registry.score(.init(
            evaluationCase: makeCase(
                ordinal: 0,
                domain: "math",
                expectation: .init(kind: .exact, value: "answer: 42")
            ),
            generationResult: generation
        ))
        let unit = try await registry.score(.init(
            evaluationCase: makeCase(
                ordinal: 1,
                domain: "math",
                expectation: .init(kind: .unitTest, value: #"answer:\s+\d+"#)
            ),
            generationResult: generation
        ))
        let customScore = try await registry.score(.init(
            evaluationCase: makeCase(
                ordinal: 2,
                domain: "quality",
                expectation: .init(
                    kind: .custom,
                    scorerIdentifier: custom.identifier
                )
            ),
            generationResult: generation
        ))
        let normalizedExact = try await registry.score(.init(
            evaluationCase: makeCase(
                ordinal: 3,
                domain: "compatibility",
                expectation: .init(
                    kind: .exact,
                    value: "answer:   42",
                    scorerIdentifier: JANGNormalizedExactScorer.scorerIdentifier
                )
            ),
            generationResult: generation
        ))

        XCTAssertEqual(exact.value, 1)
        XCTAssertEqual(unit.value, 1)
        XCTAssertEqual(
            unit.details["scorer"],
            UnitTestRegularExpressionScorer.scorerIdentifier
        )
        XCTAssertEqual(customScore.value, 0.75)
        XCTAssertEqual(customScore.details["scorer"], custom.identifier)
        XCTAssertEqual(normalizedExact.value, 1)
    }

    func testCustomPromptsAreContentAddressedAndRoundTripThroughJSONL() throws {
        let configuration = GenerationConfiguration(
            maximumTokenCount: 32,
            temperature: 0,
            topP: 1,
            seed: 7
        )
        let first = try PromptSuiteFactory.customPrompts(
            prompts: [" First prompt ", "Second prompt"],
            generationConfiguration: configuration
        )
        let repeated = try PromptSuiteFactory.customPrompts(
            prompts: ["First prompt", "Second prompt"],
            generationConfiguration: configuration
        )
        let changed = try PromptSuiteFactory.customPrompts(
            prompts: ["First prompt", "Changed prompt"],
            generationConfiguration: configuration
        )

        XCTAssertEqual(first, repeated)
        XCTAssertNotEqual(first.id, changed.id)
        XCTAssertEqual(first.cases.count, 2)
        XCTAssertTrue(first.cases.allSatisfy { $0.expectation == nil })
        XCTAssertEqual(try EvaluationJSONL.decode(EvaluationJSONL.encode(first)), first)
    }

    func testJANGExpertJSONLImportsAndExportsAsCanonicalVersionedSuite() throws {
        let source = """
        {"id":"math-1","domain":"math","prompt":"Return 4","expected_kind":"exact","expected":"4","max_new_tokens":8,"temperature":0,"tags":["smoke"],"weight":2}
        {"id":"code-1","domain":"code","text":"Print hello","expected_kind":"unit_test","expected":"hello\\\\s+world"}
        {"id":"write-1","domain":"writing","prompt":"Write freely","expected_kind":"freeform"}
        """

        let suite = try PromptSuiteImport.decode(Data(source.utf8), name: "JANG migrated")

        XCTAssertEqual(suite.name, "JANG migrated")
        XCTAssertEqual(suite.tags, ["prompt-suite", "jang-expert-import"])
        XCTAssertEqual(suite.cases.map(\.domain), ["math", "code", "writing"])
        XCTAssertEqual(suite.cases[0].expectation?.kind, .exact)
        XCTAssertEqual(
            suite.cases[0].expectation?.scorerIdentifier,
            JANGNormalizedExactScorer.scorerIdentifier
        )
        XCTAssertEqual(suite.cases[0].weight, 2)
        XCTAssertEqual(suite.cases[1].expectation?.kind, .unitTest)
        XCTAssertEqual(
            suite.cases[1].expectation?.scorerIdentifier,
            UnitTestRegularExpressionScorer.scorerIdentifier
        )
        XCTAssertNil(suite.cases[2].expectation)

        let canonical = try EvaluationJSONL.encode(suite)
        XCTAssertEqual(try PromptSuiteImport.decode(canonical), suite)
    }

    func testRunnerResumesPersistedRunAfterRepositoryRestartWithoutRegeneration() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let suite = EvaluationSuite(
            name: "Restart and resume",
            revision: "1",
            tags: ["prompt-suite"],
            cases: [
                makeCase(ordinal: 0, domain: "math"),
                makeCase(ordinal: 1, domain: "code"),
                makeCase(ordinal: 2, domain: "code"),
            ],
            suiteHash: "restart-and-resume"
        )
        let request = EvaluationRunRequest(
            suite: suite,
            candidates: [.init(artifactID: context.artifact.id, blindLabel: "Candidate")],
            runtimeVersion: "runtime-sha",
            kernelVersion: "kernel-sha",
            executionOrder: [context.artifact.id],
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        let manifest = try EvaluationManifestBuilder.build(for: request)
        let firstGeneration = GenerationResult(
            generationID: GenerationID(),
            artifactID: context.artifact.id,
            text: "already durable",
            finishReason: .completed
        )
        try context.evaluations.saveRun(request: request, manifest: manifest, status: .running)
        try context.evaluations.saveCaseResult(
            EvaluationCaseResult(
                caseID: suite.cases[0].id,
                artifactID: context.artifact.id,
                generationResult: firstGeneration
            ),
            runID: request.id
        )
        try context.evaluations.setRunStatus(
            .cancelled,
            runID: request.id,
            endedAt: Date(timeIntervalSince1970: 1_001)
        )

        let reopened = try EvaluationRepository(databaseURL: context.databaseURL)
        let provider = RecordingSuiteProvider()
        let runner = try PromptSuiteRunner(provider: provider, repository: reopened)
        let outcome = try await runner.run(request)

        XCTAssertEqual(outcome.result.status, .completed)
        XCTAssertEqual(outcome.resumedCaseResultCount, 1)
        XCTAssertEqual(outcome.result.caseResults.count, 3)
        XCTAssertEqual(provider.requests.map(\.metadata["evaluation_case_id"]), [
            suite.cases[1].id.rawValue,
            suite.cases[2].id.rawValue,
        ])
        XCTAssertEqual(try reopened.run(id: request.id)?.status, .completed)
        XCTAssertEqual(try reopened.caseResults(runID: request.id).count, 3)
        XCTAssertEqual(try reopened.runs().first?.request.id, request.id)

        let replay = try await runner.run(request)
        XCTAssertEqual(replay.resumedCaseResultCount, 3)
        XCTAssertEqual(provider.requests.count, 2)
    }

    func testCancellationPersistsStateAndSameRequestCanResume() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let suite = EvaluationSuite(
            name: "Cancellation",
            revision: "1",
            tags: ["prompt-suite"],
            cases: [makeCase(ordinal: 0, domain: "general")],
            suiteHash: "cancellation"
        )
        let request = EvaluationRunRequest(
            suite: suite,
            candidates: [.init(artifactID: context.artifact.id, blindLabel: "Candidate")],
            executionOrder: [context.artifact.id]
        )
        let probe = SuiteStartProbe()
        let runner = try PromptSuiteRunner(
            provider: HangingSuiteProvider(probe: probe),
            repository: context.evaluations
        )
        let task = Task { try await runner.run(request) }
        for _ in 0..<100 {
            if await probe.started { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let didStart = await probe.started
        XCTAssertTrue(didStart)

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(try context.evaluations.run(id: request.id)?.status, .cancelled)
        XCTAssertTrue(try context.evaluations.caseResults(runID: request.id).isEmpty)

        let resumedProvider = RecordingSuiteProvider()
        let resumed = try await PromptSuiteRunner(
            provider: resumedProvider,
            repository: context.evaluations
        ).run(request)
        XCTAssertEqual(resumed.result.status, .completed)
        XCTAssertEqual(resumed.resumedCaseResultCount, 0)
        XCTAssertEqual(resumedProvider.requests.count, 1)
    }

    func testScorecardsPreserveDomainsWeightsUnscoredPromptsErrorsAndMetrics() {
        let artifactID = ModelArtifactID()
        let runID = EvaluationRunID()
        let mathPass = makeCase(
            ordinal: 0,
            domain: "math",
            expectation: .init(kind: .exact, value: "4"),
            weight: 3
        )
        let mathFail = makeCase(
            ordinal: 1,
            domain: "math",
            expectation: .init(kind: .exact, value: "5"),
            weight: 1
        )
        let freeform = makeCase(ordinal: 2, domain: "writing")
        let errored = makeCase(ordinal: 3, domain: "writing")
        let suite = EvaluationSuite(
            name: "Domains",
            revision: "1",
            cases: [mathPass, mathFail, freeform, errored],
            suiteHash: "domains"
        )
        func generation(_ text: String) -> GenerationResult {
            GenerationResult(
                generationID: GenerationID(),
                artifactID: artifactID,
                text: text,
                finishReason: .completed,
                metrics: RuntimeMetrics(
                    generatedTokenCount: 2,
                    generationDurationSeconds: 0.5,
                    totalDurationSeconds: 0.75
                )
            )
        }
        let results = [
            EvaluationCaseResult(
                caseID: mathPass.id,
                artifactID: artifactID,
                generationResult: generation("4"),
                score: .init(kind: .init(rawValue: "exact"), value: 1)
            ),
            EvaluationCaseResult(
                caseID: mathFail.id,
                artifactID: artifactID,
                generationResult: generation("4"),
                score: .init(kind: .init(rawValue: "exact"), value: 0)
            ),
            EvaluationCaseResult(
                caseID: freeform.id,
                artifactID: artifactID,
                generationResult: generation("essay")
            ),
            EvaluationCaseResult(
                caseID: errored.id,
                artifactID: artifactID,
                errorDescription: "runtime failed"
            ),
        ]

        let scorecard = EvaluationScorecardBuilder.build(
            runID: runID,
            suite: suite,
            candidates: [.init(artifactID: artifactID, blindLabel: "Candidate")],
            results: results
        )[0]

        XCTAssertEqual(scorecard.overall.caseCount, 4)
        XCTAssertEqual(scorecard.overall.scoredCaseCount, 2)
        XCTAssertEqual(scorecard.overall.passedCaseCount, 1)
        XCTAssertEqual(scorecard.overall.failedCaseCount, 1)
        XCTAssertEqual(scorecard.overall.unscoredCaseCount, 1)
        XCTAssertEqual(scorecard.overall.errorCaseCount, 1)
        XCTAssertEqual(scorecard.overall.weightedScore, 0.75)
        XCTAssertEqual(scorecard.domains.map(\.domain), ["math", "writing"])
        XCTAssertEqual(scorecard.generatedTokenCount, 6)
        XCTAssertEqual(scorecard.totalDurationSeconds, 2.25)
    }
}

private extension PromptSuiteRunnerTests {
    struct Context {
        let root: URL
        let databaseURL: URL
        let evaluations: EvaluationRepository
        let artifact: ModelArtifact
    }

    func makeContext() throws -> Context {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prompt-suite-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("models.sqlite3")
        let artifacts = try ModelArtifactRepository(databaseURL: databaseURL)
        let modelURL = root.appendingPathComponent("model", isDirectory: true)
        try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
        try artifacts.upsertIndexedModel(IndexedModelRecord(
            legacyModelID: "prompt-suite-model",
            canonicalURL: modelURL,
            displayName: "Prompt Suite Model",
            family: "test",
            modality: "text",
            totalSizeBytes: 1,
            isJANG: false,
            isJANGTQ: false,
            quantizationBits: nil,
            detectedAt: Date(timeIntervalSince1970: 100),
            source: "test",
            capabilitiesJSON: "{}"
        ))
        return Context(
            root: root,
            databaseURL: databaseURL,
            evaluations: artifacts.makeEvaluationRepository(),
            artifact: try XCTUnwrap(artifacts.artifact(legacyModelID: "prompt-suite-model"))
        )
    }

    func makeCase(
        ordinal: Int,
        domain: String,
        expectation: EvaluationExpectation? = nil,
        weight: Double = 1
    ) -> EvaluationCase {
        EvaluationCase(
            ordinal: ordinal,
            name: "Case \(ordinal)",
            messages: [GenerationMessage(role: .user, content: "Prompt \(ordinal)")],
            domain: domain,
            expectation: expectation,
            generationConfiguration: .init(maximumTokenCount: 16, seed: 7),
            weight: weight
        )
    }
}

private struct FixedScorer: EvaluationScorer {
    let identifier: String
    let value: Double

    func score(_ request: EvaluationScoringRequest) async throws -> EvaluationScore {
        EvaluationScore(
            kind: .init(rawValue: "custom"),
            value: value,
            details: ["scorer": identifier]
        )
    }
}

private final class RecordingSuiteProvider: ModelInferenceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var captured: [GenerationRequest] = []

    var requests: [GenerationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return captured
    }

    func events(for request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        lock.lock()
        captured.append(request)
        lock.unlock()
        let result = GenerationResult(
            generationID: request.id,
            artifactID: request.artifactID,
            text: "completed",
            finishReason: .completed,
            metrics: RuntimeMetrics(generatedTokenCount: 1, generationDurationSeconds: 0.1)
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(result))
            continuation.finish()
        }
    }
}

private actor SuiteStartProbe {
    private(set) var started = false

    func recordStart() {
        started = true
    }
}

private final class HangingSuiteProvider: ModelInferenceProvider, @unchecked Sendable {
    let probe: SuiteStartProbe

    init(probe: SuiteStartProbe) {
        self.probe = probe
    }

    func events(for request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.recordStart()
                do {
                    while !Task.isCancelled {
                        try await Task.sleep(nanoseconds: 10_000_000)
                    }
                } catch {}
                continuation.finish(throwing: CancellationError())
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
