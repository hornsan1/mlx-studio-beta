import Foundation
import MLXStudioDomain
import XCTest

final class DomainContractTests: XCTestCase {
    func testIdentifiersNormalizeAndEncodeAsUUIDStrings() throws {
        let uppercase = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        let identifier = try XCTUnwrap(ModelArtifactID(rawValue: uppercase))

        XCTAssertEqual(identifier.rawValue, uppercase.lowercased())
        XCTAssertNil(ModelArtifactID(rawValue: "not-a-uuid"))

        let data = try JSONEncoder().encode(identifier)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"\(uppercase.lowercased())\"")
        XCTAssertEqual(try JSONDecoder().decode(ModelArtifactID.self, from: data), identifier)
    }

    func testSemanticValuesEncodeAsExtensibleStrings() throws {
        let format = ArtifactFormat(rawValue: "future-format")
        let data = try JSONEncoder().encode(format)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "\"future-format\"")
        XCTAssertEqual(try JSONDecoder().decode(ArtifactFormat.self, from: data), format)
    }

    func testArtifactDomainRoundTripsWithoutLosingIdentityOrLineage() throws {
        let sourceID = fixedID(ModelSourceID.self, "00000000-0000-0000-0000-000000000001")
        let projectID = fixedID(ModelProjectID.self, "00000000-0000-0000-0000-000000000002")
        let parentID = fixedID(ModelArtifactID.self, "00000000-0000-0000-0000-000000000003")
        let artifactID = fixedID(ModelArtifactID.self, "00000000-0000-0000-0000-000000000004")
        let manifestID = fixedID(ArtifactManifestID.self, "00000000-0000-0000-0000-000000000005")
        let timestamp = Date(timeIntervalSince1970: 1_750_000_000)

        let source = ModelSource(
            id: sourceID,
            legacyModelID: "legacy-7",
            localURL: URL(fileURLWithPath: "/models/source"),
            repositoryID: "org/model",
            revision: "abc123",
            architecture: "qwen",
            parameterCount: 35_000_000_000,
            activeParameterCount: 3_000_000_000,
            format: .mlx,
            precision: .init(rawValue: "bf16"),
            capabilities: [.textGeneration],
            createdAt: timestamp
        )
        let project = ModelProject(
            id: projectID,
            name: "Qwen project",
            sourceID: sourceID,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let artifact = ModelArtifact(
            id: artifactID,
            projectID: projectID,
            parentArtifactID: parentID,
            name: "Qwen JANGTQ",
            localURL: URL(fileURLWithPath: "/models/qwen-jangtq"),
            format: .jangTQ,
            precision: .init(rawValue: "4-bit"),
            state: .ready,
            manifestID: manifestID,
            verificationStatus: .passed,
            contentHash: "content-hash",
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let manifest = ArtifactManifest(
            id: manifestID,
            artifactID: artifactID,
            schemaVersion: 1,
            sourceRevision: "abc123",
            runtimeVersion: "vmlx-1",
            optimizerVersion: "jang-1",
            manifestHash: "manifest-hash",
            sourceFiles: [
                .init(relativePath: "config.json", sizeBytes: 100, sha256: "sha")
            ],
            metadata: ["architecture": "qwen"],
            createdAt: timestamp
        )
        let lineage = ArtifactLineage(
            parentArtifactID: parentID,
            childArtifactID: artifactID,
            operation: .init(rawValue: "quantize"),
            manifestID: manifestID,
            createdAt: timestamp
        )

        try assertRoundTrip(source)
        try assertRoundTrip(project)
        try assertRoundTrip(artifact)
        try assertRoundTrip(manifest)
        try assertRoundTrip(lineage)
    }

    func testGenerationContractsRoundTripAndProviderStreamsDomainEvents() async throws {
        let artifactID = fixedID(ModelArtifactID.self, "10000000-0000-0000-0000-000000000001")
        let generationID = fixedID(GenerationID.self, "10000000-0000-0000-0000-000000000002")
        let request = GenerationRequest(
            id: generationID,
            artifactID: artifactID,
            messages: [.init(role: .user, content: "Hello")],
            configuration: .init(maximumTokenCount: 64, temperature: 0, topP: 1, seed: 7),
            traceOptions: .init(capturesExpertRouting: true),
            metadata: ["suite": "smoke"]
        )
        let observation = ExpertRoutingObservation(
            layerIndex: 1,
            tokenIndex: 2,
            selectedExpertIndices: [3, 4],
            gateWeights: [0.6, 0.4]
        )
        let result = GenerationResult(
            generationID: generationID,
            artifactID: artifactID,
            text: "Hi",
            finishReason: .completed,
            metrics: .init(
                promptTokenCount: 1,
                generatedTokenCount: 1,
                generationDurationSeconds: 0.1,
                tokensPerSecond: 10
            ),
            trace: .init(expertRouting: [observation])
        )

        try assertRoundTrip(request)
        try assertRoundTrip(result)

        let provider = StubInferenceProvider(result: result)
        var events: [GenerationEvent] = []
        for try await event in provider.events(for: request) {
            events.append(event)
        }

        XCTAssertEqual(events, [.started(generationID), .textDelta("Hi"), .completed(result)])
    }

    func testEvaluationContractsPreserveSuiteCandidateAndResultFingerprints() throws {
        let artifactID = fixedID(ModelArtifactID.self, "20000000-0000-0000-0000-000000000001")
        let generationID = fixedID(GenerationID.self, "20000000-0000-0000-0000-000000000002")
        let caseID = fixedID(EvaluationCaseID.self, "20000000-0000-0000-0000-000000000003")
        let suiteID = fixedID(EvaluationSuiteID.self, "20000000-0000-0000-0000-000000000004")
        let runID = fixedID(EvaluationRunID.self, "20000000-0000-0000-0000-000000000005")
        let timestamp = Date(timeIntervalSince1970: 1_750_000_100)
        let evaluationCase = EvaluationCase(
            id: caseID,
            ordinal: 0,
            name: "Greeting",
            messages: [.init(role: .user, content: "Say hi")],
            domain: "general",
            tags: ["smoke"],
            expectation: .init(kind: .contains, value: "hi")
        )
        let suite = EvaluationSuite(
            id: suiteID,
            name: "Smoke",
            revision: "1",
            cases: [evaluationCase],
            suiteHash: "suite-hash"
        )
        let request = EvaluationRunRequest(
            id: runID,
            suite: suite,
            candidates: [.init(artifactID: artifactID, blindLabel: "A", artifactHash: "artifact-hash")],
            runtimeVersion: "vmlx-1",
            executionOrder: [artifactID],
            createdAt: timestamp
        )
        let generation = GenerationResult(
            generationID: generationID,
            artifactID: artifactID,
            text: "hi",
            finishReason: .completed
        )
        let result = EvaluationRunResult(
            runID: runID,
            suiteID: suiteID,
            status: .completed,
            caseResults: [
                .init(
                    caseID: caseID,
                    artifactID: artifactID,
                    generationResult: generation,
                    score: .init(kind: .init(rawValue: "contains"), value: 1)
                )
            ],
            startedAt: timestamp,
            endedAt: timestamp.addingTimeInterval(1)
        )

        try assertRoundTrip(request)
        try assertRoundTrip(result)
    }

    func testOptimizationPlanRoundTripsAndStrategyReturnsCandidates() async throws {
        let projectID = fixedID(ModelProjectID.self, "30000000-0000-0000-0000-000000000001")
        let artifactID = fixedID(ModelArtifactID.self, "30000000-0000-0000-0000-000000000002")
        let suiteID = fixedID(EvaluationSuiteID.self, "30000000-0000-0000-0000-000000000003")
        let analysisID = fixedID(StrategyAnalysisID.self, "30000000-0000-0000-0000-000000000004")
        let descriptor = StrategyDescriptor(
            identifier: .init(rawValue: "man"),
            version: "1",
            maturity: .production,
            supportedArchitectures: ["qwen"]
        )
        let plan = OptimizationPlan(
            projectID: projectID,
            sourceArtifactID: artifactID,
            objective: .init(maximumPeakMemoryBytes: 64_000_000_000, minimumQualityScore: 0.9),
            strategy: descriptor,
            pruningConstraints: .init(minimumSurvivorsPerLayer: 2, maximumRemovalFraction: 0.25),
            expertDirectives: [
                .init(coordinate: .init(layerIndex: 0, expertIndex: 1), action: .keep)
            ],
            quantizationRecipe: .init(name: "JANGTQ4", technology: .jangTQ, profile: "balanced"),
            estimate: .init(artifactSizeBytes: 20_000_000_000, confidence: 0.8),
            validation: .init(status: .valid)
        )
        let request = StrategyAnalysisRequest(
            id: analysisID,
            projectID: projectID,
            artifactID: artifactID,
            calibrationSuiteID: suiteID,
            objective: plan.objective,
            constraints: plan.pruningConstraints
        )

        try assertRoundTrip(plan)
        let result = try await StubPruningStrategy(descriptor: descriptor, plan: plan)
            .proposeCandidates(for: request)
        XCTAssertEqual(result.analysisID, analysisID)
        XCTAssertEqual(result.candidatePlans, [plan])
    }

    func testCoreContractsAreSendable() {
        requireSendable(ModelProject.self)
        requireSendable(ModelSource.self)
        requireSendable(ModelArtifact.self)
        requireSendable(ArtifactManifest.self)
        requireSendable(GenerationRequest.self)
        requireSendable(GenerationEvent.self)
        requireSendable(EvaluationRunRequest.self)
        requireSendable(EvaluationRunResult.self)
        requireSendable(OptimizationPlan.self)
        requireSendable(StrategyAnalysisRequest.self)
        requireSendable(StrategyAnalysisResult.self)
    }
}

private struct StubInferenceProvider: ModelInferenceProvider {
    let result: GenerationResult

    func events(for request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started(request.id))
            continuation.yield(.textDelta(result.text))
            continuation.yield(.completed(result))
            continuation.finish()
        }
    }
}

private struct StubPruningStrategy: PruningStrategy {
    let descriptor: StrategyDescriptor
    let plan: OptimizationPlan

    func proposeCandidates(for request: StrategyAnalysisRequest) async throws -> StrategyAnalysisResult {
        StrategyAnalysisResult(
            analysisID: request.id,
            descriptor: descriptor,
            candidatePlans: [plan]
        )
    }
}

private func fixedID<Tag: MLXStudioIDTag>(
    _ type: MLXStudioID<Tag>.Type,
    _ value: String
) -> MLXStudioID<Tag> {
    guard let identifier = MLXStudioID<Tag>(rawValue: value) else {
        preconditionFailure("Invalid test UUID: \(value)")
    }
    return identifier
}

private func assertRoundTrip<Value: Codable & Equatable>(
    _ value: Value,
    file: StaticString = #filePath,
    line: UInt = #line
) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    let decoded = try JSONDecoder().decode(Value.self, from: data)
    XCTAssertEqual(decoded, value, file: file, line: line)
}

private func requireSendable<Value: Sendable>(_ type: Value.Type) {}
