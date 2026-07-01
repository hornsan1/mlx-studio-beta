import Foundation
import vMLXLLM
import vMLXVLM

/// HuggingFace Hub model search (§250).
///
/// Wraps `huggingface.co/api/models` so the Downloads window can show a
/// search UI instead of forcing users to type `org/repo` by hand. Purely
/// additive — the existing "add by URL" paste flow keeps working.
///
/// The hub API returns a flat list of models matching a `search` term,
/// optionally filtered by tags (e.g. `mlx`, `safetensors`, `quantized`)
/// and sorted by `downloads` or `likes`. We expose a small typed result
/// so the UI can render a table without re-parsing free-form JSON.
///
/// Auth: when a token is configured in `HuggingFaceAuth`, it's forwarded
/// so gated + private repos show up for authenticated users. Without a
/// token the call still works for public models.
///
/// Rate limits: HF's public API throttles unauthenticated traffic at
/// ~100 req/min per IP. We surface `.rateLimited` as a distinct error
/// so the caller can show a 60s backoff banner instead of a generic
/// "search failed".
public enum HuggingFaceSearchError: Error, LocalizedError {
    case badURL
    case network(String)
    case badStatus(Int)
    case decodeFailed(String)
    case rateLimited

    public var errorDescription: String? {
        switch self {
        case .badURL: return "Invalid search query"
        case .network(let m): return "Network error: \(m)"
        case .badStatus(let c): return "HuggingFace API returned \(c)"
        case .decodeFailed(let m): return "Failed to parse response: \(m)"
        case .rateLimited: return "Rate-limited by HuggingFace — retry in a minute"
        }
    }
}

/// A single result row suitable for a picker. All fields are optional
/// where HF's API can return null.
public struct HuggingFaceSearchResult: Sendable, Hashable, Identifiable {
    public var id: String { modelId }
    /// Full `org/repo` identifier — the handle the DownloadManager wants.
    public let modelId: String
    /// Total download count (lifetime). Used for sorting.
    public let downloads: Int
    public let likes: Int
    public let lastModified: Date?
    /// Tag list (e.g. `["mlx", "safetensors", "4-bit"]`) for quick
    /// family / format badges in the UI.
    public let tags: [String]
    /// Whether the repo is marked gated. Surfaces a "Request access"
    /// CTA before attempting a download — otherwise the first shard
    /// download would fail with 401 and leave a half-downloaded dir.
    public let gated: Bool
    /// Pipeline tag (e.g. `text-generation`, `image-to-image`).
    public let pipeline: String?
    /// Hub library name when present. MLX-converted repos usually report
    /// `mlx`; JANG repos may only expose format via tags or files.
    public let libraryName: String?
    /// Runtime-resolved model type. For VLM wrappers this prefers
    /// `text_config.model_type`, matching the vMLX load path.
    public let resolvedModelType: String?
    /// Total known model storage from the Hub response.
    public let usedStorageBytes: Int64?
    /// Sum of safetensors sibling sizes when available.
    public let weightBytes: Int64?
    /// vMLX runtime compatibility verdict for this repo.
    public let runtimeCompatibility: HuggingFaceRuntimeCompatibility
}

public struct HuggingFaceRuntimeCompatibility: Sendable, Hashable {
    public enum Format: String, Sendable, Hashable {
        case mlx = "MLX"
        case jang = "JANG"
        case transformers = "HF"
    }

    public let isCompatible: Bool
    public let format: Format?
    public let modelType: String?
    public let modality: ModelCapabilities.Modality
    public let reason: String

    public static func supportedModelTypes() async -> Set<String> {
        let llm = await Set(LLMTypeRegistry.shared.registeredModelTypes().map { $0.lowercased() })
        let vlm = Set(VLMTypeRegistry.supportedModelTypes.map { $0.lowercased() })
        return llm.union(vlm).subtracting(Self.knownNonNativeModelTypes)
    }

