import Foundation
import MLXStudioDomain
import MLXStudioPersistence
import XCTest
@testable import MLXStudioEvaluation

final class QuickCompareRunnerTests: XCTestCase {
    func testSequentialFallbackPersistsIdenticalInputsAndReproducibleManifest() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let probe = QuickCompareProviderProbe()
        let provider = RecordingQuickCompareProvider(probe: probe)
        let runner = QuickCompareRunner(
            provider: provider,
            repository: context.evaluations,
            now: { Date(timeIntervalSince1970: 1_234) }
        )
        let request = makeRequest(
            first: context.first,
            second: context.second,
            executionOrder: [context.second.id, context.first.id]
        )

        let outcome = try await runner.run(request)

        XCTAssertEqual(outcome.result.status, .completed)
        XCTAssertEqual(outcome.result.caseResults.count, 4)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.maximumActiveCount, 1)
        XCTAssertEqual(
            snapshot.requests.map(\.artifactID),
            [context.second.id, context.second.id, context.first.id, context.first.id]
        )
        XCTAssertEqual(snapshot.requests[0].messages, snapshot.requests[2].messages)
        XCTAssertEqual(snapshot.requests[0].configuration, snapshot.requests[2].configuration)
        XCTAssertEqual(snapshot.requests[0].metadata, snapshot.requests[2].metadata)
        XCTAssertEqual(
            snapshot.requests[0].metadata["evaluation_execution"],
            "sequential-fallback"
        )
        XCTAssertEqual(
            snapshot.requests[0].metadata["evaluation_template_id"],
            QuickCompareRunner.templateIdentifier
        )

        let reopened = try EvaluationRepository(databaseURL: context.databaseURL)
        let stored = try XCTUnwrap(reopened.run(id: request.id))
        XCTAssertEqual(stored.request, request)
        XCTAssertEqual(stored.manifest, outcome.manifest)
        XCTAssertEqual(stored.status, .completed)
        XCTAssertEqual(try reopened.caseResults(runID: request.id), outcome.result.caseResults)
        XCTAssertEqual(try EvaluationManifestBuilder.build(for: request), outcome.manifest)
    }

    func testCandidateFailureIsPersistedAndSequentialComparisonContinues() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let probe = QuickCompareProviderProbe()
        let provider = RecordingQuickCompareProvider(
            probe: probe,
            failingArtifactID: context.first.id
        )
        let runner = QuickCompareRunner(provider: provider, repository: context.evaluations)
        let suite = EvaluationSuite(
            name: "Failure fixture",
            revision: "1",
            cases: [makeCase(ordinal: 0)],
            suiteHash: "failure-fixture"
        )
        let request = EvaluationRunRequest(
            suite: suite,
            candidates: [
                .init(artifactID: context.first.id, blindLabel: "First"),
                .init(artifactID: context.second.id, blindLabel: "Second"),
            ],
            executionOrder: [context.first.id, context.second.id]
        )

        let outcome = try await runner.run(request)

        XCTAssertEqual(outcome.result.status, .failed)
        XCTAssertEqual(outcome.result.caseResults.count, 2)
        XCTAssertNotNil(outcome.result.caseResults[0].errorDescription)
        XCTAssertEqual(outcome.result.caseResults[1].generationResult?.artifactID, context.second.id)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requests.map(\.artifactID), [context.first.id, context.second.id])
        XCTAssertEqual(snapshot.maximumActiveCount, 1)
        XCTAssertEqual(try context.evaluations.run(id: request.id)?.status, .failed)
    }

    func testBackToBackRunsPersistIndependentSuitesInTheSameStore() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let probe = QuickCompareProviderProbe()
        let runner = QuickCompareRunner(
            provider: RecordingQuickCompareProvider(probe: probe),
            repository: context.evaluations
        )
        let configuration = GenerationConfiguration(
            maximumTokenCount: 32,
            temperature: 0,
            topP: 1,
            seed: 42
        )
        let firstSuite = try QuickCompareSuiteFactory.singlePrompt(
            prompt: "Same prompt",
            generationConfiguration: configuration
        )
        let secondSuite = try QuickCompareSuiteFactory.singlePrompt(
            prompt: "Same prompt",
            generationConfiguration: configuration
        )
        XCTAssertEqual(firstSuite, secondSuite)
        let candidates = [
            EvaluationCandidate(artifactID: context.first.id, blindLabel: "First"),
            EvaluationCandidate(artifactID: context.second.id, blindLabel: "Second"),
        ]
        let order = [context.first.id, context.second.id]
        let first = EvaluationRunRequest(
            suite: firstSuite,
            candidates: candidates,
            executionOrder: order
        )
        let second = EvaluationRunRequest(
            suite: secondSuite,
            candidates: candidates,
            executionOrder: order
        )

        _ = try await runner.run(first)
        _ = try await runner.run(second)

        XCTAssertEqual(try context.evaluations.run(id: first.id)?.status, .completed)
        XCTAssertEqual(try context.evaluations.run(id: second.id)?.status, .completed)
        XCTAssertEqual(try context.evaluations.suites().count, 1)
    }

    func testPersistedSuiteResolverReusesLegacyRandomIDForMatchingHash() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let proposed = try QuickCompareSuiteFactory.singlePrompt(
            prompt: "Legacy-compatible prompt",
            generationConfiguration: .init(maximumTokenCount: 32, seed: 42)
        )
        let legacy = EvaluationSuite(
            name: proposed.name,
            revision: "1",
            tags: proposed.tags,
            cases: proposed.cases.map {
                EvaluationCase(
                    ordinal: $0.ordinal,
                    name: $0.name,
                    messages: $0.messages,
                    expectation: $0.expectation,
                    generationConfiguration: $0.generationConfiguration
                )
            },
            suiteHash: proposed.suiteHash
        )
        try context.evaluations.saveSuite(legacy)

        let resolved = try QuickCompareSuiteFactory.resolvingPersistedSuite(
            proposed,
            repository: context.evaluations
        )

        XCTAssertEqual(resolved, legacy)
        XCTAssertNotEqual(resolved.id, proposed.id)
        XCTAssertEqual(resolved.suiteHash, proposed.suiteHash)
    }

    func testValidationRejectsDuplicateOrIncompleteCandidateOrder() {
        let artifact = ModelArtifactID()
        let other = ModelArtifactID()
        let suite = EvaluationSuite(
            name: "Validation fixture",
            revision: "1",
            cases: [makeCase(ordinal: 0)],
            suiteHash: "validation-fixture"
        )
        let duplicate = EvaluationRunRequest(
            suite: suite,
            candidates: [
                .init(artifactID: artifact, blindLabel: "A"),
                .init(artifactID: artifact, blindLabel: "B"),
            ],
            executionOrder: [artifact, artifact]
        )
        XCTAssertThrowsError(try QuickCompareRunner.validate(duplicate)) { error in
            XCTAssertEqual(error as? QuickCompareError, .duplicateCandidate(artifact))
        }

        let incomplete = EvaluationRunRequest(
            suite: suite,
            candidates: [
                .init(artifactID: artifact, blindLabel: "A"),
                .init(artifactID: other, blindLabel: "B"),
            ],
            executionOrder: [artifact]
        )
        XCTAssertThrowsError(try QuickCompareRunner.validate(incomplete)) { error in
            XCTAssertEqual(error as? QuickCompareError, .invalidExecutionOrder)
        }
    }

    func testCancellationStopsCurrentCandidateAndPersistsCancelledRun() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let probe = QuickCompareProviderProbe()
        let provider = RecordingQuickCompareProvider(
            probe: probe,
            hangingArtifactID: context.first.id
        )
        let runner = QuickCompareRunner(provider: provider, repository: context.evaluations)
        let suite = EvaluationSuite(
            name: "Cancellation fixture",
            revision: "1",
            cases: [makeCase(ordinal: 0)],
            suiteHash: "cancellation-fixture"
        )
        let request = EvaluationRunRequest(
            suite: suite,
            candidates: [
                .init(artifactID: context.first.id, blindLabel: "First"),
                .init(artifactID: context.second.id, blindLabel: "Second"),
            ],
            executionOrder: [context.first.id, context.second.id]
        )
        let task = Task { try await runner.run(request) }
        try await waitUntil { await probe.snapshot().requests.count == 1 }

        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        XCTAssertEqual(try context.evaluations.run(id: request.id)?.status, .cancelled)
        let snapshot = await probe.snapshot()
        XCTAssertEqual(snapshot.requests.map(\.artifactID), [context.first.id])
    }
}

