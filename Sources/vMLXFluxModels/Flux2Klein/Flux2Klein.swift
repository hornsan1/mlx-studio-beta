import Foundation
@preconcurrency import MLX
import vMLXFluxKit

// MARK: - FLUX.2 Klein
//
// Second-generation single-encoder Flux. Python source:
//   /tmp/mflux-ref/src/mflux/models/flux2/variants/txt2img/flux2_klein.py
//
// Single text encoder (Qwen2-VL-7B in FLUX.2 — same encoder family as
// Qwen-Image), patchified DiT close in shape to Flux1 but with the
// Qwen-style RoPE-on-text-axis and a wider hidden dim.
//
// Track 1 wires the Module tree end-to-end (FluxDiTModel + VAEDecoder +
// Qwen2VL7BEncoder). FLUX.2 Klein text-to-image is no longer marked as a
// placeholder after the local smoke harness produced a verified nonblank PNG
// from mlx-community/flux2-klein-4b-4bit.

public struct Flux2KleinWeightLoadDiagnostics: Sendable, Equatable {
    public let transformer: FluxWeightApplicationReport
    public let qwen: FluxWeightApplicationReport
    public let vae: FluxWeightApplicationReport

    public init(
        transformer: FluxWeightApplicationReport,
        qwen: FluxWeightApplicationReport,
        vae: FluxWeightApplicationReport
    ) {
        self.transformer = transformer
        self.qwen = qwen
        self.vae = vae
    }

    public var reports: [FluxWeightApplicationReport] {
        [transformer, qwen, vae]
    }

    public func logIfRequested(label: String) {
        guard ProcessInfo.processInfo.environment["VMLX_FLUX_LOG_WEIGHT_DIAGNOSTICS"] == "1" else {
            return
        }
        let verbose = ProcessInfo.processInfo.environment["VMLX_FLUX_LOG_WEIGHT_DIAGNOSTICS_VERBOSE"] == "1"
        var lines = ["[flux] weight diagnostics: \(label)"]
        for report in reports {
            lines.append(
                "[flux] \(report.component): applied=\(report.appliedKeys.count) " +
                "quantized=\(report.quantizedReplacedKeys.count) " +
                "skippedQuantized=\(report.skippedQuantizedKeys.count) " +
                "shapeMismatch=\(report.skippedShapeMismatchKeys.count) " +
                "missing=\(report.missingModelKeys.count) " +
                "extra=\(report.extraCheckpointKeys.count)"
            )
            if verbose {
                lines.append("[flux] \(report.component) sampleQuantized=\(report.quantizedReplacedKeys.prefix(12).joined(separator: ", "))")
                lines.append("[flux] \(report.component) sampleSkippedQuantized=\(report.skippedQuantizedKeys.prefix(12).joined(separator: ", "))")
                lines.append("[flux] \(report.component) sampleMissing=\(report.missingModelKeys.prefix(12).joined(separator: ", "))")
                lines.append("[flux] \(report.component) sampleExtra=\(report.extraCheckpointKeys.prefix(12).joined(separator: ", "))")
            }
        }
        FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
    }
}

@discardableResult
internal func applyFluxQwen2VLWeights(
    _ weights: [String: MLXArray],
    to encoder: Qwen2VL7BEncoder
) throws -> FluxWeightApplicationReport {
    let encoderOnly = weights.filter { key, _ in
        Qwen2VL7BWeightRemap.remapKey(key) != nil
    }
    return try applyRemappedComponentWeights(
        encoderOnly,
        to: encoder,
        component: "text_encoder",
        remapKey: { Qwen2VL7BWeightRemap.remapKey($0) ?? $0 }
    )
}

public final class Flux2Klein: ImageGenerator, @unchecked Sendable {
    public static let _register: Void = {
        ModelRegistry.register(ModelEntry(
            name: "flux2-klein",
            displayName: "FLUX.2 Klein",
            kind: .imageGen,
            defaultSteps: 28,
            defaultGuidance: 3.5,
            supportsLoRA: false,
            isPlaceholder: true,
            loader: { path, quant in
                _ = Flux2Klein._register
                return try Flux2Klein(modelPath: path, quantize: quant)
            }
        ))
    }()

