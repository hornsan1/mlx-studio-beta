import Foundation
import MLXStudioDomain
import MLXStudioPersistence
import XCTest
@testable import MLXStudioOptimization

final class OptimizationWorkspaceCoordinatorTests: XCTestCase {
    func testQuantizeOnlyPersistsPlanBuildsVerifiesAndPublishesLineageArtifact() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let worker = RecordingOptimizationWorker()
        let coordinator = OptimizationWorkspaceCoordinator(
            worker: worker,
            artifactRepository: context.repository,
            planRepository: context.repository.makeOptimizationPlanRepository(),
            jobRepository: context.repository.makeJobRepository()
        )
        let recipe = QuantizationRecipe(
            name: "JANG 4-bit",
            technology: .jang,
            profile: "JANG_4K",
            tensorRoleRules: ["method": "mse"]
        )
        let plan = OptimizationPlan(
            projectID: context.artifact.projectID,
            sourceArtifactID: context.artifact.id,
            objective: .init(maximumArtifactSizeBytes: 700),
            quantizationRecipe: recipe
        )
        let request = OptimizationWorkspaceRequest(
            plan: plan,
            action: .quantizeOnly,
            sourceURL: context.source,
            outputURL: context.output,
            outputName: "Optimized Fixture"
        )

        let events = try await collect(coordinator.events(for: request))

        XCTAssertEqual(worker.recordedRequests().map(\.operation), [.convert, .validate])
        XCTAssertEqual(worker.recordedRequests().first?.parameters["profile"], "JANG_4K")
        let completed = try XCTUnwrap(events.last)
        guard case .completed(let planID, let outputArtifact, true) = completed else {
            return XCTFail("Expected verified completion, got \(completed)")
        }
        XCTAssertEqual(planID, plan.id)
        let derived = try XCTUnwrap(outputArtifact)
        XCTAssertEqual(derived.name, "Optimized Fixture")
        XCTAssertEqual(derived.parentArtifactID, context.artifact.id)
        XCTAssertEqual(derived.verificationStatus, .passed)
        let persisted = try XCTUnwrap(context.repository.artifact(id: derived.id))
        XCTAssertEqual(persisted.id, derived.id)
        XCTAssertEqual(persisted.projectID, derived.projectID)
        XCTAssertEqual(persisted.parentArtifactID, derived.parentArtifactID)
        XCTAssertEqual(persisted.localURL, derived.localURL)
        XCTAssertEqual(persisted.format, derived.format)
        XCTAssertEqual(persisted.precision, derived.precision)
        XCTAssertEqual(persisted.state, derived.state)
        XCTAssertEqual(persisted.manifestID, derived.manifestID)
        XCTAssertEqual(persisted.verificationStatus, derived.verificationStatus)
        XCTAssertEqual(persisted.createdAt.timeIntervalSince1970, derived.createdAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(persisted.updatedAt.timeIntervalSince1970, derived.updatedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(
            try context.repository.makeOptimizationPlanRepository().plan(id: plan.id)?.validation.status,
            .valid
        )
    }

    func testAnalyzeOnlyPersistsPlanWithoutLaunchingWorkerOrPublishingArtifact() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let worker = RecordingOptimizationWorker()
        let coordinator = makeCoordinator(context, worker: worker)
        let plan = OptimizationPlan(
            projectID: context.artifact.projectID,
            sourceArtifactID: context.artifact.id,
            objective: .init(notes: "Analyze before changing weights")
        )

        let events = try await collect(coordinator.events(for: .init(
            plan: plan,
            action: .analyzeOnly,
            sourceURL: context.source
        )))

        XCTAssertTrue(worker.recordedRequests().isEmpty)
        XCTAssertEqual(events.count, 3)
        guard case .completed(let planID, nil, false) = events.last else {
            return XCTFail("Expected analysis-only completion")
        }
        XCTAssertEqual(planID, plan.id)
    }

