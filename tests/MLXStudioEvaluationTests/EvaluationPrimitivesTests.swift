import Foundation
import MLXStudioDomain
import MLXStudioEvaluation
import MLXStudioPersistence
import XCTest

final class EvaluationPrimitivesTests: XCTestCase {
    func testJSONLRoundTripPreservesCompleteSuiteAndCanonicalOrder() throws {
        let second = makeCase(ordinal: 2, name: "Second", expected: "two")
        let first = makeCase(ordinal: 1, name: "First", expected: "one")
        let suite = EvaluationSuite(
            name: "JSONL suite",
            revision: "r1",
            tags: ["reasoning", "smoke"],
            cases: [second, first],
            suiteHash: "suite-jsonl-hash"
        )

        let encoded = try EvaluationJSONL.encode(suite)
        let decoded = try EvaluationJSONL.decode(encoded)

        XCTAssertEqual(decoded.id, suite.id)
        XCTAssertEqual(decoded.name, suite.name)
        XCTAssertEqual(decoded.tags, suite.tags)
        XCTAssertEqual(decoded.cases, [first, second])
        XCTAssertEqual(encoded.split(separator: 0x0A).count, 2)
    }

    func testBuiltInScorersCoverExactContainsAndRegex() async throws {
        let artifactID = ModelArtifactID()
        let generation = GenerationResult(
            generationID: GenerationID(),
            artifactID: artifactID,
            text: "answer: 42",
            finishReason: .completed
        )
        let scorer = BuiltInEvaluationScorer()

        for (kind, expected) in [
            (EvaluationExpectationKind.exact, "answer: 42"),
            (.contains, "42"),
            (.regularExpression, #"answer:\s+\d+"#),
        ] {
            let evaluationCase = EvaluationCase(
                ordinal: 0,
                name: kind.rawValue,
                messages: [GenerationMessage(role: .user, content: "question")],
                expectation: EvaluationExpectation(kind: kind, value: expected)
            )
            let score = try await scorer.score(.init(
                evaluationCase: evaluationCase,
                generationResult: generation
            ))
            XCTAssertEqual(score.value, 1)
            XCTAssertEqual(score.kind.rawValue, kind.rawValue)
        }
    }

    func testGenerationManifestIsDeterministicAndCapturesExecutionInputs() throws {
        let artifactA = ModelArtifactID()
        let artifactB = ModelArtifactID()
        let suite = EvaluationSuite(
            name: "Manifest suite",
            revision: "r1",
            cases: [makeCase(ordinal: 0, name: "Case", expected: "ok")],
            suiteHash: "manifest-suite-hash"
        )
        let request = EvaluationRunRequest(
            suite: suite,
            candidates: [
                EvaluationCandidate(artifactID: artifactA, blindLabel: "A", artifactHash: "hash-a"),
                EvaluationCandidate(artifactID: artifactB, blindLabel: "B", artifactHash: "hash-b"),
            ],
            runtimeVersion: "runtime-sha",
            kernelVersion: "kernel-sha",
            executionOrder: [artifactB, artifactA],
            createdAt: Date(timeIntervalSince1970: 1_000)
        )

        let first = try EvaluationManifestBuilder.build(for: request)
        let second = try EvaluationManifestBuilder.build(for: request)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.executionOrder, [artifactB, artifactA])
        XCTAssertEqual(first.candidates.map(\.artifactHash), ["hash-a", "hash-b"])
        XCTAssertEqual(first.cases.count, 1)
        XCTAssertEqual(first.cases[0].messagesHash.count, 64)
        XCTAssertEqual(first.manifestHash.count, 64)
    }

