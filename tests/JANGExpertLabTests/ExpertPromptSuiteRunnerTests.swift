import Foundation
import XCTest
import MLXStudioDomain
import JANGExpertLab

final class ExpertPromptSuiteRunnerTests: XCTestCase {
    func testRunnerUsesCanonicalProviderAndConvertsExpertTrace() async throws {
        let provider = RecordingExpertProvider()
        let artifactID = ModelArtifactID()
        let runner = ExpertPromptSuiteRunner(provider: provider, artifactID: artifactID)
        let mask = ExpertMask(
            layers: [2: [7]],
            lockedKeepByLayer: [2: [3]],
            topKOverride: 2
        )
        let suite = ExpertPromptSuite(
            name: "provider-contract",
            prompts: [
                ExpertPrompt(
                    id: "math-1",
                    domain: "math",
                    text: "What is 2+2?",
                    maxNewTokens: 12,
                    temperature: 0.25
                )
            ]
        )

        let runs = try await runner.run(
            suite: suite,
            config: ExpertSamplingConfiguration(topP: 0.8, topK: 4, maxTokens: 64),
            traceConfig: ExpertTraceConfiguration(mask: mask, maxTraceTokens: 1)
        )

        let request = try XCTUnwrap(provider.requests.first)
        XCTAssertEqual(request.artifactID, artifactID)
        XCTAssertEqual(request.messages, [GenerationMessage(role: .user, content: "What is 2+2?")])
        XCTAssertEqual(request.configuration.maximumTokenCount, 12)
        XCTAssertEqual(request.configuration.temperature, 0.25)
        XCTAssertEqual(request.configuration.topP, 0.8)
        XCTAssertTrue(request.traceOptions.capturesExpertRouting)
        XCTAssertEqual(request.metadata[ExpertInferenceMetadataKey.traceEnabled], "true")
        XCTAssertEqual(request.metadata[ExpertInferenceMetadataKey.traceMaximumTokens], "1")
        XCTAssertEqual(request.metadata[ExpertInferenceMetadataKey.topK], "4")

        let maskData = try XCTUnwrap(
            request.metadata[ExpertInferenceMetadataKey.maskJSON]?.data(using: .utf8)
        )
        XCTAssertEqual(try JSONDecoder().decode(ExpertMask.self, from: maskData), mask)

        let result = try XCTUnwrap(runs.first?.result)
        XCTAssertEqual(result.text, "4")
        XCTAssertEqual(result.tokens, 3)
        XCTAssertEqual(result.finishReason, .stop)
        XCTAssertEqual(result.tokenTrace?.count, 1)
        XCTAssertEqual(result.tokenTrace?.first?.disabledExperts, [7])
        XCTAssertEqual(result.layerStats.first?.layer, 2)
        XCTAssertEqual(result.layerStats.first?.tokenCount, 1)
        XCTAssertEqual(result.layerStats.first?.hitCounts, [3: 1, 5: 1])
        XCTAssertEqual(result.runtimeInfo?.backend, "vmlx")
        XCTAssertEqual(result.runtimeInfo?.maskApplied, true)
        XCTAssertEqual(result.runtimeInfo?.hookCoverageComplete, true)
        XCTAssertTrue(result.runtimeInfo?.notes.contains {
            $0 == "Expert-routing trace was capped at 1 of 2 observations."
        } == true)
    }

    func testRunnerRequiresACompletedProviderResult() async throws {
        let runner = ExpertPromptSuiteRunner(
            provider: NonCompletingExpertProvider(),
            artifactID: ModelArtifactID()
        )
        let suite = ExpertPromptSuite(
            name: "incomplete",
            prompts: [ExpertPrompt(id: "p1", domain: "general", text: "hello")]
        )

        do {
            _ = try await runner.run(suite: suite)
            XCTFail("Expected a missing completion error")
        } catch let error as ExpertPromptSuiteRunnerError {
            XCTAssertEqual(error, .providerDidNotComplete(promptID: "p1"))
        }
    }