    func testPruneOnlyRequiresReviewedQwenMapAndUsesPinnedWorkerOperation() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let worker = RecordingOptimizationWorker()
        let coordinator = makeCoordinator(context, worker: worker)
        let topology = ModelExpertTopology(
            architecture: "qwen3_moe",
            layers: [.init(layerIndex: 0, expertCount: 4, trainedTopK: 1)]
        )
        let plan = OptimizationPlan(
            projectID: context.artifact.projectID,
            sourceArtifactID: context.artifact.id,
            objective: .init(notes: "Reviewed one-expert removal"),
            pruningConstraints: .init(minimumSurvivorsPerLayer: 1, maximumRemovalFraction: 0.5),
            strategyProposedRemovals: [.init(layerIndex: 0, expertIndex: 3)]
        )
        let keepMap = context.root.appendingPathComponent("reviewed-keep-map.json")
        try Data(#"{"layers":{"0":{"keep":[0,1,2]}}}"#.utf8).write(to: keepMap)
        _ = try await collect(coordinator.events(for: .init(
            plan: plan,
            action: .pruneOnly,
            topology: topology,
            sourceURL: context.source,
            outputURL: context.output,
            reviewedKeepMapURL: keepMap
        )))

        let requests = worker.recordedRequests()
        XCTAssertEqual(requests.map(\.operation), [.pruneQwenMoE, .validate])
        XCTAssertEqual(requests.first?.parameters["keep-map"], keepMap.path)
        XCTAssertEqual(requests.first?.parameters["require-reviewed-comparison"], "true")
        let arguments = try PythonJANGCommandBuilder.arguments(for: try XCTUnwrap(requests.first))
        XCTAssertEqual(arguments.prefix(6), [
            "-m", "jang_tools", "--progress=json", "--quiet-text",
            "prequant-prune-qwen-moe", context.source.path,
        ])
        XCTAssertTrue(arguments.contains("--require-reviewed-comparison"))
    }

    func testFailureCancelAndDurableRecoveryRemainExplicit() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let worker = RecordingOptimizationWorker(failingOperations: [.convert])
        let coordinator = makeCoordinator(context, worker: worker)
        let plan = OptimizationPlan(
            projectID: context.artifact.projectID,
            sourceArtifactID: context.artifact.id,
            objective: .init(),
            quantizationRecipe: .init(name: "Fixture", technology: .jang, profile: "JANG_4K")
        )
        let workspaceRequest = OptimizationWorkspaceRequest(
            plan: plan,
            action: .quantizeOnly,
            sourceURL: context.source,
            outputURL: context.output
        )
        do {
            _ = try await collect(coordinator.events(for: workspaceRequest))
            XCTFail("Expected failed build to stop the workspace")
        } catch {
            XCTAssertEqual(error as? OptimizationWorkspaceError, .incompleteWorkerRun("build"))
        }

        await coordinator.cancel(workspaceRequest)
        XCTAssertEqual(
            Set(worker.cancelledJobIDs()),
            Set([workspaceRequest.buildJobID, workspaceRequest.verificationJobID])
        )

        let recoverRequest = OptimizationWorkerRequest(
            operation: .inspect,
            sourceURL: context.source
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = String(
            decoding: try encoder.encode(OptimizationWorkerJobSnapshot(request: recoverRequest)),
            as: UTF8.self
        )
        try context.repository.makeJobRepository().upsert(.init(
            id: recoverRequest.jobID,
            type: "optimization.inspect",
            state: .failed,
            errorJSON: "{\"reason\":\"fixture\"}",
            recoveryInstructions: "Retry from the immutable source.",
            payloadJSON: payload
        ))
        _ = try await collectWorker(try await coordinator.recover(jobID: recoverRequest.jobID))
        XCTAssertEqual(worker.recordedRequests().last, recoverRequest)
    }

    func testOutputSafetyRejectsNestedAndSymlinkedSourceTrees() async throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let worker = RecordingOptimizationWorker()
        let coordinator = makeCoordinator(context, worker: worker)
        let plan = OptimizationPlan(
            projectID: context.artifact.projectID,
            sourceArtifactID: context.artifact.id,
            objective: .init(),
            quantizationRecipe: .init(name: "Fixture", technology: .jang, profile: "JANG_4K")
        )
        let nested = context.source.appendingPathComponent("output")
        let symlink = context.root.appendingPathComponent("source-link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: context.source)

        for unsafeOutput in [nested, symlink] {
            let request = OptimizationWorkspaceRequest(
                plan: plan,
                action: .quantizeOnly,
                sourceURL: context.source,
                outputURL: unsafeOutput
            )
            do {
                _ = try await coordinator.review(request)
                XCTFail("Expected unsafe output rejection for \(unsafeOutput.path)")
            } catch {
                XCTAssertEqual(error as? OptimizationWorkspaceError, .unsafeOutputURL)
            }
        }
        XCTAssertTrue(worker.recordedRequests().isEmpty)
    }