    func testRepositoryRestoresSuiteManifestRunAndResultsAfterRestart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EvaluationRepositoryTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("models.sqlite3")
        let artifacts = try ModelArtifactRepository(databaseURL: databaseURL)
        try artifacts.upsertIndexedModel(IndexedModelRecord(
            legacyModelID: "evaluation-artifact",
            canonicalURL: URL(fileURLWithPath: "/models/evaluation-artifact"),
            displayName: "Evaluation Artifact",
            family: "qwen",
            modality: "text",
            totalSizeBytes: 1,
            isJANG: false,
            isJANGTQ: false,
            quantizationBits: nil,
            detectedAt: Date(timeIntervalSince1970: 2_000),
            source: "test",
            capabilitiesJSON: "{}"
        ))
        let artifact = try XCTUnwrap(artifacts.artifact(legacyModelID: "evaluation-artifact"))
        let suite = EvaluationSuite(
            name: "Restart suite",
            revision: "r1",
            tags: ["restart"],
            cases: [makeCase(ordinal: 0, name: "Restart case", expected: "restored")],
            suiteHash: "restart-suite-hash"
        )
        let startedAt = Date(timeIntervalSince1970: 2_100)
        let endedAt = Date(timeIntervalSince1970: 2_101)
        let request = EvaluationRunRequest(
            suite: suite,
            candidates: [EvaluationCandidate(
                artifactID: artifact.id,
                blindLabel: "A",
                artifactHash: "artifact-content-hash"
            )],
            runtimeVersion: "runtime-sha",
            kernelVersion: "kernel-sha",
            executionOrder: [artifact.id],
            createdAt: startedAt
        )
        let manifest = try EvaluationManifestBuilder.build(for: request)
        let generation = GenerationResult(
            generationID: GenerationID(),
            artifactID: artifact.id,
            text: "restored",
            finishReason: .completed,
            metrics: RuntimeMetrics(
                promptTokenCount: 2,
                generatedTokenCount: 1,
                generationDurationSeconds: 0.1,
                tokensPerSecond: 10
            )
        )
        let caseResult = EvaluationCaseResult(
            caseID: suite.cases[0].id,
            artifactID: artifact.id,
            generationResult: generation,
            score: EvaluationScore(kind: .init(rawValue: "exact"), value: 1)
        )

        let repository = artifacts.makeEvaluationRepository()
        try repository.saveRun(request: request, manifest: manifest, status: .running)
        try repository.saveCaseResult(caseResult, runID: request.id, createdAt: endedAt)
        try repository.setRunStatus(.completed, runID: request.id, endedAt: endedAt)

        let reopened = try EvaluationRepository(databaseURL: databaseURL)
        XCTAssertEqual(try reopened.suite(id: suite.id), suite)
        let restoredRun = try XCTUnwrap(reopened.run(id: request.id))
        XCTAssertEqual(restoredRun.request, request)
        XCTAssertEqual(restoredRun.manifest, manifest)
        XCTAssertEqual(restoredRun.status, .completed)
        XCTAssertEqual(restoredRun.endedAt, endedAt)
        XCTAssertEqual(try reopened.caseResults(runID: request.id), [caseResult])

        var changedSuite = suite
        changedSuite.name = "Changed after execution"
        XCTAssertThrowsError(try reopened.saveSuite(changedSuite)) { error in
            XCTAssertEqual(error as? EvaluationPersistenceError, .immutableSuite(suite.id))
        }

        let changedRequest = EvaluationRunRequest(
            id: request.id,
            suite: suite,
            candidates: request.candidates,
            runtimeVersion: "different-runtime-sha",
            kernelVersion: request.kernelVersion,
            executionOrder: request.executionOrder,
            createdAt: request.createdAt
        )
        let changedManifest = try EvaluationManifestBuilder.build(for: changedRequest)
        XCTAssertThrowsError(try reopened.saveRun(
            request: changedRequest,
            manifest: changedManifest
        )) { error in
            XCTAssertEqual(
                error as? EvaluationPersistenceError,
                .invalidPayload("evaluation run is immutable")
            )
        }
    }
}

private extension EvaluationPrimitivesTests {
    func makeCase(ordinal: Int, name: String, expected: String) -> EvaluationCase {
        EvaluationCase(
            ordinal: ordinal,
            name: name,
            messages: [
                GenerationMessage(role: .system, content: "Be exact."),
                GenerationMessage(role: .user, content: "Return \(expected)."),
            ],
            domain: "smoke",
            tags: ["tag"],
            expectation: EvaluationExpectation(kind: .exact, value: expected),
            generationConfiguration: GenerationConfiguration(
                maximumTokenCount: 32,
                temperature: 0,
                topP: 1,
                seed: 7
            ),
            weight: 1.5
        )
    }
}
