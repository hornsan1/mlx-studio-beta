import Foundation
@preconcurrency import MLX
import MLXNN
import vMLXFluxKit

// MARK: - DiT weight loader helper
//
// Filter the merged checkpoint to keys that belong to the DiT
// transformer (anything not under `text_encoder`, `text_encoder_2`,
// `tokenizer`, or `vae`), run the BFL → Swift remap, and push into
// the module via `Module.update(parameters:verify:)`.
//
// `verify: []` deliberately tolerates extra checkpoint keys — most
// FLUX.1 snapshots ship with auxiliary tensors (rope freqs, scheduler
// metadata) that aren't actual DiT parameters. Missing keys do still
// surface in our diagnostics dict so the caller can log them.

public struct FluxWeightApplicationReport: Sendable, Equatable {
    public let component: String
    public let appliedKeys: [String]
    public let quantizedReplacedKeys: [String]
    public let skippedQuantizedKeys: [String]
    public let skippedShapeMismatchKeys: [String]
    public let missingModelKeys: [String]
    public let extraCheckpointKeys: [String]

    public init(
        component: String,
        appliedKeys: [String],
        quantizedReplacedKeys: [String] = [],
        skippedQuantizedKeys: [String],
        skippedShapeMismatchKeys: [String],
        missingModelKeys: [String],
        extraCheckpointKeys: [String]
    ) {
        self.component = component
        self.appliedKeys = appliedKeys
        self.quantizedReplacedKeys = quantizedReplacedKeys
        self.skippedQuantizedKeys = skippedQuantizedKeys
        self.skippedShapeMismatchKeys = skippedShapeMismatchKeys
        self.missingModelKeys = missingModelKeys
        self.extraCheckpointKeys = extraCheckpointKeys
    }

    public var appliedCount: Int { appliedKeys.count }
    public var skippedCount: Int {
        skippedQuantizedKeys.count + skippedShapeMismatchKeys.count
    }
}

public struct Flux1WeightLoadDiagnostics: Sendable, Equatable {
    public let transformer: FluxWeightApplicationReport
    public let clip: FluxWeightApplicationReport
    public let t5: FluxWeightApplicationReport
    public let vae: FluxWeightApplicationReport

    public init(
        transformer: FluxWeightApplicationReport,
        clip: FluxWeightApplicationReport,
        t5: FluxWeightApplicationReport,
        vae: FluxWeightApplicationReport
    ) {
        self.transformer = transformer
        self.clip = clip
        self.t5 = t5
        self.vae = vae
    }