    public static func evaluate(
        modelId: String,
        tags: [String],
        pipeline: String?,
        libraryName: String?,
        config: [String: Any],
        siblingFilenames: [String],
        supportedModelTypes: Set<String>
    ) -> HuggingFaceRuntimeCompatibility {
        let lowerTags = tags.map { $0.lowercased() }
        let lowerFiles = siblingFilenames.map { $0.lowercased() }
        let modelType = resolveModelType(
            config: config,
            tags: lowerTags,
            supportedModelTypes: supportedModelTypes
        )?.lowercased()
        let format = resolveFormat(
            modelId: modelId,
            tags: lowerTags,
            libraryName: libraryName,
            config: config,
            siblingFilenames: lowerFiles
        )
        var modality = resolveModality(
            pipeline: pipeline,
            modelType: modelType,
            config: config,
            isJANG: format == .jang
        )
        if modality == .text,
           (lowerTags.contains("image-generation")
            || lowerTags.contains("text-to-image")
            || lowerTags.contains("image-to-image")
            || looksLikeDiffusionComponentLayout(siblingFilenames: lowerFiles)) {
            modality = .image
        }

        guard let format else {
            return .init(
                isCompatible: false,
                format: nil,
                modelType: modelType,
                modality: modality,
                reason: "Repo is not tagged or packaged as MLX/JANG/HF"
            )
        }

        if modality == .image {
            return evaluateImageRuntime(
                modelId: modelId,
                tags: lowerTags,
                libraryName: libraryName,
                pipeline: pipeline,
                config: config,
                siblingFilenames: lowerFiles,
                format: format
            )
        }

        guard hasRequiredTextRuntimeFiles(siblingFilenames: lowerFiles) else {
            return .init(
                isCompatible: false,
                format: format,
                modelType: modelType,
                modality: modality,
                reason: "Missing config, safetensors, or tokenizer files"
            )
        }

        guard modality == .text || modality == .vision else {
            return .init(
                isCompatible: false,
                format: format,
                modelType: modelType,
                modality: modality,
                reason: "MLX Studio beta only exposes text and vision model loading"
            )
        }

        guard let modelType, supportedModelTypes.contains(modelType) else {
            let unsupportedType = modelType ?? "unknown"
            return .init(
                isCompatible: false,
                format: format,
                modelType: modelType,
                modality: modality,
                reason: modelType == nil
                    ? "Hub metadata does not expose model_type"
                    : "model_type \(unsupportedType) is not loadable by this vMLX runtime"
            )
        }

        if format == .jang, Self.jangFormatExclusions.contains(modelType) {
            return .init(
                isCompatible: false,
                format: format,
                modelType: modelType,
                modality: modality,
                reason: "JANG format for \(modelType) is not wired in the Swift runtime yet"
            )
        }

        return .init(
            isCompatible: true,
            format: format,
            modelType: modelType,
            modality: modality,
            reason: "\(format.rawValue) \(modelType) is supported by vMLX"
        )
    }

    private static func evaluateImageRuntime(
        modelId: String,
        tags: [String],
        libraryName: String?,
        pipeline: String?,
        config: [String: Any],
        siblingFilenames: [String],
        format: Format
    ) -> HuggingFaceRuntimeCompatibility {
        guard format == .mlx else {
            return .init(
                isCompatible: false,
                format: format,
                modelType: nil,
                modality: .image,
                reason: "Only MLX image pipelines are wired in the Swift runtime yet"
            )
        }

        guard let runtimeName = resolveImageRuntimeName(
            modelId: modelId,
            tags: tags,
            libraryName: libraryName,
            pipeline: pipeline,
            config: config,
            siblingFilenames: siblingFilenames
        ) else {
            return .init(
                isCompatible: false,
                format: format,
                modelType: nil,
                modality: .image,
                reason: "Image repo does not match a vMLX Flux runtime"
            )
        }

        if runtimeName == "qwen-image" {
            return .init(
                isCompatible: false,
                format: format,
                modelType: runtimeName,
                modality: .image,
                reason: "Qwen-Image is scaffolded in this beta, but not prompt-proven by the vMLX image runtime yet"
            )
        }

        guard supportedImageRuntimeNames.contains(runtimeName) else {
            return .init(
                isCompatible: false,
                format: format,
                modelType: runtimeName,
                modality: .image,
                reason: "Image runtime \(runtimeName) is not enabled in this vMLX build"
            )
        }

        guard hasRequiredImageRuntimeFiles(siblingFilenames: siblingFilenames) else {
            return .init(
                isCompatible: false,
                format: format,
                modelType: runtimeName,
                modality: .image,
                reason: "Missing Flux component weights, VAE, or tokenizer files"
            )
        }

        return .init(
            isCompatible: true,
            format: format,
            modelType: runtimeName,
            modality: .image,
            reason: "\(format.rawValue) \(runtimeName) image pipeline is supported by the MLX Studio image backend"
        )
    }

