import Foundation
import MLXStudioDomain
import vMLXLMCommon
import XCTest
@testable import vMLXEngine

final class VMLXInferenceProviderTests: XCTestCase {
    func testAdapterPreservesRequestOutputReasoningMetricsAndTokenScores() async throws {
        let artifact = makeArtifact()
        let probe = InferenceRuntimeProbe(artifact: artifact, loadedPath: artifact.localURL)
        let usage = StreamChunk.Usage(
            promptTokens: 12,
            completionTokens: 3,
            cachedTokens: 4,
            tokensPerSecond: 24,
            promptTokensPerSecond: 120,
            ttftMs: 50,
            prefillMs: 100,
            totalMs: 250,
            cacheDetail: "paged(4)",
            isPartial: false
        )
        await probe.setStreamChunks([
            StreamChunk(reasoning: "think "),
            StreamChunk(content: "hello "),
            StreamChunk(
                content: "world",
                finishReason: "stop",
                usage: usage,
                logprobs: [TokenLogprob(token: "world", logprob: -0.25)]
            ),
        ])
        let provider = VMLXInferenceProvider(runtime: runtime(probe))
        let request = GenerationRequest(
            artifactID: artifact.id,
            messages: [
                GenerationMessage(role: .system, content: "Be concise"),
                GenerationMessage(role: .user, content: "Hi"),
            ],
            configuration: GenerationConfiguration(
                maximumTokenCount: 33,
                temperature: 0.2,
                topP: 0.8,
                repetitionPenalty: 1.1,
                seed: 42,
                stopSequences: ["END"]
            ),
            traceOptions: InferenceTraceOptions(capturesTokenScores: true),
            metadata: ["enable_thinking": "true", "reasoning_effort": "low"]
        )

        let events = try await collect(provider.events(for: request))
        let capturedValue = await probe.capturedRequest()
        let captured = try XCTUnwrap(capturedValue)
        XCTAssertEqual(captured.model, artifact.name)
        XCTAssertEqual(captured.maxTokens, 33)
        XCTAssertEqual(captured.temperature, 0.2)
        XCTAssertEqual(captured.topP, 0.8)
        XCTAssertEqual(captured.repetitionPenalty, 1.1)
        XCTAssertEqual(captured.seed, 42)
        XCTAssertEqual(captured.stop, ["END"])
        XCTAssertEqual(captured.enableThinking, true)
        XCTAssertEqual(captured.reasoningEffort, "low")
        XCTAssertEqual(captured.logprobs, true)
        let loadedPaths = await probe.loadedPaths()
        let capturedStreamID = await probe.capturedStreamID()
        XCTAssertEqual(loadedPaths, [])
        XCTAssertEqual(capturedStreamID, request.id.rawValue)

        XCTAssertTrue(events.contains { if case .started(request.id) = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .textDelta("hello ") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .reasoningDelta("think ") = $0 { return true }; return false })
        let result = try XCTUnwrap(events.compactMap { event -> GenerationResult? in
            if case .completed(let result) = event { return result }
            return nil
        }.last)
        XCTAssertEqual(result.text, "hello world")
        XCTAssertEqual(result.reasoning, "think ")
        XCTAssertEqual(result.finishReason, .completed)
        XCTAssertEqual(result.metrics.promptTokenCount, 12)
        XCTAssertEqual(result.metrics.generatedTokenCount, 3)
        XCTAssertEqual(result.metrics.cachedTokenCount, 4)
        XCTAssertEqual(result.metrics.timeToFirstTokenSeconds, 0.05)
        XCTAssertEqual(result.metrics.prefillDurationSeconds, 0.1)
        XCTAssertEqual(result.metrics.generationDurationSeconds, 0.15)
        XCTAssertEqual(result.metrics.totalDurationSeconds, 0.25)
        XCTAssertEqual(result.metrics.tokensPerSecond, 24)
        XCTAssertEqual(result.metrics.promptTokensPerSecond, 120)
        XCTAssertEqual(result.metrics.cacheDetail, "paged(4)")
        XCTAssertEqual(result.trace?.tokenScores, [-0.25])
    }

    func testAdapterLoadsRequestedArtifactBeforeStreaming() async throws {
        let artifact = makeArtifact()
        let probe = InferenceRuntimeProbe(artifact: artifact, loadedPath: nil)
        await probe.setLoadEvents([.progress(.startingPhase(.reading)), .done])
        await probe.setStreamChunks([StreamChunk(content: "ok", finishReason: "length")])
        let request = GenerationRequest(
            artifactID: artifact.id,
            messages: [GenerationMessage(role: .user, content: "Hi")],
            metadata: ["vmlx_use_runtime_sampling_defaults": "true"]
        )

        let events = try await collect(
            VMLXInferenceProvider(runtime: runtime(probe)).events(for: request)
        )

        let loadedPaths = await probe.loadedPaths()
        XCTAssertEqual(loadedPaths, [artifact.localURL])
        let capturedRequest = await probe.capturedRequest()
        XCTAssertNil(capturedRequest?.temperature)
        XCTAssertNil(capturedRequest?.topP)
        let result = try XCTUnwrap(events.compactMap { event -> GenerationResult? in
            if case .completed(let result) = event { return result }
            return nil
        }.last)
        XCTAssertEqual(result.finishReason, .length)
    }