    public var reports: [FluxWeightApplicationReport] {
        [transformer, clip, t5, vae]
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

internal struct FluxWeightApplicationPlan {
    let appliedPairs: [(source: String, target: String)]
    let skippedQuantizedKeys: [String]
    let skippedShapeMismatchKeys: [String]
    let missingModelKeys: [String]
    let extraCheckpointKeys: [String]
}

internal struct FluxQuantizedReplacement: Equatable {
    let sourcePrefixes: [String]
    let targetPrefix: String
    let bits: Int
    let groupSize: Int
    let targetShape: [Int]

    var sourcePrefix: String {
        sourcePrefixes.first ?? ""
    }

    init(
        sourcePrefix: String,
        targetPrefix: String,
        bits: Int,
        groupSize: Int,
        targetShape: [Int]
    ) {
        self.sourcePrefixes = [sourcePrefix]
        self.targetPrefix = targetPrefix
        self.bits = bits
        self.groupSize = groupSize
        self.targetShape = targetShape
    }

    init(
        sourcePrefixes: [String],
        targetPrefix: String,
        bits: Int,
        groupSize: Int,
        targetShape: [Int]
    ) {
        self.sourcePrefixes = sourcePrefixes
        self.targetPrefix = targetPrefix
        self.bits = bits
        self.groupSize = groupSize
        self.targetShape = targetShape
    }
}

internal struct FluxQuantizedReplacementPlan {
    let replacements: [FluxQuantizedReplacement]
    let unsupportedKeys: [String]
}

private struct FluxQuantizedFusionPart {
    let sourcePrefix: String
    let targetPrefix: String
    let bits: Int
    let groupSize: Int
    let targetShape: [Int]
    let outputRows: Int
}

internal func planQuantizedModuleReplacements(
    sourceShapes: [(key: String, shape: [Int])],
    targetShapes: [String: [Int]],
    remapKey: (String) -> String
) -> FluxQuantizedReplacementPlan {
    var byPrefix: [String: [String: [Int]]] = [:]
    for item in sourceShapes {
        let parts = item.key.split(separator: ".")
        guard let leaf = parts.last else { continue }
        let prefix = parts.dropLast().joined(separator: ".")
        byPrefix[prefix, default: [:]][String(leaf)] = item.shape
    }

    var replacements: [FluxQuantizedReplacement] = []
    var unsupported: [String] = []
    var fusionParts: [String: [FluxQuantizedFusionPart]] = [:]

    for (sourcePrefix, shapes) in byPrefix {
        guard let packedShape = shapes["weight"],
              let scalesShape = shapes["scales"]
        else { continue }

        let targetWeightKey = remapKey(sourcePrefix + ".weight")
        guard targetWeightKey.hasSuffix(".weight") else {
            unsupported.append(targetWeightKey)
            continue
        }
        let targetPrefix = String(targetWeightKey.dropLast(".weight".count))
        guard let targetShape = targetShapes[targetWeightKey],
              targetShape.count == 2,
              packedShape.count == 2,
              scalesShape.count == 2,
              scalesShape[0] == packedShape[0]
        else {
            unsupported.append(targetWeightKey)
            continue
        }

        let targetInput = targetShape[1]
        let packedInput = packedShape[1]
        let numerator = packedInput * 32
        guard targetInput > 0,
              numerator % targetInput == 0
        else {
            unsupported.append(targetWeightKey)
            continue
        }
        let bits = numerator / targetInput
        guard [2, 3, 4, 6, 8].contains(bits),
              scalesShape[1] > 0,
              targetInput % scalesShape[1] == 0
        else {
            unsupported.append(targetWeightKey)
            continue
        }
        let groupSize = targetInput / scalesShape[1]
        if targetShape[0] == packedShape[0] {
            replacements.append(FluxQuantizedReplacement(
                sourcePrefix: sourcePrefix,
                targetPrefix: targetPrefix,
                bits: bits,
                groupSize: groupSize,
                targetShape: targetShape
            ))
        } else if targetShape[0] > packedShape[0] {
            fusionParts[targetPrefix, default: []].append(FluxQuantizedFusionPart(
                sourcePrefix: sourcePrefix,
                targetPrefix: targetPrefix,
                bits: bits,
                groupSize: groupSize,
                targetShape: targetShape,
                outputRows: packedShape[0]
            ))
        } else {
            unsupported.append(targetWeightKey)
        }
    }

    for (targetPrefix, parts) in fusionParts {
        guard let first = parts.first else { continue }
        let sorted = parts.sorted {
            let lhs = fluxQuantizedFusionOrder(sourcePrefix: $0.sourcePrefix)
            let rhs = fluxQuantizedFusionOrder(sourcePrefix: $1.sourcePrefix)
            if lhs != rhs { return lhs < rhs }
            return $0.sourcePrefix < $1.sourcePrefix
        }
        let outputRows = sorted.reduce(0) { $0 + $1.outputRows }
        let compatible = sorted.allSatisfy {
            $0.bits == first.bits
                && $0.groupSize == first.groupSize
                && $0.targetShape == first.targetShape
        }
        guard compatible,
              outputRows == first.targetShape[0]
        else {
            unsupported.append(targetPrefix + ".weight")
            continue
        }
        replacements.append(FluxQuantizedReplacement(
            sourcePrefixes: sorted.map(\.sourcePrefix),
            targetPrefix: targetPrefix,
            bits: first.bits,
            groupSize: first.groupSize,
            targetShape: first.targetShape
        ))
    }

    return FluxQuantizedReplacementPlan(
        replacements: replacements.sorted { $0.targetPrefix < $1.targetPrefix },
        unsupportedKeys: unsupported.sorted()
    )
}

private func fluxQuantizedFusionOrder(sourcePrefix: String) -> Int {
    let markers: [(String, Int)] = [
        (".to_q", 0),
        (".add_q_proj", 0),
        (".to_k", 1),
        (".add_k_proj", 1),
        (".to_v", 2),
        (".add_v_proj", 2),
        (".proj_mlp", 3),
    ]
    for (marker, order) in markers where sourcePrefix.contains(marker) {
        return order
    }
    return 100
}

internal func planRemappedComponentWeights(
    sourceShapes: [(key: String, shape: [Int])],
    targetShapes: [String: [Int]],
    remapKey: (String) -> String,
    quantizedReplacedKeys: Set<String> = []
) -> FluxWeightApplicationPlan {
    let targetKeys = Set(targetShapes.keys)
    let quantizedSourcePrefixes = Set(sourceShapes.compactMap { item -> String? in
        guard item.key.hasSuffix(".scales") || item.key.hasSuffix(".biases") else { return nil }
        return String(item.key.split(separator: ".").dropLast().joined(separator: "."))
    })

    var appliedPairs: [(source: String, target: String)] = []
    var skippedQuantized: [String] = []
    var skippedShapeMismatch: [String] = []
    var extra: [String] = []

    for item in sourceShapes {
        let mappedKey = remapKey(item.key)
        let sourceParts = item.key.split(separator: ".")
        let sourceLeaf = sourceParts.last.map(String.init) ?? item.key
        let sourcePrefix = sourceParts.dropLast().joined(separator: ".")

        if quantizedSourcePrefixes.contains(sourcePrefix),
           ["weight", "bias", "scales", "biases"].contains(sourceLeaf) {
            let mappedWeightKey = remapKey(sourcePrefix + ".weight")
            let mappedQuantizedKey: String
            if mappedWeightKey.hasSuffix(".weight") {
                let mappedPrefix = String(mappedWeightKey.dropLast(".weight".count))
                mappedQuantizedKey = mappedPrefix + ".\(sourceLeaf)"
            } else {
                mappedQuantizedKey = mappedKey
            }
            if !quantizedReplacedKeys.contains(mappedQuantizedKey) {
                skippedQuantized.append(mappedKey)
            }
            continue
        }

        guard let targetShape = targetShapes[mappedKey] else {
            extra.append(mappedKey)
            continue
        }
        guard targetShape == item.shape else {
            skippedShapeMismatch.append(mappedKey)
            continue
        }
        appliedPairs.append((source: item.key, target: mappedKey))
    }

    let appliedSet = Set(appliedPairs.map(\.target))
    let skippedSet = Set(skippedQuantized)
        .union(skippedShapeMismatch)
        .union(quantizedReplacedKeys)
    let missing = targetKeys
        .subtracting(appliedSet)
        .subtracting(skippedSet)
        .sorted()

    return FluxWeightApplicationPlan(
        appliedPairs: appliedPairs.sorted { $0.target < $1.target },
        skippedQuantizedKeys: skippedQuantized.sorted(),
        skippedShapeMismatchKeys: skippedShapeMismatch.sorted(),
        missingModelKeys: missing,
        extraCheckpointKeys: extra.sorted()
    )
}

internal func applyQuantizedModuleReplacements(
    _ weights: [String: MLXArray],
    to module: Module,
    remapKey: (String) -> String
) -> (replacedKeys: [String], unsupportedKeys: [String]) {
    let targetShapes = Dictionary(
        uniqueKeysWithValues: module.parameters().flattened().map { ($0.0, $0.1.shape) }
    )
    let sourceShapes = weights.map { (key: $0.key, shape: $0.value.shape) }
    let plan = planQuantizedModuleReplacements(
        sourceShapes: sourceShapes,
        targetShapes: targetShapes,
        remapKey: remapKey
    )
    let leafModules = Dictionary(uniqueKeysWithValues: module.leafModules().flattened())
    let childModules = Dictionary(uniqueKeysWithValues: module.children().flattened())

    var replaced: [String] = []
    var unsupported = plan.unsupportedKeys

    for replacement in plan.replacements {
        guard let targetModule = leafModules[replacement.targetPrefix],
              let packedWeight = stackedQuantizedArray(
                leaf: "weight",
                sourcePrefixes: replacement.sourcePrefixes,
                weights: weights
              ),
              let scales = stackedQuantizedArray(
                leaf: "scales",
                sourcePrefixes: replacement.sourcePrefixes,
                weights: weights
              )
        else {
            unsupported.append(replacement.targetPrefix)
            continue
        }

        let quantBiases = optionalStackedQuantizedArray(
            leaf: "biases",
            sourcePrefixes: replacement.sourcePrefixes,
            weights: weights
        )
        let moduleBias = optionalStackedQuantizedArray(
            leaf: "bias",
            sourcePrefixes: replacement.sourcePrefixes,
            weights: weights
        )
        let newModule: Module?
        if targetModule is Embedding {
            newModule = QuantizedEmbedding(
                weight: packedWeight,
                scales: scales,
                biases: quantBiases,
                groupSize: replacement.groupSize,
                bits: replacement.bits
            )
        } else if targetModule is Linear {
            newModule = QuantizedLinear(
                weight: packedWeight,
                bias: moduleBias,
                scales: scales,
                biases: quantBiases,
                groupSize: replacement.groupSize,
                bits: replacement.bits
            )
        } else {
            newModule = nil
        }

        guard let newModule else {
            unsupported.append(replacement.targetPrefix)
            continue
        }

        do {
            let updateTarget = quantizedUpdateTarget(
                root: module,
                targetPrefix: replacement.targetPrefix,
                childModules: childModules
            )
            try updateTarget.module.update(
                modules: ModuleChildren.unflattened([(updateTarget.localPrefix, newModule)]),
                verify: []
            )
            for leaf in ["weight", "bias", "scales", "biases"] {
                let hasAnySourceLeaf = replacement.sourcePrefixes.contains {
                    weights[$0 + ".\(leaf)"] != nil
                }
                if hasAnySourceLeaf || (leaf == "bias" && targetModule is Linear) {
                    replaced.append(replacement.targetPrefix + ".\(leaf)")
                }
            }
        } catch {
            unsupported.append(replacement.targetPrefix)
        }
    }

    return (
        replacedKeys: replaced.sorted(),
        unsupportedKeys: unsupported.sorted()
    )
}

private func quantizedUpdateTarget(
    root: Module,
    targetPrefix: String,
    childModules: [String: Module]
) -> (module: Module, localPrefix: String) {
    let parts = targetPrefix.split(separator: ".").map(String.init)
    guard parts.count > 1 else {
        return (root, targetPrefix)
    }

    for count in stride(from: parts.count - 1, through: 1, by: -1) {
        let parentPrefix = parts.prefix(count).joined(separator: ".")
        if let parent = childModules[parentPrefix] {
            let localPrefix = parts.dropFirst(count).joined(separator: ".")
            return (parent, localPrefix)
        }
    }

    return (root, targetPrefix)
}

private func stackedQuantizedArray(
    leaf: String,
    sourcePrefixes: [String],
    weights: [String: MLXArray]
) -> MLXArray? {
    let arrays = sourcePrefixes.compactMap { weights[$0 + ".\(leaf)"] }
    guard arrays.count == sourcePrefixes.count else { return nil }
    guard arrays.count > 1 else { return arrays.first }
    return concatenated(arrays, axis: 0)
}

private func optionalStackedQuantizedArray(
    leaf: String,
    sourcePrefixes: [String],
    weights: [String: MLXArray]
) -> MLXArray? {
    let arrays = sourcePrefixes.compactMap { weights[$0 + ".\(leaf)"] }
    guard !arrays.isEmpty else { return nil }
    guard arrays.count == sourcePrefixes.count else { return nil }
    guard arrays.count > 1 else { return arrays.first }
    return concatenated(arrays, axis: 0)
}

/// Apply remapped checkpoint weights only when the checkpoint tensor has
/// the exact shape of the destination parameter. Pre-quantized MLX
/// groups (`weight` + `scales`/`biases`) are skipped as a known case
/// until the corresponding module replacement path is wired through
/// `QuantizedLinear` / `QuantizedEmbedding`.
@discardableResult
internal func applyRemappedComponentWeights(
    _ weights: [String: MLXArray],
    to module: Module,
    component: String,
    remapKey: (String) -> String
) throws -> FluxWeightApplicationReport {
    let modelParams = module.parameters().flattened()
    let modelShapes = Dictionary(uniqueKeysWithValues: modelParams.map { ($0.0, $0.1.shape) })
    let sourceShapes = weights.map { (key: $0.key, shape: $0.value.shape) }
    let replacementResult = applyQuantizedModuleReplacements(
        weights,
        to: module,
        remapKey: remapKey
    )
    let plan = planRemappedComponentWeights(
        sourceShapes: sourceShapes,
        targetShapes: modelShapes,
        remapKey: remapKey,
        quantizedReplacedKeys: Set(replacementResult.replacedKeys)
    )

    var updates = plan.appliedPairs.compactMap { pair -> (String, MLXArray)? in
        guard let value = weights[pair.source] else { return nil }
        return (pair.target, value)
    }
    let zeroFilledBiases = plan.missingModelKeys.compactMap { key -> (String, MLXArray)? in
        guard key.hasSuffix(".bias"),
              let shape = modelShapes[key]
        else { return nil }
        return (key, MLXArray.zeros(shape))
    }
    updates.append(contentsOf: zeroFilledBiases)

    if !updates.isEmpty {
        try module.update(parameters: ModuleParameters.unflattened(updates), verify: [])
    }

    let zeroFilledBiasKeys = Set(zeroFilledBiases.map(\.0))

    return FluxWeightApplicationReport(
        component: component,
        appliedKeys: (plan.appliedPairs.map(\.target) + zeroFilledBiases.map(\.0)).sorted(),
        quantizedReplacedKeys: replacementResult.replacedKeys,
        skippedQuantizedKeys: (plan.skippedQuantizedKeys + replacementResult.unsupportedKeys).sorted(),
        skippedShapeMismatchKeys: plan.skippedShapeMismatchKeys,
        missingModelKeys: plan.missingModelKeys.filter { !zeroFilledBiasKeys.contains($0) },
        extraCheckpointKeys: plan.extraCheckpointKeys
    )
}

@discardableResult
internal func applyFluxDiTWeights(
    _ weights: [String: MLXArray],
    to dit: FluxDiTModel
) throws -> FluxWeightApplicationReport {
    let dropPrefixes = [
        "text_encoder.", "text_encoder_2.",
        "vae.", "decoder.", "encoder.",
        "tokenizer.", "tokenizer_2.",
        "scheduler.",
    ]
    let ditOnly = weights.filter { (key, _) in
        for prefix in dropPrefixes where key.hasPrefix(prefix) { return false }
        return true
    }
    return try applyRemappedComponentWeights(
        ditOnly,
        to: dit,
        component: "transformer",
        remapKey: Flux1WeightRemap.remapKey
    )
}

@discardableResult
internal func applyFluxCLIPWeights(
    _ weights: [String: MLXArray],
    to encoder: CLIPLEncoder
) throws -> FluxWeightApplicationReport {
    try applyRemappedComponentWeights(
        weights,
        to: encoder,
        component: "text_encoder",
        remapKey: CLIPLWeightRemap.remapKey
    )
}

@discardableResult
internal func applyFluxT5Weights(
    _ weights: [String: MLXArray],
    to encoder: T5XXLEncoder
) throws -> FluxWeightApplicationReport {
    try applyRemappedComponentWeights(
        weights,
        to: encoder,
        component: "text_encoder_2",
        remapKey: T5XXLWeightRemap.remapKey
    )
}

@discardableResult
internal func applyFluxVAEWeights(
    _ weights: [String: MLXArray],
    to vae: VAEDecoder
) throws -> FluxWeightApplicationReport {
    try applyRemappedComponentWeights(
        weights,
        to: vae,
        component: "vae",
        remapKey: VAEWeightRemap.remapKey
    )
}

// MARK: - Flux1 (Schnell + Dev)
//
// Original FLUX.1 family — dual-encoder (T5-XXL + CLIP-L) DiT with
// flow-matching sampling. Two variants:
//
//   - Schnell: 4 steps, no CFG (guidance=0). 2.3B-ish.
//   - Dev:     20 steps, CFG via guidance embed. 12B.
//
// Track 1 ships the Module trees + weight loaders end-to-end. The
// remaining smoke gap: a real M-series test fixture with safetensors so
// `Tests/vMLXFluxTests/Track1SmokeTests.swift` can prove non-noise
// pixels. Until that smoke runs green on Eric's hardware, registry
// entries stay `isPlaceholder: true`.
//
// Track 2 owns Flux1Kontext + Flux1Fill in their own files. They
// previously lived here; once Track 2 splits them out the old defs
// here will go away. Until then the file-level `_register` calls in
// the existing `Flux1Kontext` / `Flux1Fill` types (left in this file
// from the prior scaffold — DO NOT remove without Track 2 sign-off)
// continue to register the edit kinds.

internal func fluxAllowsPlaceholderTextEncoderFallback(
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> Bool {
    environment["VMLX_FLUX_ALLOW_PLACEHOLDER_TEXT_ENCODERS"] == "1"
}

public final class Flux1Schnell: ImageGenerator, @unchecked Sendable {
    public static let _register: Void = {
        ModelRegistry.register(ModelEntry(
            name: "flux1-schnell",
            displayName: "FLUX.1 Schnell",
            kind: .imageGen,
            defaultSteps: 4,
            defaultGuidance: 0.0,
            supportsLoRA: true,
            // Module tree + DiT/VAE/encoder forward passes are ported
            // (T5XXL, CLIPL, FluxDiTModel, VAEDecoder). Smoke proof on
            // real safetensors weights is gated on `VMLX_SWIFT_TEST_WEIGHTS`
            // env var. Stays placeholder until that gates green.
            isPlaceholder: true,
            loader: { path, quant in
                _ = Flux1Schnell._register
                return try Flux1Schnell(modelPath: path, quantize: quant)
            }
        ))
    }()

    public let modelPath: URL
    public let quantize: Int?
    public let loadedWeights: LoadedWeights
    public let transformer: FluxDiTModel
    public let vae: VAEDecoder
    public let t5: T5XXLEncoder
    public let clip: CLIPLEncoder
    public let weightLoadDiagnostics: Flux1WeightLoadDiagnostics

    public init(modelPath: URL, quantize: Int?) throws {
        self.modelPath = modelPath
        self.quantize = quantize
        _ = Self._register
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw FluxError.weightsNotFound(modelPath)
        }
        try WeightLoader.validateComponentLayout(
            in: modelPath,
            requiredComponents: ["transformer", "text_encoder", "text_encoder_2", "vae"],
            requiredFiles: ["tokenizer/tokenizer.json", "tokenizer_2/tokenizer.json"]
        )
        self.loadedWeights = try WeightLoader.load(from: modelPath)
        self.transformer = FluxDiTModel(config: .schnell)
        self.vae = VAEDecoder()
        // Schnell uses canonical T5-XXL (24 blocks, 4096 hidden, 64 heads × 64 dim,
        // 10240 ffn) and CLIP-L (12 blocks, 768 hidden, 12 heads).
        self.t5 = T5XXLEncoder(maxSeqLen: 256)
        self.clip = CLIPLEncoder()
        let transformerWeights = self.loadedWeights.weights(forComponent: "transformer")
        let clipWeights = self.loadedWeights.weights(forComponent: "text_encoder")
        let t5Weights = self.loadedWeights.weights(forComponent: "text_encoder_2")
        let vaeWeights = self.loadedWeights.weights(forComponent: "vae")
        let transformerReport = try applyFluxDiTWeights(
            transformerWeights.isEmpty ? self.loadedWeights.weights : transformerWeights,
            to: self.transformer
        )
        let clipReport = try applyFluxCLIPWeights(
            clipWeights.isEmpty ? self.loadedWeights.weights : clipWeights,
            to: self.clip
        )
        let t5Report = try applyFluxT5Weights(
            t5Weights.isEmpty ? self.loadedWeights.weights : t5Weights,
            to: self.t5
        )
        let vaeReport = try applyFluxVAEWeights(
            vaeWeights.isEmpty ? self.loadedWeights.weights : vaeWeights,
            to: self.vae
        )
        self.weightLoadDiagnostics = Flux1WeightLoadDiagnostics(
            transformer: transformerReport,
            clip: clipReport,
            t5: t5Report,
            vae: vaeReport
        )
        self.weightLoadDiagnostics.logIfRequested(label: "flux1-schnell")
    }

    public func generate(_ request: ImageGenRequest) -> AsyncThrowingStream<ImageGenEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
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
        }
    }