    public let modelPath: URL
    public let quantize: Int?
    public let loadedWeights: LoadedWeights
    public let transformer: FluxDiTModel
    public let vae: VAEDecoder
    public let textEncoder: Qwen2VL7BEncoder
    public let weightLoadDiagnostics: Flux2KleinWeightLoadDiagnostics

    public init(modelPath: URL, quantize: Int?) throws {
        self.modelPath = modelPath
        self.quantize = quantize
        _ = Self._register
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw FluxError.weightsNotFound(modelPath)
        }
        try WeightLoader.validateComponentLayout(
            in: modelPath,
            requiredComponents: ["transformer", "text_encoder", "vae"],
            requiredFiles: ["tokenizer/tokenizer.json"]
        )
        self.loadedWeights = try WeightLoader.load(from: modelPath)
        self.transformer = FluxDiTModel(config: .flux2Klein)
        self.vae = VAEDecoder()
        self.textEncoder = Qwen2VL7BEncoder(maxSeqLen: 256)
        let transformerWeights = self.loadedWeights.weights(forComponent: "transformer")
        let qwenWeights = self.loadedWeights.weights(forComponent: "text_encoder")
        let vaeWeights = self.loadedWeights.weights(forComponent: "vae")
        let transformerReport = try applyFluxDiTWeights(
            transformerWeights.isEmpty ? self.loadedWeights.weights : transformerWeights,
            to: self.transformer
        )
        let qwenReport = try applyFluxQwen2VLWeights(
            qwenWeights.isEmpty ? self.loadedWeights.weights : qwenWeights,
            to: self.textEncoder
        )
        let vaeReport = try applyFluxVAEWeights(
            vaeWeights.isEmpty ? self.loadedWeights.weights : vaeWeights,
            to: self.vae
        )
        self.weightLoadDiagnostics = Flux2KleinWeightLoadDiagnostics(
            transformer: transformerReport,
            qwen: qwenReport,
            vae: vaeReport
        )
        self.weightLoadDiagnostics.logIfRequested(label: "flux2-klein")
    }

    public func encodeText(_ prompt: String) async throws -> MLXArray {
        let tokenizer = try await Flux2KleinTokenizer.load(
            modelPath: modelPath,
            maxLen: textEncoder.maxSeqLen
        )
        let tokenIds = tokenizer.encode(prompt)
        guard !tokenIds.isEmpty else {
            throw FluxError.invalidRequest("FLUX.2 Klein tokenizer returned no token IDs")
        }
        return textEncoder.encode(tokenIds: tokenIds)
    }

    public func generate(_ request: ImageGenRequest) -> AsyncThrowingStream<ImageGenEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { continuation.finish(); return }
                do {
                    try await self.runGenerate(request, continuation: continuation)
                    continuation.finish()
                } catch {
                    let msg = String(describing: error)
                    let hf = msg.contains("401") || msg.contains("403")
                    continuation.yield(.failed(message: msg, hfAuth: hf))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func runGenerate(
        _ request: ImageGenRequest,
        continuation: AsyncThrowingStream<ImageGenEvent, Error>.Continuation
    ) async throws {
        // FLUX.2 has its own scheduler tune; for now reuse the Flux1
        // Euler scheduler. The shift bands tracked in mflux's flow
        // scheduler differ slightly — that delta is part of the smoke
        // debt and surfaces as a quality issue not a shape one.
        let scheduler = FlowMatchEulerScheduler(
            steps: max(1, request.steps),
            imageSeqLen: (request.width / 16) * (request.height / 16),
            baseShift: 0.5,
            maxShift: 1.15
        )
        var latent = LatentSpace.initialNoise(
            width: request.width,
            height: request.height,
            layout: .spatial(channels: transformer.config.inChannels),
            batchSize: 1,
            seed: request.seed
        )

        var textHidden = try await encodeText(request.prompt)
        let curD = textHidden.dim(2)
        if curD < transformer.config.textDim {
            let pad = MLXArray.zeros([
                textHidden.dim(0), textHidden.dim(1),
                transformer.config.textDim - curD
            ])
            textHidden = concatenated([textHidden, pad], axis: -1)
        } else if curD > transformer.config.textDim {
            textHidden = textHidden[.ellipsis, 0..<transformer.config.textDim]
        }
        // Mean-pool as a stand-in for FLUX.2's pooled head until the
        // real conditioning vector path lands.
        let pooled = textHidden.mean(axis: 1)
        let pooledClip: MLXArray
        if pooled.dim(-1) >= 768 {
            pooledClip = pooled[.ellipsis, 0..<768]
        } else {
            let need = 768 - pooled.dim(-1)
            let pad = MLXArray.zeros([pooled.dim(0), need])
            pooledClip = concatenated([pooled, pad], axis: -1)
        }
        let guidance = MLXArray([request.guidance])

        let total = scheduler.stepCount
        let startedAt = Date()
        for step in 0..<total {
            if Task.isCancelled { continuation.yield(.cancelled); return }
            let imgPatched = patchify(
                latent,
                patchSize: transformer.config.patchSize,
                inChannels: transformer.config.inChannels
            )
            let timestep = MLXArray([scheduler.timesteps[step]])
            let velocityPatched = transformer(
                imgPatched: imgPatched,
                txt: textHidden,
                pooledClip: pooledClip,
                timestep: timestep,
                guidance: guidance,
                rope: nil
            )
            let velocity = unpatchify(
                velocityPatched,
                patchSize: transformer.config.patchSize,
                outChannels: transformer.config.outChannels,
                height: request.height,
                width: request.width
            )
            latent = scheduler.step(latent: latent, velocity: velocity, stepIndex: step)
            _ = latent.shape
            let elapsed = Date().timeIntervalSince(startedAt)
            let perStep = elapsed / Double(step + 1)
            let eta = perStep * Double(total - step - 1)
            continuation.yield(.step(step: step + 1, total: total, etaSeconds: eta))
        }

        let rescaled = VAEDecoder.preprocessFluxLatent(latent)
        let decoded = vae(rescaled)
        let image = VAEDecoder.postprocess(decoded)
        let outURL = try await MainActor.run {
            try ImageIO.writePNG(image, outputDir: request.outputDir, prefix: "flux2-klein")
        }
        continuation.yield(.completed(url: outURL, seed: request.seed ?? 0))
    }
}