    func testBaselineAndMaskedRunsUseTheSameSuiteAndPreserveValidatorGate() async throws {
        let provider = MaskSensitiveExpertProvider()
        let runner = ExpertPromptSuiteRunner(provider: provider, artifactID: ModelArtifactID())
        let prompt = ExpertPrompt(
            id: "exact",
            domain: "math",
            text: "2+2",
            expectedKind: .exact,
            expected: "4"
        )
        let suite = ExpertPromptSuite(name: "same-suite", prompts: [prompt])

        let baseline = try await runner.run(suite: suite)
        let masked = try await runner.run(
            suite: suite,
            traceConfig: ExpertTraceConfiguration(mask: ExpertMask(layers: [0: [1]]))
        )
        let outcome = ExpertPromptEvaluator.evaluate(
            prompt: prompt,
            baselineText: try XCTUnwrap(baseline.first?.result.text),
            maskedText: try XCTUnwrap(masked.first?.result.text)
        )

        XCTAssertEqual(outcome.baselinePassed, true)
        XCTAssertEqual(outcome.maskedPassed, false)
        XCTAssertEqual(outcome.risk, "regression")
        XCTAssertEqual(provider.promptIDs, ["2+2", "2+2"])
    }
}

private final class RecordingExpertProvider: ModelInferenceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRequests: [GenerationRequest] = []

    var requests: [GenerationRequest] {
        lock.lock()
        defer { lock.unlock() }
        return capturedRequests
    }

    func events(for request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        lock.lock()
        capturedRequests.append(request)
        lock.unlock()

        let observations = [
            ExpertRoutingObservation(
                layerIndex: 2,
                tokenIndex: 0,
                selectedExpertIndices: [3, 5],
                gateWeights: [0.75, 0.25]
            ),
            ExpertRoutingObservation(
                layerIndex: 2,
                tokenIndex: 1,
                selectedExpertIndices: [5, 3],
                gateWeights: [0.6, 0.4]
            ),
        ]
        let result = GenerationResult(
            generationID: request.id,
            artifactID: request.artifactID,
            text: "4",
            finishReason: .completed,
            metrics: RuntimeMetrics(
                generatedTokenCount: 3,
                generationDurationSeconds: 0.5,
                totalDurationSeconds: 0.6,
                tokensPerSecond: 6
            ),
            trace: InferenceTrace(
                expertRouting: observations,
                metadata: [
                    ExpertInferenceMetadataKey.backend: "vmlx",
                    ExpertInferenceMetadataKey.runtimeMode: "in_process",
                    ExpertInferenceMetadataKey.deviceName: "Apple Silicon",
                    ExpertInferenceMetadataKey.metalEnabled: "true",
                    ExpertInferenceMetadataKey.maskApplied: "true",
                    ExpertInferenceMetadataKey.hookedMOELayers: "32",
                    ExpertInferenceMetadataKey.expectedMOELayers: "32",
                    ExpertInferenceMetadataKey.hookCoverageComplete: "true",
                ]
            )
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.started(request.id))
            observations.forEach { continuation.yield(.trace($0)) }
            continuation.yield(.completed(result))
            continuation.finish()
        }
    }
}

private struct NonCompletingExpertProvider: ModelInferenceProvider {
    func events(for request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.started(request.id))
            continuation.finish()
        }
    }
}

private final class MaskSensitiveExpertProvider: ModelInferenceProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedPrompts: [String] = []

    var promptIDs: [String] {
        lock.lock()
        defer { lock.unlock() }
        return capturedPrompts
    }

    func events(for request: GenerationRequest) -> AsyncThrowingStream<GenerationEvent, Error> {
        let prompt = request.messages.first?.content ?? ""
        lock.lock()
        capturedPrompts.append(prompt)
        lock.unlock()
        let isMasked = request.metadata[ExpertInferenceMetadataKey.maskJSON] != nil
        let result = GenerationResult(
            generationID: request.id,
            artifactID: request.artifactID,
            text: isMasked ? "five" : "4",
            finishReason: .completed
        )
        return AsyncThrowingStream { continuation in
            continuation.yield(.completed(result))
            continuation.finish()
        }
    }
}