    /// Encode the prompt through both text encoders. Returns the T5
    /// caption embedding `(1, 256, 4096)` and the pooled CLIP-L vector
    /// `(1, 768)` that feed the DiT.
    ///
    /// Loaded lazily on first use so the synchronous registry loader
    /// doesn't have to host an `await`. Tokenizers are tiny — the cost
    /// is the upstream `AutoTokenizer.from(modelFolder:)` parse, which
    /// happens once per `runGenerate` call.
    public func encodeText(_ prompt: String) async throws -> (t5Out: MLXArray, clipPooled: MLXArray) {
        let t5Tok = try await T5SentencePieceTokenizer.load(modelPath: modelPath, maxLen: 256)
        let clipTok = try await CLIPBPETokenizer.load(modelPath: modelPath)
        let t5Ids = t5Tok.encode(prompt)
        let clipIds = clipTok.encode(prompt)
        let t5Embed = t5.encode(tokenIds: t5Ids)
        let (_, pooledClip) = clip.encodePooled(tokenIds: clipIds)
        return (t5Embed, pooledClip)
    }

    private func runGenerate(
        _ request: ImageGenRequest,
        continuation: AsyncThrowingStream<ImageGenEvent, Error>.Continuation
    ) async throws {
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

        // Encode the prompt through T5-XXL + CLIP-L. Normal app/CLI
        // generation must use real text encoders so prompts affect the
        // image. The all-zero fallback is kept only as an explicit debug
        // escape hatch for low-level Metal/DiT/VAE smoke isolation.
        let t5Embed: MLXArray
        let pooledClip: MLXArray
        if ProcessInfo.processInfo.environment["VMLX_FLUX_BYPASS_TEXT_ENCODERS"] == "1" {
            t5Embed = MLXArray.zeros([1, 256, 4096], dtype: .float32)
            pooledClip = MLXArray.zeros([1, 768], dtype: .float32)
        } else {
            do {
                let pair = try await encodeText(request.prompt)
                t5Embed = pair.t5Out
                pooledClip = pair.clipPooled
            } catch {
                guard fluxAllowsPlaceholderTextEncoderFallback() else {
                    throw FluxError.invalidRequest(
                        "FLUX.1 Schnell text encoding failed; install a snapshot with tokenizer/tokenizer.json and tokenizer_2/tokenizer.json. Underlying error: \(error)"
                    )
                }
                let t5Tokens = Array(repeating: 0, count: 256)
                let clipTokens = Array(repeating: 0, count: 77)
                t5Embed = t5.encode(tokenIds: t5Tokens)
                pooledClip = clip.encodePooled(tokenIds: clipTokens).pooled
            }
        }

        let total = scheduler.stepCount
        let startedAt = Date()
        // REVIEW MED-8: build the Flux axial RoPE once (it's step-invariant)
        // from the patch grid + text length, and thread it into the DiT.
        let headDim = transformer.config.dim / transformer.config.numHeads
        let ropeGridH = request.height / (8 * transformer.config.patchSize)
        let ropeGridW = request.width / (8 * transformer.config.patchSize)
        let rope = FluxRoPE(
            headDim: headDim,
            textLen: t5Embed.dim(1),
            latentH: ropeGridH,
            latentW: ropeGridW
        )
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
                txt: t5Embed,
                pooledClip: pooledClip,
                timestep: timestep,
                guidance: nil,
                rope: rope
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
            try ImageIO.writePNG(image, outputDir: request.outputDir, prefix: "flux1-schnell")
        }
        continuation.yield(.completed(url: outURL, seed: request.seed ?? 0))
    }
}

