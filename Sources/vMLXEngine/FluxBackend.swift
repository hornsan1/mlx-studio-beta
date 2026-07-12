import Foundation
import vMLXFlux
import vMLXFluxKit

// MARK: - vMLX ↔ vmlx-flux bridge
//
// Wires the vMLX `Engine` actor's image generation surface to the
// vmlx-flux `FluxEngine` actor. The app's `ImageScreen` already calls
// `Engine.generateImage(prompt:model:settings:)` and subscribes to
// `imageGenStream(jobId:)` — this file replaces the `notImplemented`
// stubs with real `FluxEngine` dispatch.
//
// Lifecycle: a single `FluxEngine` is created lazily on the first image
// call and held for the Engine actor's lifetime. Switching image models
// is handled by `FluxEngine.load(name:modelPath:quantize:)` — one
// resident model at a time, matching the current SwiftUI UX.
//
// Stream semantics: `FluxEngine` returns
// `AsyncThrowingStream<ImageGenEvent, Error>`. We bridge each
// `ImageGenEvent` to the Engine's own `ImageGenEvent` (same shape, in
// the vMLXEngine namespace) and store the active job's stream so
// `imageGenStream(jobId:)` can tee off of it.

extension Engine {

    /// Lazy-loaded flux backend. Created on first call.
    internal func getOrCreateFluxBackend() -> FluxEngine {
        if let existing = fluxBackend as? FluxEngine { return existing }
        let e = FluxEngine()
        fluxBackend = e
        // Make sure the model registry is populated on first use.
        vMLXFluxModels.registerAll()
        vMLXFluxVideo.registerAll()
        return e
    }

