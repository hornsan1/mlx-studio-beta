import Foundation
import MLXStudioDomain

public enum VMLXInferenceProviderError: Error, Equatable, LocalizedError, Sendable {
    case artifactNotFound(ModelArtifactID)
    case artifactNotReady(ModelArtifactID, ArtifactState)
    case loadFailed(String)
    case unsupportedAttachment(String)
    case seedOutOfRange(UInt64)

    public var errorDescription: String? {
        switch self {
        case .artifactNotFound(let id):
            return "Model artifact \(id.rawValue) was not found."
        case .artifactNotReady(let id, let state):
            return "Model artifact \(id.rawValue) is \(state.rawValue), not ready."
        case .loadFailed(let message):
            return "Model load failed: \(message)"
        case .unsupportedAttachment(let mediaType):
            return "Unsupported generation attachment type: \(mediaType)"
        case .seedOutOfRange(let seed):
            return "Generation seed \(seed) exceeds the vMLX integer range."
        }
    }
}

/// Production inference boundary backed by the in-process vMLX engine.
/// Cancelling the consumer cancels the matching engine stream by generation
/// ID; no HTTP listener is involved.
public final class VMLXInferenceProvider: ModelInferenceProvider, @unchecked Sendable {
    struct Runtime: Sendable {
        var artifact: @Sendable (ModelArtifactID) async -> ModelArtifact?
        var loadedModelPath: @Sendable () async -> URL?
        var load: @Sendable (URL) async -> AsyncThrowingStream<LoadEvent, Error>
        var stream: @Sendable (ChatRequest, String) async -> AsyncThrowingStream<StreamChunk, Error>
        var cancel: @Sendable (String) async -> Void
    }

    private let runtime: Runtime

    public convenience init(engine: Engine) {
        self.init(runtime: Runtime(
            artifact: { id in
                let library = engine.modelLibrary
                return await library.artifact(id: id)
            },
            loadedModelPath: { await engine.loadedModelPath },
            load: { path in await engine.load(.init(modelPath: path)) },
            stream: { request, id in await engine.stream(request: request, id: id) },
            cancel: { id in _ = await engine.cancelStream(id: id) }
        ))
    }

    init(runtime: Runtime) {
        self.runtime = runtime
    }

    public func events(
        for request: GenerationRequest
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let streamID = request.id.rawValue
            let task = Task {
                do {
                    continuation.yield(.started(request.id))
                    try Task.checkCancellation()

                    guard let artifact = await runtime.artifact(request.artifactID) else {
                        throw VMLXInferenceProviderError.artifactNotFound(request.artifactID)
                    }
                    guard artifact.state == .ready else {
                        throw VMLXInferenceProviderError.artifactNotReady(artifact.id, artifact.state)
                    }

                    if await runtime.loadedModelPath()?.standardizedFileURL
                        != artifact.localURL.standardizedFileURL
                    {
                        for try await event in await runtime.load(artifact.localURL) {
                            try Task.checkCancellation()
                            if case .failed(let message) = event {
                                throw VMLXInferenceProviderError.loadFailed(message)
                            }
                        }
                    }

                    let chatRequest = try Self.chatRequest(for: request, artifact: artifact)
                    let startedAt = Date()
                    var text = ""
                    var reasoning = ""
                    var metrics = RuntimeMetrics()
                    var finishReason: GenerationFinishReason = .completed
                    var tokenScores: [Double] = []

                    for try await chunk in await runtime.stream(chatRequest, streamID) {
                        try Task.checkCancellation()
                        if let delta = chunk.content, !delta.isEmpty {
                            text += delta
                            continuation.yield(.textDelta(delta))
                        }
                        if let delta = chunk.reasoning, !delta.isEmpty {
                            reasoning += delta
                            continuation.yield(.reasoningDelta(delta))
                        }
                        if let usage = chunk.usage {
                            metrics = Self.metrics(from: usage, startedAt: startedAt)
                            continuation.yield(.metrics(metrics))
                        }
                        if request.traceOptions.capturesTokenScores,
                           let logprobs = chunk.logprobs
                        {
                            tokenScores.append(contentsOf: logprobs.map { Double($0.logprob) })
                        }
                        if let reason = chunk.finishReason {
                            finishReason = Self.finishReason(from: reason)
                        }
                    }

                    if metrics.generationDurationSeconds == 0 {
                        metrics.generationDurationSeconds = Date().timeIntervalSince(startedAt)
                    }
                    let capturesTrace = request.traceOptions.capturesTokenScores
                        || request.traceOptions.capturesExpertRouting
                    let trace = capturesTrace
                        ? InferenceTrace(
                            tokenScores: tokenScores,
                            metadata: request.traceOptions.capturesExpertRouting
                                ? ["expert_routing": "not_emitted_by_current_vmlx_stream"]
                                : [:]
                        )
                        : nil
                    let result = GenerationResult(
                        generationID: request.id,
                        artifactID: artifact.id,
                        text: text,
                        reasoning: reasoning.isEmpty ? nil : reasoning,
                        finishReason: finishReason,
                        metrics: metrics,
                        trace: trace
                    )
                    continuation.yield(.completed(result))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    Task {
                        await self.runtime.cancel(streamID)
                        task.cancel()
                    }
                }
            }
        }
    }
}