    private static let knownNonNativeModelTypes: Set<String> = [
        "laguna",
        "ministral3",
    ]

    private static let jangFormatExclusions: Set<String> = [
        "nemotron_h",
    ]

    private static let supportedImageRuntimeNames: Set<String> = [
        "flux1-schnell",
        "flux1-dev",
        "flux2-klein",
        "z-image-turbo",
    ]

    private static func resolveModelType(
        config: [String: Any],
        tags: [String],
        supportedModelTypes: Set<String>
    ) -> String? {
        if let text = config["text_config"] as? [String: Any],
           let modelType = text["model_type"] as? String,
           !modelType.isEmpty {
            return modelType
        }
        if let modelType = config["model_type"] as? String,
           !modelType.isEmpty {
            return modelType
        }
        return tags.first { tag in
            supportedModelTypes.contains(tag.lowercased())
        }
    }

    private static func resolveFormat(
        modelId: String,
        tags: [String],
        libraryName: String?,
        config: [String: Any],
        siblingFilenames: [String]
    ) -> Format? {
        let lowerId = modelId.lowercased()
        let lowerLibrary = libraryName?.lowercased()
        let isJANG = lowerId.contains("jang")
            || tags.contains(where: { tag in
                tag == "jang" || tag == "jangtq" || tag == "mxtq" || tag.contains("turboquant")
            })
            || siblingFilenames.contains("jang_config.json")
            || config["jang_config"] != nil
            || config["jang"] != nil
            || weightFormatIsMXTQ(config)
        if isJANG { return .jang }

        let isMLX = lowerLibrary == "mlx"
            || tags.contains("mlx")
            || lowerId.hasPrefix("mlx-community/")
        if isMLX { return .mlx }

        let isNativeHF = lowerLibrary == "transformers"
            || tags.contains("transformers")
        return isNativeHF ? .transformers : nil
    }

    private static func resolveModality(
        pipeline: String?,
        modelType: String?,
        config: [String: Any],
        isJANG: Bool
    ) -> ModelCapabilities.Modality {
        if let pipeline {
            switch pipeline {
            case "image-text-to-text", "visual-question-answering":
                return .vision
            case "text-generation", "conversational":
                return .text
            case "feature-extraction", "sentence-similarity":
                return .embedding
            case "text-to-image", "image-to-image":
                return .image
            default:
                break
            }
        }
        if isJANG,
           let architecture = config["architecture"] as? [String: Any],
           let hasVision = architecture["has_vision"] as? Bool {
            return hasVision ? .vision : .text
        }
        if config["vision_config"] != nil || config["text_config"] != nil {
            return .vision
        }
        if let modelType {
            if let entry = ModelTypeTable.lookup(modelType: modelType), entry.isMLLM {
                return .vision
            }
            if modelType.contains("embed") || modelType == "bert" || modelType == "xlm-roberta" {
                return .embedding
            }
            if modelType.contains("rerank") {
                return .rerank
            }
        }
        return .text
    }

    private static func hasRequiredTextRuntimeFiles(siblingFilenames: [String]) -> Bool {
        let hasConfig = siblingFilenames.contains("config.json")
        let hasWeights = siblingFilenames.contains { $0.hasSuffix(".safetensors") }
        let hasTokenizer = siblingFilenames.contains("tokenizer.json")
            || siblingFilenames.contains("tokenizer.model")
        return hasConfig && hasWeights && hasTokenizer
    }