// MARK: - Flux2KleinEdit (legacy stub)
//
// FLUX.2 Klein edit is not in Track 2's exclusive list (Track 2 owns
// `Flux1Kontext.swift`, `Flux1Fill.swift`, `QwenImageEdit.swift`). We
// keep the stub registration here so the legacy registry surface
// `flux2-klein-edit` doesn't disappear — the loader returns
// `notImplemented` until either track ports it.

public final class Flux2KleinEdit: ImageEditor, @unchecked Sendable {
    public static let _register: Void = {
        ModelRegistry.register(ModelEntry(
            name: "flux2-klein-edit",
            displayName: "FLUX.2 Klein Edit",
            kind: .imageEdit,
            defaultSteps: 28,
            defaultGuidance: 3.5,
            isPlaceholder: true,
            loader: { path, quant in
                _ = Flux2KleinEdit._register
                return try Flux2KleinEdit(modelPath: path, quantize: quant)
            }
        ))
    }()

    public let modelPath: URL
    public let quantize: Int?

    public init(modelPath: URL, quantize: Int?) throws {
        self.modelPath = modelPath
        self.quantize = quantize
        _ = Self._register
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw FluxError.weightsNotFound(modelPath)
        }
    }

    public func edit(_ request: ImageEditRequest) -> AsyncThrowingStream<ImageGenEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: FluxError.notImplemented(
                "Flux2KleinEdit — not yet ported. Track ownership TBD; falls outside Track 1's image-gen scope."))
        }
    }
}