    private func makeCoordinator(
        _ context: Context,
        worker: RecordingOptimizationWorker
    ) -> OptimizationWorkspaceCoordinator {
        OptimizationWorkspaceCoordinator(
            worker: worker,
            artifactRepository: context.repository,
            planRepository: context.repository.makeOptimizationPlanRepository(),
            jobRepository: context.repository.makeJobRepository()
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<OptimizationWorkspaceEvent, Error>
    ) async throws -> [OptimizationWorkspaceEvent] {
        var result: [OptimizationWorkspaceEvent] = []
        for try await event in stream { result.append(event) }
        return result
    }

    private func collectWorker(
        _ stream: AsyncThrowingStream<OptimizationWorkerEventEnvelope, Error>
    ) async throws -> [OptimizationWorkerEventEnvelope] {
        var result: [OptimizationWorkerEventEnvelope] = []
        for try await event in stream { result.append(event) }
        return result
    }

    private struct Context {
        let root: URL
        let source: URL
        let output: URL
        let repository: ModelArtifactRepository
        let artifact: ModelArtifact
    }

    private func makeContext() throws -> Context {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("optimization-workspace-\(UUID().uuidString)")
        let source = root.appendingPathComponent("source")
        let output = root.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let repository = try ModelArtifactRepository(databaseURL: root.appendingPathComponent("models.sqlite3"))
        try repository.upsertIndexedModel(.init(
            legacyModelID: "fixture-source",
            canonicalURL: source,
            displayName: "Fixture Source",
            family: "qwen3_moe",
            modality: "text",
            totalSizeBytes: 1_000,
            isJANG: false,
            isJANGTQ: false,
            quantizationBits: nil,
            detectedAt: Date(),
            source: "test",
            capabilitiesJSON: "{}"
        ))
        return Context(
            root: root,
            source: source,
            output: output,
            repository: repository,
            artifact: try XCTUnwrap(repository.artifact(legacyModelID: "fixture-source"))
        )
    }
}

private final class RecordingOptimizationWorker: OptimizationWorker, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [OptimizationWorkerRequest] = []
    private var cancellations: [JobID] = []
    private let failingOperations: Set<OptimizationWorkerOperation>

    init(failingOperations: Set<OptimizationWorkerOperation> = []) {
        self.failingOperations = failingOperations
    }

    func events(
        for request: OptimizationWorkerRequest
    ) -> AsyncThrowingStream<OptimizationWorkerEventEnvelope, Error> {
        lock.withLock { requests.append(request) }
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(
                jobID: request.jobID,
                event: .phase(index: 1, total: 1, name: request.operation.rawValue)
            ))
            if failingOperations.contains(request.operation) {
                continuation.yield(.init(
                    jobID: request.jobID,
                    event: .failed(
                        message: "fixture failure",
                        exitCode: 1,
                        partialOutput: .notPresent
                    )
                ))
            } else {
                continuation.yield(.init(
                    jobID: request.jobID,
                    event: .completed(outputURL: request.outputURL)
                ))
            }
            continuation.finish()
        }
    }

    func cancel(jobID: JobID) async {
        lock.withLock { cancellations.append(jobID) }
    }

    func diagnostics() async -> OptimizationWorkerDiagnostics {
        .init(
            executable: "/fixture/python",
            supportedOperations: [.convert, .pruneQwenMoE, .inspect, .validate]
        )
    }

    func recordedRequests() -> [OptimizationWorkerRequest] {
        lock.withLock { requests }
    }

    func cancelledJobIDs() -> [JobID] {
        lock.withLock { cancellations }
    }
}