private extension QuickCompareRunnerTests {
    struct Context {
        let root: URL
        let databaseURL: URL
        let evaluations: EvaluationRepository
        let first: ModelArtifact
        let second: ModelArtifact
    }

    func makeContext() throws -> Context {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quick-compare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("models.sqlite3")
        let artifacts = try ModelArtifactRepository(databaseURL: databaseURL)
        let firstURL = root.appendingPathComponent("first", isDirectory: true)
        let secondURL = root.appendingPathComponent("second", isDirectory: true)
        try FileManager.default.createDirectory(at: firstURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secondURL, withIntermediateDirectories: true)
        try artifacts.upsertIndexedModel(.init(
            legacyModelID: "quick-first",
            canonicalURL: firstURL,
            displayName: "First",
            family: "fixture",
            modality: "text",
            totalSizeBytes: 100,
            isJANG: false,
            isJANGTQ: false,
            quantizationBits: nil,
            detectedAt: Date(timeIntervalSince1970: 10),
            source: "test",
            capabilitiesJSON: "{}"
        ))
        try artifacts.upsertIndexedModel(.init(
            legacyModelID: "quick-second",
            canonicalURL: secondURL,
            displayName: "Second",
            family: "fixture",
            modality: "text",
            totalSizeBytes: 100,
            isJANG: false,
            isJANGTQ: false,
            quantizationBits: nil,
            detectedAt: Date(timeIntervalSince1970: 11),
            source: "test",
            capabilitiesJSON: "{}"
        ))
        return Context(
            root: root,
            databaseURL: databaseURL,
            evaluations: try EvaluationRepository(databaseURL: databaseURL),
            first: try XCTUnwrap(artifacts.artifact(legacyModelID: "quick-first")),
            second: try XCTUnwrap(artifacts.artifact(legacyModelID: "quick-second"))
        )
    }