    internal static func generatedImagesDirectory(
        fileManager: FileManager = .default
    ) throws -> URL {
        let appSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let outputDir = appSupport
            .appendingPathComponent("vMLX", isDirectory: true)
            .appendingPathComponent("Generated Images", isDirectory: true)
        try fileManager.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )
        return outputDir
    }

    /// P1 §294 — pre-load an image-gen model at serve startup. Called
    /// from `vmlxctl serve --image-model <path>`. The derived `name`
    /// is the path's last component lowercased — this name is what
    /// `lastLoadedName` will report; generateImage/editImage will
    /// accept any `model` field and dispatch to this backend as long
    /// as it stays resident (see generateImage fallback below).
    public func preloadImageModel(at modelPath: URL, runtimeName: String? = nil) async throws {
        try MetalRuntimePreflight.validateForImageGeneration()
        let flux = getOrCreateFluxBackend()
        // Resolve through fuzzy lookup so `z-image-turbo-8bit` (what
        // the HF snapshot directory is named) resolves to the canonical
        // registry entry `z-image-turbo`. Matches how the UI picks a
        // backend from a local path.
        let requested = runtimeName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved: String
        if let requested, !requested.isEmpty {
            resolved = canonicalFluxRegistryName(for: requested)
        } else {
            resolved = canonicalFluxRegistryName(forModelPath: modelPath)
        }
        if MFluxImageBackend.shouldUse(for: resolved) {
            guard let executableName = MFluxImageBackend.executableName(for: resolved),
                  MFluxImageBackend.resolvedExecutable(for: resolved) != nil else {
                throw MFluxImageBackend.BackendError.executableNotFound(
                    MFluxImageBackend.executableName(for: resolved) ?? "mflux image backend"
                )
            }
            self.lastImageModelPath = modelPath
            await self.log(.info, "engine",
                "\(executableName) image backend staged: \(resolved) at \(modelPath.lastPathComponent)")
            return
        }
        try await flux.load(name: resolved, modelPath: modelPath, quantize: nil)
        // L3 §313 — retain the path so JIT-wake + admin-wake can
        // re-hydrate after deep-sleep without re-specifying the flag.
        self.lastImageModelPath = modelPath
    }

    /// L3/L4 §313 — JIT re-hydration of the image backend when the
    /// fluxBackend was dropped by deep-sleep but we know which path
    /// to reload. Called by generateImage/editImage before dispatch.
    /// No-op when a backend is already resident OR when no path is
    /// recorded.
    internal func rehydrateImageBackendIfNeeded() async throws {
        guard lastImageModelPath != nil else { return }
        if let existing = fluxBackend as? FluxEngine,
           await existing.lastLoadedName != nil
        {
            return // already resident
        }
        guard let path = lastImageModelPath else { return }
        try await preloadImageModel(at: path)
        await self.log(.info, "engine",
            "flux backend re-hydrated on JIT wake: \(path.lastPathComponent)")
    }

    // MARK: - Typed image generation (called from ImageScreen)

    /// Run a text-to-image generation end-to-end and return the final URL.
    /// The UI subscribes to `imageGenStream(jobId:)` for progress — we
    /// kick off the actual generation here and feed the bridged events
    /// into the job registry before returning.
    public func generateImage(
        prompt: String,
        model: String,
        settings: ImageGenSettings
    ) async throws -> URL {
        try MetalRuntimePreflight.validateForImageGeneration()
        let flux = getOrCreateFluxBackend()
        let libraryEntries = await self.modelLibrary.entries()
        let libraryEntry = imageLibraryEntry(for: model, in: libraryEntries)
        try ImageGenerationSafety.validate(
            settings: settings,
            modelStorageBytes: libraryEntry?.totalSizeBytes
        )
        let requestedRegistryName = canonicalFluxRegistryName(for: model, entry: libraryEntry)
        if MFluxImageBackend.shouldUse(for: requestedRegistryName) {
            let candidatePaths = Self.uniqueImageModelCandidatePaths([
                self.lastImageModelPath,
                libraryEntry?.canonicalPath,
            ].compactMap { $0 } + Self.fallbackImageModelCandidatePaths(
                runtimeName: requestedRegistryName
            ))
            var validationErrors: [String] = []
            var selectedModelPath: URL?
            for candidate in candidatePaths {
                do {
                    try ImageModelInstallVerifier.validate(
                        runtimeName: requestedRegistryName,
                        repo: model,
                        localPath: candidate
                    )
                    selectedModelPath = candidate
                    break
                } catch {
                    validationErrors.append("\(candidate.path): \(error.localizedDescription)")
                }
            }
            guard let modelPath = selectedModelPath else {
                if !validationErrors.isEmpty {
                    throw EngineError.notImplemented(
                        "mflux image backend — no verified local model path for '\(model)'. "
                        + validationErrors.joined(separator: " ")
                    )
                }
                throw EngineError.notImplemented(
                    "mflux image backend — no local model path for '\(model)'. "
                    + "Download the model first or preload with `vmlxctl images --model <path>`."
                )
            }
            let outputDir = try Self.generatedImagesDirectory()
            let result = try await MFluxImageBackend.generate(
                prompt: prompt,
                runtimeName: requestedRegistryName,
                modelPath: modelPath,
                settings: settings,
                outputDir: outputDir
            )
            self.lastImageModelPath = modelPath
            await self.logs.append(
                .info, category: "mflux",
                "generated image with mflux backend: \(requestedRegistryName)"
            )
            return result.outputURL
        }

        // Ensure the requested model is loaded. If a different model is
        // currently resident, swap. `lastLoadedName` is an actor accessor.
        // P1 §294: when the request's `model` field doesn't match any
        // library entry BUT a backend is already resident (via
        // `vmlxctl serve --image-model <path>` preload), accept the
        // request against that backend. This matches how serve mode
        // is liberal with the chat `model` field — operators running
        // single-model CLI shouldn't have to match the name exactly.
        let lastName = await flux.lastLoadedName
        if lastName != requestedRegistryName {
            if let entry = libraryEntry {
                let registryName = canonicalFluxRegistryName(for: model, entry: entry)
                try await flux.load(
                    name: registryName,
                    modelPath: entry.canonicalPath,
                    quantize: nil
                )
                self.lastImageModelPath = entry.canonicalPath
            } else if lastName != nil {
                // Preloaded backend is resident; reuse it regardless of
                // the caller's `model` field.
                await self.logs.append(
                    .info, category: "flux",
                    "image request model='\(model)' not in library; routing to preloaded backend '\(lastName ?? "?")'"
                )
            } else {
                throw EngineError.notImplemented(
                    "FluxBackend — no model entry for '\(model)'. "
                    + "Stage it via DownloadManager first, or start with `vmlxctl serve --image-model <path>`."
                )
            }
        }
        if let libraryEntry {
            self.lastImageModelPath = libraryEntry.canonicalPath
        }

        // vMLXEngine.ImageGenSettings has a flat Int seed (-1 = random) and
        // no outputDir field; resolve the final image dir centrally so the
        // app Library can survive relaunch and macOS temp cleanup.
        let outputDir = try Self.generatedImagesDirectory()
        try? FileManager.default.createDirectory(
            at: outputDir, withIntermediateDirectories: true)

        let seed: UInt64? = settings.seed >= 0
            ? UInt64(bitPattern: Int64(settings.seed))
            : nil

        let request = vMLXFlux.ImageGenRequest(
            prompt: prompt,
            width: settings.width,
            height: settings.height,
            steps: settings.steps,
            guidance: Float(settings.guidance),
            seed: seed,
            numImages: settings.numImages,
            outputDir: outputDir
        )

        // Drain the stream until completion, feeding bridged events into
        // the per-job event channel so the UI gets live updates.
        let jobId = UUID()
        let bridge = FluxJobBridge(jobId: jobId)
        registerFluxJob(bridge)

        var finalURL: URL? = nil
        var seedReturned: UInt64 = 0
        do {
            for try await evt in await flux.generate(request) {
                bridge.yield(bridgeEvent(evt))
                if case .completed(let url, let seed) = evt {
                    finalURL = url
                    seedReturned = seed
                }
                if case .failed(let msg, _) = evt {
                    throw EngineError.notImplemented("FluxBackend: \(msg)")
                }
            }
        } catch {
            bridge.finish(throwing: error)
            unregisterFluxJob(jobId)
            throw error
        }
        bridge.finish()
        unregisterFluxJob(jobId)
        _ = seedReturned
        guard let url = finalURL else {
            throw EngineError.notImplemented("FluxBackend — no output URL")
        }
        return url
    }

    /// Run an image edit end-to-end. Mirrors `generateImage` but dispatches
    /// through `FluxEngine.edit` which routes to whichever concrete editor
    /// the loaded model exposes (`Flux1Fill`, `Flux2KleinEdit`, `QwenImageEdit`).
    ///
    /// Writes `source` and optional `mask` to PNGs under a scratch directory,
    /// builds an `ImageEditRequest`, drains the bridge stream, and returns
    /// the final output URL. Progress events are fed into `fluxJobs` under
    /// the returned job id — callers can subscribe via `imageGenStream`.
    public func editImage(
        prompt: String,
        model: String,
        source: Data,
        mask: Data?,
        strength: Double,
        settings: ImageGenSettings
    ) async throws -> URL {
        try MetalRuntimePreflight.validateForImageGeneration()
        let flux = getOrCreateFluxBackend()
        let libraryEntries = await self.modelLibrary.entries()
        let libraryEntry = imageLibraryEntry(for: model, in: libraryEntries)
        try ImageGenerationSafety.validate(
            settings: settings,
            modelStorageBytes: libraryEntry?.totalSizeBytes
        )
        let requestedRegistryName = canonicalFluxRegistryName(for: model, entry: libraryEntry)

        // Ensure the requested model is loaded — same pattern as generateImage.
        let lastName = await flux.lastLoadedName
        if lastName != requestedRegistryName {
            guard let libraryEntry else {
                throw EngineError.notImplemented(
                    "FluxBackend.editImage — no model entry for '\(model)'. "
                    + "Stage it via DownloadManager first."
                )
            }
            let registryName = canonicalFluxRegistryName(for: model, entry: libraryEntry)
            try await flux.load(
                name: registryName,
                modelPath: libraryEntry.canonicalPath,
                quantize: nil
            )
            self.lastImageModelPath = libraryEntry.canonicalPath
        }
        if let libraryEntry {
            self.lastImageModelPath = libraryEntry.canonicalPath
        }

        // Scratch dir for source/mask inputs. Final images go to the durable
        // generated-images directory so Library records remain valid.
        let outputDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmlx-flux-out", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: outputDir, withIntermediateDirectories: true)

        // Dump inputs to disk — vmlx-flux editors take URL handles so they
        // can memory-map / reopen on the model actor. Use random filenames
        // so concurrent edits don't race on the same path.
        let stem = UUID().uuidString.prefix(8)
        let sourceURL = outputDir.appendingPathComponent("src-\(stem).png")
        try source.write(to: sourceURL, options: .atomic)

        var maskURL: URL? = nil
        if let mask {
            let u = outputDir.appendingPathComponent("mask-\(stem).png")
            try mask.write(to: u, options: .atomic)
            maskURL = u
        }

        let seed: UInt64? = settings.seed >= 0
            ? UInt64(bitPattern: Int64(settings.seed))
            : nil

        let request = vMLXFlux.ImageEditRequest(
            prompt: prompt,
            sourceImage: sourceURL,
            mask: maskURL,
            strength: Float(strength),
            width: settings.width > 0 ? settings.width : nil,
            height: settings.height > 0 ? settings.height : nil,
            steps: settings.steps,
            guidance: Float(settings.guidance),
            seed: seed,
            outputDir: try Self.generatedImagesDirectory()
        )

        // Drain the edit stream, feeding events into the per-job bridge
        // so the UI gets live updates. Symmetric to generateImage.
        let jobId = UUID()
        let bridge = FluxJobBridge(jobId: jobId)
        registerFluxJob(bridge)

        var finalURL: URL? = nil
        do {
            for try await evt in await flux.edit(request) {
                bridge.yield(bridgeEvent(evt))
                if case .completed(let url, _) = evt {
                    finalURL = url
                }
                if case .failed(let msg, _) = evt {
                    throw EngineError.notImplemented("FluxBackend.editImage: \(msg)")
                }
            }
        } catch {
            bridge.finish(throwing: error)
            unregisterFluxJob(jobId)
            try? FileManager.default.removeItem(at: sourceURL)
            if let maskURL { try? FileManager.default.removeItem(at: maskURL) }
            throw error
        }
        bridge.finish()
        unregisterFluxJob(jobId)

        // Best-effort cleanup of the temporary inputs. The output PNG
        // lives under the same `outputDir` and is the caller's return value.
        try? FileManager.default.removeItem(at: sourceURL)
        if let maskURL { try? FileManager.default.removeItem(at: maskURL) }

        guard let url = finalURL else {
            throw EngineError.notImplemented("FluxBackend.editImage — no output URL")
        }
        return url
    }

    private func canonicalFluxRegistryName(
        for requestedModel: String,
        entry: ModelLibrary.ModelEntry? = nil
    ) -> String {
        let candidates = [
            requestedModel,
            entry?.displayName,
            entry?.canonicalPath.lastPathComponent,
            entry?.canonicalPath.deletingLastPathComponent().lastPathComponent,
            entry?.canonicalPath.deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent,
        ].compactMap { $0 }

        for candidate in candidates {
            if let match = vMLXFluxKit.ModelRegistry.lookupFuzzy(name: candidate) {
                return match.name
            }
        }

        let comparable = imageComparableName(requestedModel)
        if comparable.contains("z-image") && comparable.contains("turbo") {
            return "z-image-turbo"
        }
        if comparable.contains("krea-2") || comparable.contains("krea2") {
            return "krea-2-turbo"
        }
        if comparable.contains("krea") {
            return "flux-krea-dev"
        }
        if comparable.contains("qwen-image") || comparable.contains("qwen/image") {
            return "qwen-image"
        }
        if comparable.contains("flux2") || comparable.contains("flux-2") || comparable.contains("klein") {
            return "flux2-klein"
        }
        if comparable.contains("flux1-dev") || comparable.contains("flux-1-dev") {
            return "flux1-dev"
        }
        if comparable.contains("flux1-schnell") || comparable.contains("flux-1-schnell") {
            return "flux1-schnell"
        }
        return requestedModel.lowercased()
    }

    private static func uniqueImageModelCandidatePaths(_ paths: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []
        for path in paths {
            let standardized = path.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { continue }
            result.append(standardized)
        }
        return result
    }

    private static func fallbackImageModelCandidatePaths(runtimeName: String) -> [URL] {
        guard runtimeName == "krea-2-turbo" else { return [] }
        let snapshots = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".cache/huggingface/hub/models--krea--Krea-2-Turbo/snapshots",
                isDirectory: true
            )
        var candidates = [
            snapshots.appendingPathComponent("main", isDirectory: true),
        ]
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: snapshots,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            candidates.append(contentsOf: contents.filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            })
        }
        return uniqueImageModelCandidatePaths(candidates)
    }

    private func canonicalFluxRegistryName(forModelPath modelPath: URL) -> String {
        let candidates = [
            modelPath.lastPathComponent,
            modelPath.deletingLastPathComponent().lastPathComponent,
            modelPath.deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent,
            modelPath.path,
        ]

        for candidate in candidates {
            if let match = vMLXFluxKit.ModelRegistry.lookupFuzzy(name: candidate) {
                return match.name
            }
        }

        for candidate in candidates {
            let comparable = imageComparableName(candidate)
            if comparable.contains("z-image") && comparable.contains("turbo") {
                return "z-image-turbo"
            }
            if comparable.contains("krea-2") || comparable.contains("krea2") {
                return "krea-2-turbo"
            }
            if comparable.contains("krea") {
                return "flux-krea-dev"
            }
            if comparable.contains("qwen-image") || comparable.contains("qwen/image") {
                return "qwen-image"
            }
            if comparable.contains("flux2") || comparable.contains("flux-2") || comparable.contains("klein") {
                return "flux2-klein"
            }
            if comparable.contains("flux1-dev") || comparable.contains("flux-1-dev") {
                return "flux1-dev"
            }
            if comparable.contains("flux1-schnell") || comparable.contains("flux-1-schnell") {
                return "flux1-schnell"
            }
        }

        return modelPath.lastPathComponent.lowercased()
    }

    private func imageLibraryEntry(
        for requestedModel: String,
        in entries: [ModelLibrary.ModelEntry]
    ) -> ModelLibrary.ModelEntry? {
        let requested = imageComparableName(requestedModel)
        let requestedRegistry = vMLXFluxKit.ModelRegistry.lookupFuzzy(name: requestedModel)?.name
            ?? canonicalFluxRegistryName(for: requestedModel)

        return entries.first { entry in
            guard entry.modality == .image
                    || entry.family.lowercased().contains("flux")
                    || entry.family.lowercased().contains("krea")
                    || entry.displayName.lowercased().contains("flux")
                    || entry.displayName.lowercased().contains("krea")
                    || entry.displayName.lowercased().contains("z-image")
                    || entry.displayName.lowercased().contains("qwen-image")
                    || entry.canonicalPath.path.lowercased().contains("flux")
                    || entry.canonicalPath.path.lowercased().contains("krea")
                    || entry.canonicalPath.path.lowercased().contains("z-image")
                    || entry.canonicalPath.path.lowercased().contains("qwen-image")
            else { return false }

            let candidates = [
                entry.id,
                entry.displayName,
                entry.canonicalPath.path,
                entry.canonicalPath.lastPathComponent,
                entry.canonicalPath.deletingLastPathComponent().lastPathComponent,
                entry.canonicalPath.deletingLastPathComponent()
                    .deletingLastPathComponent().lastPathComponent,
            ]

            for candidate in candidates {
                let comparable = imageComparableName(candidate)
                if comparable == requested || comparable.contains(requested) || requested.contains(comparable) {
                    return true
                }
                if let fuzzy = vMLXFluxKit.ModelRegistry.lookupFuzzy(name: candidate),
                   fuzzy.name == requestedRegistry {
                    return true
                }
                if requestedRegistry == "flux1-schnell",
                   comparable.contains("flux1-schnell") || comparable.contains("flux-1-schnell") {
                    return true
                }
                if requestedRegistry == "z-image-turbo",
                   comparable.contains("z-image") && comparable.contains("turbo") {
                    return true
                }
                if requestedRegistry == "krea-2-turbo",
                   comparable.contains("krea-2") || comparable.contains("krea2") {
                    return true
                }
                if requestedRegistry == "flux-krea-dev",
                   comparable.contains("krea") {
                    return true
                }
                if requestedRegistry == "qwen-image",
                   comparable.contains("qwen-image") || comparable.contains("qwen/image") {
                    return true
                }
            }
            return false
        }
    }

    private func imageComparableName(_ value: String) -> String {
        value.lowercased()
            .replacingOccurrences(of: "models--", with: "")
            .replacingOccurrences(of: "--", with: "/")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
    }

    /// Subscribe to progress events for a specific job.
    public nonisolated func imageGenStream(
        jobId: UUID
    ) -> AsyncThrowingStream<ImageGenEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else { continuation.finish(); return }
                guard let bridge = await self.fluxJobs[jobId] else {
                    continuation.finish()
                    return
                }
                for await e in bridge.subscribe() {
                    continuation.yield(e)
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Job registry helpers

    private func registerFluxJob(_ bridge: FluxJobBridge) {
        fluxJobs[bridge.jobId] = bridge
    }

    private func unregisterFluxJob(_ id: UUID) {
        fluxJobs[id] = nil
    }

    /// Convert a vmlx-flux ImageGenEvent to the vMLXEngine ImageGenEvent
    /// the app layer already knows about. Note: the two enums have
    /// overlapping names but different shapes — vMLXEngine's `.step` bundles
    /// the preview into the same case while vmlx-flux has a separate
    /// `.preview` case. We merge them here.
    private nonisolated func bridgeEvent(_ e: vMLXFlux.ImageGenEvent) -> ImageGenEvent {
        switch e {
        case .step(let step, let total, _):
            return .step(step: step, total: total, preview: nil)
        case .preview(let data, let step):
            // Surface as a step event with preview bytes; total unknown here
            // so use step for both. The UI re-derives progress from its own
            // counter between bridge events.
            return .step(step: step, total: step, preview: data)
        case .completed(let url, _):
            return .completed(url: url)
        case .failed(let msg, let hfAuth):
            return .failed(message: msg, hfAuth: hfAuth)
        case .cancelled:
            return .cancelled
        }
    }
}

