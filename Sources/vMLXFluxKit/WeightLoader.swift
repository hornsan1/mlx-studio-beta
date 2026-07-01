import Foundation
@preconcurrency import MLX
import MLXNN
@preconcurrency import vMLXLMCommon

// MARK: - WeightLoader
//
// Loads safetensors weight shards from a local model directory and
// applies vMLX's JANG-aware remapping if the model has a `jang_config.json`.
//
// Flow (JANG-less path):
//   1. Read `model.safetensors.index.json` to enumerate all shards.
//   2. Open each shard via `MLX.loadArrays(url:)`.
//   3. Merge into a single `[String: MLXArray]` dict keyed by weight name.
//
// Flow (JANG path):
//   1. Parse `jang_config.json` via `JangLoader` (reused from vmlx-swift-lm).
//   2. Enumerate shards as above.
//   3. Apply per-layer quantization metadata before use — the
//      `QuantizedLinear` modules in the model module tree check the
//      `jangConfig.quantization.bitWidthsUsed[layer_idx]` to pick
//      the right decode path.
//
// Weight loading returns both a backwards-compatible merged dict and
// component-scoped dictionaries for Diffusers-style snapshots. The component
// view lets Flux/Z-Image apply transformer, encoder, and VAE weights without
// guessing ownership from a single merged keyspace.

public struct LoadedWeights: Sendable {
    public let weights: [String: MLXArray]
    public let componentWeights: [String: [String: MLXArray]]
    public let jangConfig: vMLXLMCommon.JangConfig?

    public init(
        weights: [String: MLXArray],
        componentWeights: [String: [String: MLXArray]] = [:],
        jangConfig: vMLXLMCommon.JangConfig? = nil
    ) {
        self.weights = weights
        self.componentWeights = componentWeights
        self.jangConfig = jangConfig
    }

    public func weights(forComponent component: String) -> [String: MLXArray] {
        componentWeights[component] ?? [:]
    }
}

public enum WeightLoader {
    public struct ShardManifest: Sendable, Equatable {
        public let component: String?
        public let urls: [URL]

        public init(component: String?, urls: [URL]) {
            self.component = component
            self.urls = urls
        }
    }

    /// Load all safetensors shards from a model directory and return a
    /// merged dict. If the directory contains `jang_config.json`, the
    /// parsed config is returned alongside so the caller can apply
    /// per-layer quantization during module construction.
    public static func load(from directory: URL) throws -> LoadedWeights {
        // Detect JANG first so the caller gets the config regardless of
        // the shard layout.
        let jang = try JangBridge.detect(at: directory)

        // Enumerate safetensors shards.
        let manifests = try shardManifest(in: directory)
        guard !manifests.flatMap(\.urls).isEmpty else {
            throw FluxError.weightsNotFound(directory)
        }

        // Merge all shards into a single dict.
        var merged: [String: MLXArray] = [:]
        var components: [String: [String: MLXArray]] = [:]
        for manifest in manifests {
            for shard in manifest.urls {
                let arrays = try MLX.loadArrays(url: shard)
                for (key, value) in arrays {
                    merged[key] = value
                    if let component = manifest.component {
                        components[component, default: [:]][key] = value
                    }
                }
            }
        }

        return LoadedWeights(
            weights: merged,
            componentWeights: components,
            jangConfig: jang.config
        )
    }

    /// Enumerate .safetensors files in the directory. Prefers the
    /// `model.safetensors.index.json` manifest when present (so we load
    /// shards in deterministic order), falling back to a sorted glob.
    /// If neither is found at the top level, falls through to the
    /// diffusion-layout subdirs (`transformer/`, `text_encoder/`, `vae/`)
    /// — Z-Image / Flux snapshots ship weights per-component that way
    /// and this loader needs to see all of them in one merge.
    public static func shardManifest(in directory: URL) throws -> [ShardManifest] {
        let fm = FileManager.default
        // Try top-level index first.
        if let urls = try indexedShardURLs(in: directory), !urls.isEmpty {
            return [ShardManifest(component: nil, urls: urls)]
        }
        // Top-level glob.
        let topLevel = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let topShards = topLevel
            .filter { $0.hasSuffix(".safetensors") }
            .sorted()
            .map { directory.appendingPathComponent($0) }
        if !topShards.isEmpty {
            return [ShardManifest(component: nil, urls: topShards)]
        }
        // Diffusion-layout subdir fallback. Z-Image / Flux variants store
        // shards under `transformer/`, `text_encoder/`, and `vae/` —
        // collect all three so the merged weight dict carries every
        // component the model builder needs. Prefer each subdir's own
        // `model.safetensors.index.json` when present for deterministic
        // order, otherwise enumerate.
        var manifests: [ShardManifest] = []
        for sub in ["transformer", "text_encoder", "text_encoder_2", "vae", "scheduler"] {
            let subURL = directory.appendingPathComponent(sub)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: subURL.path, isDirectory: &isDir),
                  isDir.boolValue
            else { continue }
            if let urls = try indexedShardURLs(in: subURL), !urls.isEmpty {
                manifests.append(ShardManifest(component: sub, urls: urls))
                continue
            }
            let entries = (try? fm.contentsOfDirectory(atPath: subURL.path)) ?? []
            let shards = entries
                .filter { $0.hasSuffix(".safetensors") }
                .sorted()
                .map { subURL.appendingPathComponent($0) }
            if !shards.isEmpty {
                manifests.append(ShardManifest(component: sub, urls: shards))
            }
        }
        return manifests
    }

    public static func componentLayoutIssues(
        in directory: URL,
        requiredComponents: [String],
        requiredFiles: [String] = [],
        fileManager: FileManager = .default
    ) -> [String] {
        let manifests = (try? shardManifest(in: directory)) ?? []
        let byComponent = Dictionary(uniqueKeysWithValues: manifests.compactMap { manifest in
            manifest.component.map { ($0, manifest.urls) }
        })

        var issues: [String] = []
        for component in requiredComponents {
            guard let urls = byComponent[component], !urls.isEmpty else {
                issues.append("\(component) has no safetensors shards")
                continue
            }
            for url in urls where !fileManager.fileExists(atPath: url.path) {
                issues.append("\(component)/\(url.lastPathComponent) is missing")
            }
        }

        for relativePath in requiredFiles {
            let url = relativePath
                .split(separator: "/")
                .reduce(directory) { partial, component in
                    partial.appendingPathComponent(String(component))
                }
            if !fileManager.fileExists(atPath: url.path) {
                issues.append("\(relativePath) is missing")
            }
        }
        return issues
    }

    public static func validateComponentLayout(
        in directory: URL,
        requiredComponents: [String],
        requiredFiles: [String] = []
    ) throws {
        let issues = componentLayoutIssues(
            in: directory,
            requiredComponents: requiredComponents,
            requiredFiles: requiredFiles
        )
        if !issues.isEmpty {
            throw FluxError.invalidRequest(
                "model layout incomplete at \(directory.path): \(issues.joined(separator: "; "))"
            )
        }
    }

    private static func indexedShardURLs(in directory: URL) throws -> [URL]? {
        let indexURL = directory.appendingPathComponent("model.safetensors.index.json")
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return nil }
        let data = try Data(contentsOf: indexURL)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weightMap = obj["weight_map"] as? [String: String]
        else { return nil }
        return Set(weightMap.values)
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }
}