    private static func hasRequiredImageRuntimeFiles(siblingFilenames: [String]) -> Bool {
        let hasWeights = siblingFilenames.contains { $0.hasSuffix(".safetensors") }
        let hasTransformer = siblingFilenames.contains { file in
            file.hasPrefix("transformer/") && file.hasSuffix(".safetensors")
        } || siblingFilenames.contains { file in
            file.contains("flux") && file.hasSuffix(".safetensors")
        }
        let hasVAE = siblingFilenames.contains { file in
            file.hasPrefix("vae/") && file.hasSuffix(".safetensors")
        } || siblingFilenames.contains { file in
            file == "ae.safetensors" || file.contains("vae")
        }
        let hasTokenizer = siblingFilenames.contains { file in
            file.hasPrefix("tokenizer/") || file.hasPrefix("tokenizer_2/")
        }
        return hasWeights && hasTransformer && hasVAE && hasTokenizer
    }

    private static func looksLikeDiffusionComponentLayout(siblingFilenames: [String]) -> Bool {
        let hasTransformer = siblingFilenames.contains { $0.hasPrefix("transformer/") }
        let hasVAE = siblingFilenames.contains { $0.hasPrefix("vae/") || $0 == "ae.safetensors" }
        let hasTokenizer = siblingFilenames.contains { $0.hasPrefix("tokenizer/") || $0.hasPrefix("tokenizer_2/") }
        return hasTransformer && hasVAE && hasTokenizer
    }

    private static func resolveImageRuntimeName(
        modelId: String,
        tags: [String],
        libraryName: String?,
        pipeline: String?,
        config: [String: Any],
        siblingFilenames: [String]
    ) -> String? {
        var evidence = [modelId, libraryName, pipeline].compactMap { $0?.lowercased() }
        evidence.append(contentsOf: tags.map { $0.lowercased() })
        evidence.append(contentsOf: siblingFilenames.map { $0.lowercased() })
        if let base = config["_name_or_path"] as? String {
            evidence.append(base.lowercased())
        }
        if let architectures = config["architectures"] as? [String] {
            evidence.append(contentsOf: architectures.map { $0.lowercased() })
        }
        let text = evidence.joined(separator: " ")

        if text.contains("z-image") && text.contains("turbo") {
            return "z-image-turbo"
        }
        if text.contains("qwen-image") || text.contains("qwen image") {
            return "qwen-image"
        }
        if text.contains("flux.2") || text.contains("flux2") || text.contains("klein") {
            return "flux2-klein"
        }
        if text.contains("flux.1-dev") || text.contains("flux1-dev") || text.contains("flux1.dev") {
            return "flux1-dev"
        }
        if text.contains("flux.1-schnell")
            || text.contains("flux1-schnell")
            || text.contains("flux1.schnell")
            || (text.contains("flux") && text.contains("schnell")) {
            return "flux1-schnell"
        }
        return nil
    }

    private static func weightFormatIsMXTQ(_ config: [String: Any]) -> Bool {
        if let value = config["weight_format"] as? String,
           value.lowercased() == "mxtq" {
            return true
        }
        if let text = config["text_config"] as? [String: Any],
           let value = text["weight_format"] as? String,
           value.lowercased() == "mxtq" {
            return true
        }
        if let quant = config["quantization"] as? [String: Any],
           let method = quant["method"] as? String,
           method.lowercased().contains("mxtq") {
            return true
        }
        return false
    }
}

public struct HuggingFaceSearch {
    /// `session` is injectable for tests; defaults to the shared URL session.
    public let session: URLSession
    /// Optional HF token; pass nil for unauthenticated calls.
    public let token: String?

    public init(session: URLSession = .shared, token: String? = nil) {
        self.session = session
        self.token = token
    }