public final class Flux1Dev: ImageGenerator, @unchecked Sendable {
    public static let _register: Void = {
        ModelRegistry.register(ModelEntry(
            name: "flux1-dev",
            displayName: "FLUX.1 Dev",
            kind: .imageGen,
            defaultSteps: 20,
            defaultGuidance: 3.5,
            supportsLoRA: true,
            isPlaceholder: true,
            loader: { path, quant in
                _ = Flux1Dev._register
                return try Flux1Dev(modelPath: path, quantize: quant)
            }
        ))
    }()

    public let modelPath: URL
    public let quantize: Int?
    public let loadedWeights: LoadedWeights
    public let transformer: FluxDiTModel
    public let vae: VAEDecoder
    public let t5: T5XXLEncoder
    public let clip: CLIPLEncoder
    /// See `Flux1Schnell.weightLoadDiagnostics`.
    public let weightLoadDiagnostics: Flux1WeightLoadDiagnostics

    public init(modelPath: URL, quantize: Int?) throws {
        self.modelPath = modelPath
        self.quantize = quantize
        _ = Self._register
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw FluxError.weightsNotFound(modelPath)
        }
        try WeightLoader.validateComponentLayout(
            in: modelPath,
            requiredComponents: ["transformer", "text_encoder", "text_encoder_2", "vae"],
            requiredFiles: ["tokenizer/tokenizer.json", "tokenizer_2/tokenizer.json"]
        )
        self.loadedWeights = try WeightLoader.load(from: modelPath)
        self.transformer = FluxDiTModel(config: .dev)
        self.vae = VAEDecoder()
        self.t5 = T5XXLEncoder(maxSeqLen: 512)
        self.clip = CLIPLEncoder()
        let transformerWeights = self.loadedWeights.weights(forComponent: "transformer")
        let clipWeights = self.loadedWeights.weights(forComponent: "text_encoder")
        let t5Weights = self.loadedWeights.weights(forComponent: "text_encoder_2")
        let vaeWeights = self.loadedWeights.weights(forComponent: "vae")
        let transformerReport = try applyFluxDiTWeights(
            transformerWeights.isEmpty ? self.loadedWeights.weights : transformerWeights,
            to: self.transformer
        )
        let clipReport = try applyFluxCLIPWeights(
            clipWeights.isEmpty ? self.loadedWeights.weights : clipWeights,
            to: self.clip
        )
        let t5Report = try applyFluxT5Weights(
            t5Weights.isEmpty ? self.loadedWeights.weights : t5Weights,
            to: self.t5
        )
        let vaeReport = try applyFluxVAEWeights(
            vaeWeights.isEmpty ? self.loadedWeights.weights : vaeWeights,
            to: self.vae
        )
        self.weightLoadDiagnostics = Flux1WeightLoadDiagnostics(
            transformer: transformerReport,
            clip: clipReport,
            t5: t5Report,
            vae: vaeReport
        )
        self.weightLoadDiagnostics.logIfRequested(label: "flux1-dev")
    }

    public func generate(_ request: ImageGenRequest) -> AsyncThrowingStream<ImageGenEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
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
        }
    }

    /// Encode the prompt through both text encoders (T5 maxLen=512 for
    /// Dev, vs 256 for Schnell). Returns the T5 caption embedding
    /// `(1, 512, 4096)` and the pooled CLIP-L vector `(1, 768)`.
    public func encodeText(_ prompt: String) async throws -> (t5Out: MLXArray, clipPooled: MLXArray) {
        let t5Tok = try await T5SentencePieceTokenizer.load(modelPath: modelPath, maxLen: 512)
        let clipTok = try await CLIPBPETokenizer.load(modelPath: modelPath)
        let t5Ids = t5Tok.encode(prompt)
        let clipIds = clipTok.encode(prompt)
        let t5Embed = t5.encode(tokenIds: t5Ids)
        let (_, pooledClip) = clip.encodePooled(tokenIds: clipIds)
        return (t5Embed, pooledClip)
    }

    private func runGenerate(
        _ request: ImageGenRequest,
        continuation: AsyncThrowingStream<ImageGenEvent, Error>.Continuation
    ) async throws {
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

        // Encode the prompt (T5 maxLen=512 for Dev). Keep the zero-token
        // fallback behind the same explicit debug flag as Schnell.
        let t5Embed: MLXArray
        let pooledClip: MLXArray
        do {
            let pair = try await encodeText(request.prompt)
            t5Embed = pair.t5Out
            pooledClip = pair.clipPooled
        } catch {
            guard fluxAllowsPlaceholderTextEncoderFallback() else {
                throw FluxError.invalidRequest(
                    "FLUX.1 Dev text encoding failed; install a snapshot with tokenizer/tokenizer.json and tokenizer_2/tokenizer.json. Underlying error: \(error)"
                )
            }
            let t5Tokens = Array(repeating: 0, count: 512)
            let clipTokens = Array(repeating: 0, count: 77)
            t5Embed = t5.encode(tokenIds: t5Tokens)
            pooledClip = clip.encodePooled(tokenIds: clipTokens).pooled
        }
        let guidance = MLXArray([request.guidance])

        let total = scheduler.stepCount
        let startedAt = Date()
        // REVIEW MED-8: Flux axial RoPE (step-invariant), built from the grid.
        let devHeadDim = transformer.config.dim / transformer.config.numHeads
        let devRope = FluxRoPE(
            headDim: devHeadDim,
            textLen: t5Embed.dim(1),
            latentH: request.height / (8 * transformer.config.patchSize),
            latentW: request.width / (8 * transformer.config.patchSize))
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
                txt: t5Embed,
                pooledClip: pooledClip,
                timestep: timestep,
                guidance: guidance,
                rope: devRope
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
            try ImageIO.writePNG(image, outputDir: request.outputDir, prefix: "flux1-dev")
        }
        continuation.yield(.completed(url: outURL, seed: request.seed ?? 0))
    }
}