// MARK: - FluxJobBridge
//
// Per-job fan-out. A single `FluxEngine.generate()` stream feeds here,
// and any number of UI subscribers tee off via `subscribe()`. When the
// job finishes, all subscriptions finish too.

final class FluxJobBridge: @unchecked Sendable {
    let jobId: UUID
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<ImageGenEvent>.Continuation] = [:]
    private var finished = false
    private var terminalError: Error?

    init(jobId: UUID) {
        self.jobId = jobId
    }

    func subscribe() -> AsyncStream<ImageGenEvent> {
        AsyncStream { cont in
            lock.lock()
            let id = UUID()
            if finished {
                cont.finish()
                lock.unlock()
                return
            }
            continuations[id] = cont
            lock.unlock()
            cont.onTermination = { [weak self] _ in
                self?.lock.lock()
                self?.continuations[id] = nil
                self?.lock.unlock()
            }
        }
    }

    func yield(_ event: ImageGenEvent) {
        lock.lock()
        let conts = continuations
        lock.unlock()
        for (_, c) in conts { c.yield(event) }
    }

    func finish(throwing error: Error? = nil) {
        lock.lock()
        finished = true
        terminalError = error
        let conts = continuations
        continuations.removeAll()
        lock.unlock()
        for (_, c) in conts { c.finish() }
    }
}