extension VMLXInferenceProvider {
    static func chatRequest(
        for request: GenerationRequest,
        artifact: ModelArtifact
    ) throws -> ChatRequest {
        let seed: Int?
        if let configuredSeed = request.configuration.seed {
            guard configuredSeed <= UInt64(Int.max) else {
                throw VMLXInferenceProviderError.seedOutOfRange(configuredSeed)
            }
            seed = Int(configuredSeed)
        } else {
            seed = nil
        }

        var chatRequest = ChatRequest(
            model: artifact.name,
            messages: try request.messages.map(Self.chatMessage),
            stream: true,
            maxTokens: request.configuration.maximumTokenCount,
            temperature: usesRuntimeSamplingDefaults(request) ? nil : request.configuration.temperature,
            topP: usesRuntimeSamplingDefaults(request) ? nil : request.configuration.topP,
            repetitionPenalty: request.configuration.repetitionPenalty,
            stop: request.configuration.stopSequences.isEmpty
                ? nil : request.configuration.stopSequences,
            seed: seed,
            enableThinking: request.metadata["enable_thinking"].flatMap(Self.boolValue),
            reasoningEffort: request.metadata["reasoning_effort"],
            includeReasoning: true
        )
        if request.traceOptions.capturesTokenScores {
            chatRequest.logprobs = true
            chatRequest.topLogprobs = 0
        }
        return chatRequest
    }

    static func chatMessage(_ message: GenerationMessage) throws -> ChatRequest.Message {
        let content: ChatRequest.ContentValue
        if message.attachments.isEmpty {
            content = .string(message.content)
        } else {
            var parts: [ChatRequest.ContentPart] = []
            if !message.content.isEmpty {
                parts.append(.init(type: "text", text: message.content))
            }
            for attachment in message.attachments {
                if attachment.mediaType.lowercased().hasPrefix("image/") {
                    parts.append(.init(
                        type: "image_url",
                        imageUrl: .init(url: attachment.url.absoluteString)
                    ))
                } else if attachment.mediaType.lowercased().hasPrefix("video/") {
                    parts.append(.init(
                        type: "video_url",
                        videoUrl: .init(url: attachment.url.absoluteString)
                    ))
                } else {
                    throw VMLXInferenceProviderError.unsupportedAttachment(attachment.mediaType)
                }
            }
            content = .parts(parts)
        }
        return ChatRequest.Message(
            role: message.role.rawValue,
            content: content,
            name: message.name,
            toolCallId: message.toolCallID
        )
    }

    static func metrics(
        from usage: StreamChunk.Usage,
        startedAt: Date
    ) -> RuntimeMetrics {
        let totalDuration = usage.totalMs.map { $0 / 1_000 }
        let prefillDuration = usage.prefillMs.map { $0 / 1_000 }
        let generationDuration = totalDuration.map {
            max(0, $0 - (prefillDuration ?? 0))
        } ?? Date().timeIntervalSince(startedAt)
        return RuntimeMetrics(
            promptTokenCount: usage.promptTokens,
            generatedTokenCount: usage.completionTokens,
            cachedTokenCount: usage.cachedTokens,
            timeToFirstTokenSeconds: usage.ttftMs.map { $0 / 1_000 },
            prefillDurationSeconds: prefillDuration,
            generationDurationSeconds: generationDuration,
            totalDurationSeconds: totalDuration,
            tokensPerSecond: usage.tokensPerSecond,
            promptTokensPerSecond: usage.promptTokensPerSecond,
            peakMemoryBytes: nil,
            cacheDetail: usage.cacheDetail,
            isPartial: usage.isPartial
        )
    }

    static func finishReason(from value: String) -> GenerationFinishReason {
        switch value.lowercased() {
        case "stop", "stopped", "eos", "completed", "tool_calls": return .completed
        case "length", "max_tokens": return .length
        case "cancel", "cancelled", "timeout": return .cancelled
        case "error", "failed": return .failed
        default: return GenerationFinishReason(rawValue: value)
        }
    }

    private static func boolValue(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "1", "yes", "on": return true
        case "false", "0", "no", "off": return false
        default: return nil
        }
    }

    private static func usesRuntimeSamplingDefaults(_ request: GenerationRequest) -> Bool {
        request.metadata["vmlx_use_runtime_sampling_defaults"]
            .flatMap(boolValue) == true
    }
}
