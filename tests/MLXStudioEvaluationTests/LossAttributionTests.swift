import Foundation
import MLXStudioDomain
import MLXStudioPersistence
import XCTest
@testable import MLXStudioEvaluation

final class LossAttributionTests: XCTestCase {
    func testPlannerBuildsFullMatrixInCanonicalOrder() throws {
        let artifacts = makeArtifacts()
        let plan = try LossAttributionPlanner.plan(artifacts: Array(artifacts.reversed()))

        XCTAssertTrue(plan.usesFullMatrix)
        XCTAssertTrue(plan.missingVariants.isEmpty)
        XCTAssertEqual(plan.artifacts.map(\.variant), LossAttributionVariant.allCases)
        XCTAssertEqual(
            plan.comparisons.map(\.kind),
            LossAttributionComparisonKind.allCases
        )
        XCTAssertTrue(plan.comparisons.allSatisfy { $0.state == .notEvaluated })
        XCTAssertEqual(
            LossAttributionPlanner.candidates(for: plan).map(\.artifactID),
            plan.artifacts.map(\.artifactID)
        )
    }

    func testPlannerMarksEveryComparisonAffectedByMissingVariants() throws {
        let artifacts = makeArtifacts()
        let plan = try LossAttributionPlanner.plan(artifacts: [artifacts[0], artifacts[3]])
        let states = Dictionary(uniqueKeysWithValues: plan.comparisons.map {
            ($0.kind, $0.state)
        })

        XCTAssertFalse(plan.usesFullMatrix)
        XCTAssertEqual(plan.missingVariants, [.baseQuantized, .prunedOriginalPrecision])
        XCTAssertEqual(states[.baseQuantization], .missingTarget)
        XCTAssertEqual(states[.pruning], .missingTarget)
        XCTAssertEqual(states[.quantizationAfterPruning], .missingSource)
        XCTAssertEqual(states[.totalDeployment], .notEvaluated)
    }

    func testPlannerRejectsDuplicateRolesAndArtifacts() throws {
        let artifact = LossAttributionArtifact(
            variant: .baseOriginalPrecision,
            artifactID: ModelArtifactID()
        )
        XCTAssertThrowsError(try LossAttributionPlanner.plan(artifacts: [artifact, artifact])) {
            XCTAssertEqual(
                $0 as? LossAttributionError,
                .duplicateVariant(.baseOriginalPrecision)
            )
        }
        XCTAssertThrowsError(try LossAttributionPlanner.plan(artifacts: [
            artifact,
            .init(variant: .baseQuantized, artifactID: artifact.artifactID),
        ])) {
            XCTAssertEqual($0 as? LossAttributionError, .duplicateArtifact(artifact.artifactID))
        }
    }

    func testReportAttributesQualityPerformanceInteractionAndHumanPreference() throws {
        let artifacts = makeArtifacts()
        let plan = try LossAttributionPlanner.plan(artifacts: artifacts)
        let observations = [
            observation(artifacts[0], quality: 1.00, size: 100, memory: 80, rate: 10),
            observation(artifacts[1], quality: 0.98, size: 50, memory: 50, rate: 12),
            observation(artifacts[2], quality: 0.95, size: 75, memory: 65, rate: 11),
            observation(artifacts[3], quality: 0.90, size: 40, memory: 40, rate: 14),
        ]
        let assignment = BlindAssignment(
            responseAArtifactID: artifacts[0].artifactID,
            responseBArtifactID: artifacts[1].artifactID,
            assignmentSeed: 7,
            ordinal: 0
        )
        let judgments = [
            HumanJudgment(
                runID: EvaluationRunID(),
                caseID: EvaluationCaseID(),
                assignment: assignment,
                choice: .responseB
            ),
            HumanJudgment(
                runID: EvaluationRunID(),
                caseID: EvaluationCaseID(),
                assignment: assignment,
                choice: .tie
            ),
            HumanJudgment(
                runID: EvaluationRunID(),
                caseID: EvaluationCaseID(),
                assignment: assignment,
                choice: .bothFailed
            ),
        ]

        let report = try LossAttributionReportBuilder.build(
            runID: EvaluationRunID(),
            plan: plan,
            observations: observations,
            judgments: judgments
        )
        let comparisons = Dictionary(uniqueKeysWithValues: report.comparisons.map {
            ($0.kind, $0)
        })
        let quantization = try XCTUnwrap(comparisons[.baseQuantization])
        XCTAssertEqual(quantization.state, .measured)
        XCTAssertEqual(try XCTUnwrap(quantization.quality).change, -0.02, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(quantization.quality).loss, 0.02, accuracy: 0.000_001)
        XCTAssertEqual(
            try XCTUnwrap(quantization.performance?.storageSavingsFraction),
            0.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(quantization.performance?.peakMemorySavingsFraction),
            0.375,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(quantization.performance?.generationRateChangeFraction),
            0.2,
            accuracy: 0.000_001
        )
        XCTAssertEqual(quantization.humanPreference.sourcePreferredCount, 0)
        XCTAssertEqual(quantization.humanPreference.targetPreferredCount, 1)
        XCTAssertEqual(quantization.humanPreference.tieCount, 1)
        XCTAssertEqual(quantization.humanPreference.bothFailedCount, 1)

        XCTAssertEqual(
            try XCTUnwrap(comparisons[.pruning]?.quality).loss,
            0.05,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(comparisons[.quantizationAfterPruning]?.quality).loss,
            0.05,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(comparisons[.totalDeployment]?.quality).loss,
            0.10,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(report.qualityInteractionEffect),
            -0.03,
            accuracy: 0.000_001
        )
    }