    /// Search the HF Hub. Caps at 50 results to keep payloads small; UI
    /// should paginate by refining the query rather than scrolling.
    ///
    /// - Parameters:
    ///   - query: free-text search. Empty string returns popular models.
    ///   - filters: repo-level filters (e.g. `["mlx"]`, `["text-to-image"]`).
    ///   - sort: `downloads` (default), `likes`, `modified`, `created`.
    ///   - limit: clamped to [1, 50].
    public func search(
        query: String,
        filters: [String] = [],
        sort: String = "downloads",
        limit: Int = 30
    ) async throws -> [HuggingFaceSearchResult] {
        var comps = URLComponents(string: "https://huggingface.co/api/models")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "sort", value: sort),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 50)))),
            // `full=true` asks HF to include the siblings/gated/tags
            // fields we need. Without it the response is a bare row.
            URLQueryItem(name: "full", value: "true"),
        ]
        for f in filters where !f.isEmpty {
            items.append(URLQueryItem(name: "filter", value: f))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw HuggingFaceSearchError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        if let token, !token.isEmpty {
            req.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw HuggingFaceSearchError.network(error.localizedDescription)
        }

        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw HuggingFaceSearchError.rateLimited }
        guard (200..<300).contains(status) else {
            throw HuggingFaceSearchError.badStatus(status)
        }

        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            let snippet = String(data: data.prefix(160), encoding: .utf8) ?? ""
            throw HuggingFaceSearchError.decodeFailed(snippet)
        }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let supportedModelTypes = await HuggingFaceRuntimeCompatibility.supportedModelTypes()
        var out: [HuggingFaceSearchResult] = []
        out.reserveCapacity(rows.count)
        for row in rows {
            if let result = Self.parseResult(
                row,
                supportedModelTypes: supportedModelTypes,
                dateFormatter: fmt
            ) {
                out.append(result)
            }
        }
        return out
    }

    /// Fetch a single model's full Hub metadata. Search rows omit byte
    /// sizes for siblings, but the detail endpoint includes `usedStorage`
    /// and per-file `size` values that the selector can surface.
    public func modelDetails(modelId: String) async throws -> HuggingFaceSearchResult? {
        let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw HuggingFaceSearchError.badURL }

        var comps = URLComponents()
        comps.scheme = "https"
        comps.host = "huggingface.co"
        comps.path = "/api/models/\(trimmed)"
        comps.queryItems = [
            URLQueryItem(name: "blobs", value: "false"),
        ]
        guard let url = comps.url else { throw HuggingFaceSearchError.badURL }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        if let token, !token.isEmpty {
            req.addValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let resp: URLResponse
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw HuggingFaceSearchError.network(error.localizedDescription)
        }

        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 { throw HuggingFaceSearchError.rateLimited }
        guard (200..<300).contains(status) else {
            throw HuggingFaceSearchError.badStatus(status)
        }

        guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            let snippet = String(data: data.prefix(160), encoding: .utf8) ?? ""
            throw HuggingFaceSearchError.decodeFailed(snippet)
        }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let supportedModelTypes = await HuggingFaceRuntimeCompatibility.supportedModelTypes()
        return Self.parseResult(
            row,
            supportedModelTypes: supportedModelTypes,
            dateFormatter: fmt
        )
    }

    /// Search Hugging Face for models this build can load directly through
    /// the vMLX runtime. Uses multiple Hub queries because MLX and JANG
    /// models are not tagged consistently across publishers.
    public func searchRuntimeCompatible(
        query: String,
        sort: String = "downloads",
        limit: Int = 30
    ) async throws -> [HuggingFaceSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var buckets: [[HuggingFaceSearchResult]] = []
        buckets.append(try await search(query: trimmed, filters: [], sort: sort, limit: limit))
        buckets.append(try await search(query: trimmed, filters: ["mlx"], sort: sort, limit: limit))
        buckets.append(try await search(query: "\(trimmed) JANG", filters: [], sort: sort, limit: limit))
        buckets.append(try await search(query: "\(trimmed) MXTQ", filters: [], sort: sort, limit: limit))

        var seen = Set<String>()
        var merged: [HuggingFaceSearchResult] = []
        for row in buckets.flatMap({ $0 }) where row.runtimeCompatibility.isCompatible {
            if seen.insert(row.modelId).inserted {
                merged.append(row)
            }
        }
        let ranked = Array(merged.sorted { lhs, rhs in
            if lhs.downloads != rhs.downloads { return lhs.downloads > rhs.downloads }
            return lhs.modelId.localizedCaseInsensitiveCompare(rhs.modelId) == .orderedAscending
        }.prefix(max(1, min(limit, 50))))

        var hydrated: [HuggingFaceSearchResult] = []
        hydrated.reserveCapacity(ranked.count)
        for row in ranked {
            if let detail = try? await modelDetails(modelId: row.modelId),
               detail.runtimeCompatibility.isCompatible {
                hydrated.append(detail)
            } else {
                hydrated.append(row)
            }
        }
        return hydrated
    }

    /// HF returns `gated` as either the literal bool `false` or the string
    /// `"auto"` / `"manual"`. Normalize to a single bool.
    private static func parseGated(_ raw: Any?) -> Bool {
        if let b = raw as? Bool { return b }
        if let s = raw as? String { return s != "false" }
        return false
    }

    private static func resolveModelType(
        _ config: [String: Any],
        tags: [String],
        supportedModelTypes: Set<String>
    ) -> String? {
        if let text = config["text_config"] as? [String: Any],
           let modelType = text["model_type"] as? String,
           !modelType.isEmpty {
            return modelType
        }
        if let modelType = config["model_type"] as? String,
           !modelType.isEmpty {
            return modelType
        }
        return tags
            .map { $0.lowercased() }
            .first { supportedModelTypes.contains($0) }
    }

    private static func parseResult(
        _ row: [String: Any],
        supportedModelTypes: Set<String>,
        dateFormatter: ISO8601DateFormatter
    ) -> HuggingFaceSearchResult? {
        guard let id = row["modelId"] as? String ?? row["id"] as? String else { return nil }
        let downloads = (row["downloads"] as? Int) ?? 0
        let likes = (row["likes"] as? Int) ?? 0
        let tags = (row["tags"] as? [String]) ?? []
        let gated = Self.parseGated(row["gated"])
        let pipeline = row["pipeline_tag"] as? String
        let libraryName = row["library_name"] as? String
        let config = row["config"] as? [String: Any] ?? [:]
        let siblings = row["siblings"] as? [[String: Any]] ?? []
        let siblingFilenames = siblings.compactMap { $0["rfilename"] as? String }
        let weightBytes = siblings.reduce(Int64(0)) { total, sibling in
            guard let filename = sibling["rfilename"] as? String,
                  filename.lowercased().hasSuffix(".safetensors")
            else { return total }
            return total + Self.int64(sibling["size"])
        }
        let resolvedModelType = Self.resolveModelType(
            config,
            tags: tags,
            supportedModelTypes: supportedModelTypes
        )
        let compatibility = HuggingFaceRuntimeCompatibility.evaluate(
            modelId: id,
            tags: tags,
            pipeline: pipeline,
            libraryName: libraryName,
            config: config,
            siblingFilenames: siblingFilenames,
            supportedModelTypes: supportedModelTypes
        )
        var lastMod: Date?
        if let s = row["lastModified"] as? String {
            lastMod = dateFormatter.date(from: s)
                ?? ISO8601DateFormatter().date(from: s)
        }
        return HuggingFaceSearchResult(
            modelId: id,
            downloads: downloads,
            likes: likes,
            lastModified: lastMod,
            tags: tags,
            gated: gated,
            pipeline: pipeline,
            libraryName: libraryName,
            resolvedModelType: resolvedModelType,
            usedStorageBytes: Self.optionalInt64(row["usedStorage"]),
            weightBytes: weightBytes > 0 ? weightBytes : nil,
            runtimeCompatibility: compatibility
        )
    }

    private static func optionalInt64(_ raw: Any?) -> Int64? {
        let value = int64(raw)
        return value > 0 ? value : nil
    }

    private static func int64(_ raw: Any?) -> Int64 {
        if let n = raw as? Int64 { return n }
        if let n = raw as? Int { return Int64(n) }
        if let n = raw as? Double { return Int64(n) }
        if let n = raw as? NSNumber { return n.int64Value }
        return 0
    }
}