    func makeRequest(
        first: ModelArtifact,
        second: ModelArtifact,
        executionOrder: [ModelArtifactID]
    ) -> EvaluationRunRequest {
        let suite = EvaluationSuite(
            name: "Quick Compare fixture",
            revision: "1",
            cases: [makeCase(ordinal: 0), makeCase(ordinal: 1)],
            suiteHash: "quick-compare-fixture"
        )
        return EvaluationRunRequest(
            suite: suite,
            candidates: [
                .init(artifactID: first.id, blindLabel: "First"),
                .init(artifactID: second.id, blindLabel: "Second"),
            ],
            runtimeVersion: "vmlx-test",
            kernelVersion: "mlx-test",
            executionOrder: executionOrder,
            createdAt: Date(timeIntervalSince1970: 1_200)
        )
    }

    func makeCase(ordinal: Int) -> EvaluationCase {
        EvaluationCase(
            ordinal: ordinal,
            name: "Prompt \(ordinal)",
            messages: [
                .init(role: .system, content: "Answer briefly."),
                .init(role: .user, content: "Fixture \(ordinal)"),
            ],
            generationConfiguration: .init(
                maximumTokenCount: 32,
                temperature: 0,
                topP: 1,
                seed: 42
            )
        )
    }

    func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<100 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for Quick Compare provider state")
    }
}

private enum QuickCompareProviderFixtureError: Error {
    case failed
}

private final class RecordingQuickCompareProvider: ModelInferenceProvider, @unchecked Sendable {
    let probe: QuickCompareProviderProbe
    let failingArtifactID: ModelArtifactID?
    let hangingArtifactID: ModelArtifactID?

    init(
        probe: QuickCompareProviderProbe,
        failingArtifactID: ModelArtifactID? = nil,
        hangingArtifactID: ModelArtifactID? = nil
    ) {
        self.probe = probe
        self.failingArtifactID = failingArtifactID
        self.hangingArtifactID = hangingArtifactID
    }

    func events(for request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await probe.started(request)
                if request.artifactID == failingArtifactID {
                    await probe.finished()
                    continuation.finish(throwing: QuickCompareProviderFixtureError.failed)
                    return
                }
                if request.artifactID == hangingArtifactID {
                    do {
                        while !Task.isCancelled {
                            try await Task.sleep(nanoseconds: 10_000_000)
                        }
                    } catch {}
                    await probe.finished()
                    continuation.finish(throwing: CancellationError())
                    return
                }
                await Task.yield()
                continuation.yield(.completed(.init(
                    generationID: request.id,
                    artifactID: request.artifactID,
                    text: "result-\(request.artifactID.rawValue)",
                    finishReason: .completed,
                    metrics: .init(generatedTokenCount: 1, generationDurationSeconds: 0.1)
                )))
                await probe.finished()
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

private actor QuickCompareProviderProbe {
    struct Snapshot: Sendable {
        let requests: [GenerationRequest]
        let maximumActiveCount: Int
    }

    private var requests: [GenerationRequest] = []
    private var activeCount = 0
    private var maximumActiveCount = 0

    func started(_ request: GenerationRequest) {
        requests.append(request)
        activeCount += 1
        maximumActiveCount = max(maximumActiveCount, activeCount)
    }

    func finished() {
        activeCount -= 1
    }

    func snapshot() -> Snapshot {
        Snapshot(requests: requests, maximumActiveCount: maximumActiveCount)
    }
}