    func testReportKeepsMissingAndUnevaluatedComparisonsExplicit() throws {
        let artifacts = makeArtifacts()
        let plan = try LossAttributionPlanner.plan(artifacts: [artifacts[0], artifacts[3]])
        let report = try LossAttributionReportBuilder.build(
            runID: EvaluationRunID(),
            plan: plan,
            observations: [observation(
                artifacts[0],
                quality: 1,
                size: 100,
                memory: 80,
                rate: 10
            )]
        )
        let comparisons = Dictionary(uniqueKeysWithValues: report.comparisons.map {
            ($0.kind, $0)
        })

        XCTAssertEqual(comparisons[.baseQuantization]?.state, .missingTarget)
        XCTAssertEqual(comparisons[.pruning]?.state, .missingTarget)
        XCTAssertEqual(comparisons[.quantizationAfterPruning]?.state, .missingSource)
        XCTAssertEqual(comparisons[.totalDeployment]?.state, .notEvaluated)
        XCTAssertNil(report.qualityInteractionEffect)
    }

    func testPartialMatrixRunsSequentiallyAndBuildsPersistedAttribution() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("loss-attribution-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let databaseURL = root.appendingPathComponent("models.sqlite3")
        let repository = try ModelArtifactRepository(databaseURL: databaseURL)
        var domainArtifacts: [ModelArtifact] = []
        for (index, size) in [100, 40].enumerated() {
            let modelURL = root.appendingPathComponent("model-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: modelURL, withIntermediateDirectories: true)
            try repository.upsertIndexedModel(IndexedModelRecord(
                legacyModelID: "loss-model-\(index)",
                canonicalURL: modelURL,
                displayName: "Loss Model \(index)",
                family: "test",
                modality: "text",
                totalSizeBytes: Int64(size),
                isJANG: false,
                isJANGTQ: false,
                quantizationBits: nil,
                detectedAt: Date(timeIntervalSince1970: Double(100 + index)),
                source: "test",
                capabilitiesJSON: "{}"
            ))
            domainArtifacts.append(try XCTUnwrap(
                repository.artifact(legacyModelID: "loss-model-\(index)")
            ))
        }
        let assignments = [
            LossAttributionArtifact(
                variant: .baseOriginalPrecision,
                artifactID: domainArtifacts[0].id
            ),
            LossAttributionArtifact(
                variant: .prunedQuantized,
                artifactID: domainArtifacts[1].id
            ),
        ]
        let plan = try LossAttributionPlanner.plan(artifacts: assignments)
        let suite = EvaluationSuite(
            name: "Loss integration",
            revision: "1",
            cases: (0..<2).map { ordinal in
                EvaluationCase(
                    ordinal: ordinal,
                    name: "Case \(ordinal)",
                    messages: [.init(role: .user, content: "Prompt \(ordinal)")],
                    domain: "quality",
                    expectation: .init(kind: .exact, value: "completed")
                )
            },
            suiteHash: "loss-integration"
        )
        let request = EvaluationRunRequest(
            suite: suite,
            candidates: LossAttributionPlanner.candidates(for: plan),
            executionOrder: plan.artifacts.map(\.artifactID)
        )
        let provider = LossRecordingProvider()
        let evaluations = repository.makeEvaluationRepository()
        let runner = try PromptSuiteRunner(
            provider: provider,
            repository: evaluations
        )
        let outcome = try await runner.run(request)
        let observations = LossAttributionObservationBuilder.build(
            plan: plan,
            outcome: outcome,
            artifactSizeBytes: [domainArtifacts[0].id: 100, domainArtifacts[1].id: 40]
        )
        let report = try LossAttributionReportBuilder.build(
            runID: request.id,
            plan: plan,
            observations: observations,
            judgments: try evaluations.humanJudgments()
        )

        XCTAssertEqual(provider.requests.map(\.artifactID), [
            domainArtifacts[0].id, domainArtifacts[0].id,
            domainArtifacts[1].id, domainArtifacts[1].id,
        ])
        XCTAssertEqual(outcome.result.status, .completed)
        XCTAssertEqual(try evaluations.caseResults(runID: request.id).count, 4)
        XCTAssertEqual(report.comparisons.map(\.state), [
            .missingTarget, .missingTarget, .missingSource, .measured,
        ])
        XCTAssertEqual(
            report.comparisons.last?.performance?.storageSavingsFraction,
            0.6
        )

        let replay = try await runner.run(request)
        XCTAssertEqual(replay.resumedCaseResultCount, 4)
        XCTAssertEqual(provider.requests.count, 4)
    }
}

private extension LossAttributionTests {
    func makeArtifacts() -> [LossAttributionArtifact] {
        LossAttributionVariant.allCases.map {
            LossAttributionArtifact(variant: $0, artifactID: ModelArtifactID())
        }
    }

    func observation(
        _ artifact: LossAttributionArtifact,
        quality: Double,
        size: Int64,
        memory: Int64,
        rate: Double
    ) -> LossAttributionObservation {
        LossAttributionObservation(
            variant: artifact.variant,
            artifactID: artifact.artifactID,
            qualityScore: quality,
            artifactSizeBytes: size,
            peakMemoryBytes: memory,
            generatedTokensPerSecond: rate
        )
    }
}

private final class LossRecordingProvider: ModelInferenceProvider, @unchecked Sendable {
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
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(GenerationResult(
                generationID: request.id,
                artifactID: request.artifactID,
                text: "completed",
                finishReason: .completed,
                metrics: RuntimeMetrics(
                    generatedTokenCount: 2,
                    generationDurationSeconds: 0.2,
                    peakMemoryBytes: 64
                )
            )))
            continuation.finish()
        }
    }
}