    func testCancellingConsumerCancelsMatchingEngineStream() async throws {
        let artifact = makeArtifact()
        let probe = InferenceRuntimeProbe(artifact: artifact, loadedPath: artifact.localURL)
        await probe.useHangingStream()
        let request = GenerationRequest(
            artifactID: artifact.id,
            messages: [GenerationMessage(role: .user, content: "Wait")]
        )
        let stream = VMLXInferenceProvider(runtime: runtime(probe)).events(for: request)
        let consumer = Task {
            for try await _ in stream {}
        }

        try await waitUntil { await probe.capturedRequest() != nil }
        consumer.cancel()
        _ = await consumer.result
        try await waitUntil { await probe.cancelledIDs().contains(request.id.rawValue) }
        let cancelledIDs = await probe.cancelledIDs()
        XCTAssertEqual(cancelledIDs, [request.id.rawValue])
    }

    func testLoadFailureStopsBeforeGenerationStream() async throws {
        let artifact = makeArtifact()
        let probe = InferenceRuntimeProbe(artifact: artifact, loadedPath: nil)
        await probe.setLoadEvents([.failed("fixture load error")])
        let request = GenerationRequest(
            artifactID: artifact.id,
            messages: [GenerationMessage(role: .user, content: "Hi")]
        )

        do {
            _ = try await collect(
                VMLXInferenceProvider(runtime: runtime(probe)).events(for: request)
            )
            XCTFail("Expected load failure")
        } catch {
            XCTAssertEqual(
                error as? VMLXInferenceProviderError,
                .loadFailed("fixture load error")
            )
        }
        let capturedRequest = await probe.capturedRequest()
        XCTAssertNil(capturedRequest)
    }

    func testUnsupportedAttachmentFailsBeforeRuntimeStream() async throws {
        let artifact = makeArtifact()
        let probe = InferenceRuntimeProbe(artifact: artifact, loadedPath: artifact.localURL)
        let request = GenerationRequest(
            artifactID: artifact.id,
            messages: [GenerationMessage(
                role: .user,
                content: "Read this",
                attachments: [GenerationAttachment(
                    url: URL(fileURLWithPath: "/tmp/file.pdf"),
                    mediaType: "application/pdf"
                )]
            )]
        )

        do {
            _ = try await collect(
                VMLXInferenceProvider(runtime: runtime(probe)).events(for: request)
            )
            XCTFail("Expected unsupported attachment failure")
        } catch {
            XCTAssertEqual(
                error as? VMLXInferenceProviderError,
                .unsupportedAttachment("application/pdf")
            )
        }
        let capturedRequest = await probe.capturedRequest()
        XCTAssertNil(capturedRequest)
    }

    func testRealArtifactGeneratesThroughProviderWhenProvided() async throws {
        guard let path = ProcessInfo.processInfo.environment["MLX_STUDIO_REAL_ARTIFACT_PATH"],
              !path.isEmpty
        else {
            throw XCTSkip("Set MLX_STUDIO_REAL_ARTIFACT_PATH for the real vMLX provider smoke")
        }
        let modelURL = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw XCTSkip("Real artifact path does not exist: \(modelURL.path)")
        }
        try stageTestMetallibIfNeeded()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VMLXInferenceProviderReal-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = Engine(
            modelLibraryDB: ModelLibraryDB(customPath: directory.appendingPathComponent("models.sqlite3")),
            settingsDB: SettingsDB(customPath: directory.appendingPathComponent("settings.sqlite3"))
        )
        defer { Task { await engine.stop() } }
        let artifact = ModelArtifact(
            projectID: ModelProjectID(),
            legacyModelID: "real-provider-smoke",
            name: modelURL.lastPathComponent,
            localURL: modelURL,
            format: .mlx,
            state: .ready
        )
        let cancellationRecorder = RealCancellationRecorder()
        let runtime = VMLXInferenceProvider.Runtime(
            artifact: { id in id == artifact.id ? artifact : nil },
            loadedModelPath: { await engine.loadedModelPath },
            load: { path in await engine.load(.init(modelPath: path)) },
            stream: { request, id in await engine.stream(request: request, id: id) },
            cancel: { id in
                let accepted = await engine.cancelStream(id: id)
                await cancellationRecorder.record(id: id, accepted: accepted)
            }
        )
        let provider = VMLXInferenceProvider(runtime: runtime)
        let request = GenerationRequest(
            artifactID: artifact.id,
            messages: [GenerationMessage(role: .user, content: "Reply with exactly: MLX_PROVIDER_OK")],
            configuration: GenerationConfiguration(
                maximumTokenCount: 24,
                temperature: 0,
                topP: 1,
                seed: 1
            ),
            metadata: ["enable_thinking": "false"]
        )

