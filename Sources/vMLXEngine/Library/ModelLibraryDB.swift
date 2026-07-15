import Foundation
import MLXStudioDomain
import MLXStudioPersistence

/// Persistent store for `ModelLibrary`. Backed by its own SQLite file at
/// `~/Library/Application Support/vMLX/models.sqlite3` — deliberately split
/// from the chat/sessions DB (`vmlx.sqlite3`) so schema migrations evolve
/// independently and a corrupt index here can't nuke chat history.
///
/// Thread-safety: the class itself is not actor-isolated, but all callers
/// currently funnel through the `ModelLibrary` actor so access is serialized.
/// Connection is opened with `SQLITE_OPEN_FULLMUTEX` for defence in depth.
public final class ModelLibraryDB: @unchecked Sendable {

    private let repository: ModelArtifactRepository?
    public private(set) var migrationErrorDescription: String?
    public var durableJobRepository: DurableJobRepository? {
        repository?.makeJobRepository()
    }

    public init(customPath: URL? = nil) {
        let fm = FileManager.default
        let url: URL
        if let customPath {
            url = customPath
        } else {
            let appSup = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                     appropriateFor: nil, create: true)
            let dir = (appSup ?? URL(fileURLWithPath: NSTemporaryDirectory()))
                .appendingPathComponent("vMLX", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            url = dir.appendingPathComponent("models.sqlite3")
        }
        do {
            self.repository = try ModelArtifactRepository(databaseURL: url)
        } catch {
            self.repository = nil
            self.migrationErrorDescription = String(describing: error)
            NSLog("vMLX ModelLibraryDB migration failed: \(error)")
        }
    }

    // MARK: - Models CRUD

    public func upsert(_ e: ModelLibrary.ModelEntry) {
        do {
            try repository?.upsertIndexedModel(IndexedModelRecord(
                legacyModelID: e.id,
                canonicalURL: e.canonicalPath,
                displayName: e.displayName,
                family: e.family,
                modality: e.modality.rawValue,
                totalSizeBytes: e.totalSizeBytes,
                isJANG: e.isJANG,
                isJANGTQ: e.isMXTQ,
                quantizationBits: e.quantBits,
                detectedAt: e.detectedAt,
                source: encodeSource(e.source),
                capabilitiesJSON: encodeCapabilities(e.capabilities)
            ))
        } catch {
            NSLog("vMLX ModelLibraryDB upsert failed: \(error)")
        }
    }

    private func encodeCapabilities(_ c: ModelCapabilities) -> String {
        guard let data = try? JSONEncoder().encode(c),
              let s = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return s
    }

    private func decodeCapabilities(_ s: String) -> ModelCapabilities {
        guard !s.isEmpty, s != "{}",
              let data = s.data(using: .utf8),
              let caps = try? JSONDecoder().decode(ModelCapabilities.self, from: data) else {
            return .unknown
        }
        return caps
    }

    public func all() -> [ModelLibrary.ModelEntry] {
        (try? repository?.indexedModels())?.compactMap(recordToEntry) ?? []
    }

    public func byId(_ id: String) -> ModelLibrary.ModelEntry? {
        guard let record = try? repository?.indexedModel(legacyModelID: id) else { return nil }
        return recordToEntry(record)
    }

    public func artifact(legacyModelID: String) -> ModelArtifact? {
        try? repository?.artifact(legacyModelID: legacyModelID)
    }

    public func purge(_ ids: Set<String>) {
        try? repository?.markUnavailableAndRemoveFromIndex(ids)
    }

    /// Most-recent `detected_at` (unix seconds) across all entries, or nil if empty.
    public func mostRecentDetectedAt() -> Date? {
        (try? repository?.mostRecentDetectionDate()) ?? nil
    }

    // MARK: - User dirs

    public func userDirs() -> [URL] {
        (try? repository?.userDirectories()) ?? []
    }

    public func addUserDir(_ url: URL) {
        try? repository?.addUserDirectory(url)
    }

    public func removeUserDir(_ url: URL) {
        try? repository?.removeUserDirectory(url)
    }

    // MARK: - Row decoding

    private func recordToEntry(_ record: IndexedModelRecord) -> ModelLibrary.ModelEntry? {
        return ModelLibrary.ModelEntry(
            id: record.legacyModelID,
            canonicalPath: record.canonicalURL,
            displayName: record.displayName,
            family: record.family,
            modality: ModelLibrary.Modality(rawValue: record.modality) ?? .unknown,
            totalSizeBytes: record.totalSizeBytes,
            isJANG: record.isJANG,
            isMXTQ: record.isJANGTQ,
            quantBits: record.quantizationBits,
            detectedAt: record.detectedAt,
            source: decodeSource(record.source),
            capabilities: decodeCapabilities(record.capabilitiesJSON)
        )
    }

    private func encodeSource(_ s: ModelLibrary.Source) -> String {
        switch s {
        case .hfCache: return "hf"
        case .downloaded: return "dl"
        case .bundled(let u): return "bundle:\(u.path)"
        case .userDir(let u): return "user:\(u.path)"
        }
    }

    private func decodeSource(_ s: String) -> ModelLibrary.Source {
        if s == "hf" { return .hfCache }
        if s == "dl" { return .downloaded }
        if s.hasPrefix("bundle:") {
            return .bundled(URL(fileURLWithPath: String(s.dropFirst(7))))
        }
        if s.hasPrefix("user:") {
            return .userDir(URL(fileURLWithPath: String(s.dropFirst(5))))
        }
        return .hfCache
    }
}