// MARK: - Flux1Kontext / Flux1Fill (Track 2 will split out)
//
// These edit heads are owned by Track 2 (`Flux1Kontext.swift`,
// `Flux1Fill.swift`). Until those files land we keep the existing
// scaffold registration here so the registry surface doesn't churn.
// Track 2 will delete these and move the impls to their own files.

public final class Flux1Kontext: ImageEditor, @unchecked Sendable {
    public static let _register: Void = {
        ModelRegistry.register(ModelEntry(
            name: "flux1-kontext",
            displayName: "FLUX.1 Kontext",
            kind: .imageEdit,
            defaultSteps: 28,
            defaultGuidance: 2.5,
            isPlaceholder: true,
            loader: { path, quant in
                _ = Flux1Kontext._register
                return try Flux1Kontext(modelPath: path, quantize: quant)
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
                "Flux1 Kontext edit — Track 2 owns Flux1Kontext.swift; this scaffold registration stays until that file lands."))
        }
    }
}

public final class Flux1Fill: ImageEditor, @unchecked Sendable {
    public static let _register: Void = {
        ModelRegistry.register(ModelEntry(
            name: "flux1-fill",
            displayName: "FLUX.1 Fill",
            kind: .imageEdit,
            defaultSteps: 28,
            defaultGuidance: 30.0,
            isPlaceholder: true,
            loader: { path, quant in
                _ = Flux1Fill._register
                return try Flux1Fill(modelPath: path, quantize: quant)
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
                "Flux1 Fill inpaint — Track 2 owns Flux1Fill.swift; this scaffold registration stays until that file lands."))
        }
    }
}