        let events = try await collect(
            provider.events(for: request)
        )
        let result = try XCTUnwrap(events.compactMap { event -> GenerationResult? in
            if case .completed(let result) = event { return result }
            return nil
        }.last)
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertGreaterThan(result.metrics.generatedTokenCount, 0)
        XCTAssertGreaterThan(result.metrics.tokensPerSecond ?? 0, 0)

        let cancellationRequest = GenerationRequest(
            artifactID: artifact.id,
            messages: [GenerationMessage(
                role: .user,
                content: "List the positive integers in order and continue until stopped."
            )],
            configuration: GenerationConfiguration(
                maximumTokenCount: 2_048,
                temperature: 0,
                topP: 1,
                seed: 2
            ),
            metadata: ["enable_thinking": "false"]
        )
        let consumer = Task {
            for try await event in provider.events(for: cancellationRequest) {
                if case .textDelta(let text) = event, !text.isEmpty { return }
            }
        }
        try await consumer.value
        try await waitUntil {
            await cancellationRecorder.records().contains {
                $0.id == cancellationRequest.id.rawValue
            }
        }
        let cancellation = await cancellationRecorder.records().first {
            $0.id == cancellationRequest.id.rawValue
        }
        XCTAssertEqual(cancellation?.accepted, true)
    }
}

private extension VMLXInferenceProviderTests {
    func makeArtifact() -> ModelArtifact {
        ModelArtifact(
            projectID: ModelProjectID(),
            legacyModelID: "fixture-model",
            name: "Fixture Model",
            localURL: URL(fileURLWithPath: "/models/fixture"),
            format: .mlx,
            state: .ready
        )
    }

    func runtime(_ probe: InferenceRuntimeProbe) -> VMLXInferenceProvider.Runtime {
        .init(
            artifact: { id in await probe.artifact(id) },
            loadedModelPath: { await probe.currentLoadedPath() },
            load: { path in await probe.load(path) },
            stream: { request, id in await probe.stream(request, id: id) },
            cancel: { id in await probe.cancel(id) }
        )
    }

    func collect(
        _ stream: AsyncThrowingStream<GenerationEvent, Error>
    ) async throws -> [GenerationEvent] {
        var events: [GenerationEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    func waitUntil(
        _ predicate: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<100 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for inference runtime state")
    }

    func stageTestMetallibIfNeeded() throws {
        let testBundle = Bundle(for: VMLXInferenceProviderTests.self).bundleURL
        let executableDirectory = testBundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        let destination = executableDirectory.appendingPathComponent("mlx.metallib")
        guard !FileManager.default.fileExists(atPath: destination.path) else { return }
        let buildDirectory = testBundle.deletingLastPathComponent()
        let source = buildDirectory
            .appendingPathComponent("vmlx_Cmlx.bundle", isDirectory: true)
            .appendingPathComponent("default.metallib")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("SwiftPM MLX metallib is not staged at \(source.path)")
        }
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

private actor InferenceRuntimeProbe {
    private let storedArtifact: ModelArtifact
    private let loadedPath: URL?
    private var loadEvents: [LoadEvent] = [.done]
    private var chunks: [StreamChunk] = []
    private var hanging = false
    private var retainedContinuation: AsyncThrowingStream<StreamChunk, Error>.Continuation?
    private var request: ChatRequest?
    private var streamID: String?
    private var loadPathsValue: [URL] = []
    private var cancelledIDsValue: [String] = []

    init(artifact: ModelArtifact, loadedPath: URL?) {
        self.storedArtifact = artifact
        self.loadedPath = loadedPath
    }

    func artifact(_ id: ModelArtifactID) -> ModelArtifact? {
        id == storedArtifact.id ? storedArtifact : nil
    }

    func currentLoadedPath() -> URL? { loadedPath }
    func setLoadEvents(_ events: [LoadEvent]) { loadEvents = events }
    func setStreamChunks(_ values: [StreamChunk]) { chunks = values }
    func useHangingStream() { hanging = true }
    func capturedRequest() -> ChatRequest? { request }
    func capturedStreamID() -> String? { streamID }
    func loadedPaths() -> [URL] { loadPathsValue }
    func cancelledIDs() -> [String] { cancelledIDsValue }

    func load(_ path: URL) -> AsyncThrowingStream<LoadEvent, Error> {
        loadPathsValue.append(path)
        let events = loadEvents
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }

    func stream(
        _ request: ChatRequest,
        id: String
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        self.request = request
        self.streamID = id
        if hanging {
            return AsyncThrowingStream { continuation in
                retainedContinuation = continuation
            }
        }
        let values = chunks
        return AsyncThrowingStream { continuation in
            for value in values { continuation.yield(value) }
            continuation.finish()
        }
    }

    func cancel(_ id: String) {
        cancelledIDsValue.append(id)
        retainedContinuation?.finish()
        retainedContinuation = nil
    }
}

private actor RealCancellationRecorder {
    struct Record: Sendable {
        let id: String
        let accepted: Bool
    }

    private var values: [Record] = []

    func record(id: String, accepted: Bool) {
        values.append(Record(id: id, accepted: accepted))
    }

    func records() -> [Record] { values }
}
