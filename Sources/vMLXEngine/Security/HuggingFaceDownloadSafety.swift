import Foundation

/// Safety helpers for turning Hugging Face repo paths into local model files.
///
/// The downloader still owns networking and progress. This type keeps the
/// filesystem invariants small, public, and unit-testable.
public enum HuggingFaceDownloadSafety {
    public struct RemoteFile: Sendable, Equatable, Codable {
        public let path: String
        public let size: Int64?

        public init(path: String, size: Int64?) {
            self.path = path
            self.size = size
        }
    }

    public struct VerificationIssue: Sendable, Equatable {
        public let path: String
        public let reason: String

        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    public struct VerificationFailure: Error, LocalizedError, Sendable, Equatable {
        public let issues: [VerificationIssue]

        public var errorDescription: String? {
            guard let first = issues.first else {
                return "Download incomplete."
            }
            if issues.count == 1 {
                return "Download incomplete: \(first.path) \(first.reason)."
            }
            return "Download incomplete: \(issues.count) files are missing or have the wrong size."
        }
    }

    /// Fixed safety headroom for destination-volume checks. This covers HF size
    /// rounding, temporary files, and the final move into place.
    public static let storageSafetyMarginBytes: Int64 = 256 * 1024 * 1024

    /// Accept only simple slash-separated relative paths from Hugging Face.
    public static func normalizedRemoteFilePath(_ path: String) -> String? {
        guard !path.isEmpty,
              !path.contains("\\"),
              !path.contains("\0"),
              !(path as NSString).isAbsolutePath
        else { return nil }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return nil }

        var normalized: [String] = []
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                return nil
            }
            normalized.append(String(component))
        }
        return normalized.joined(separator: "/")
    }

    public static func destinationURL(forRemotePath path: String, under directory: URL) -> URL? {
        guard let safePath = normalizedRemoteFilePath(path) else { return nil }
        let base = directory.standardizedFileURL
        let destination = safePath
            .split(separator: "/")
            .reduce(base) { partial, component in
                partial.appendingPathComponent(String(component))
            }
            .standardizedFileURL

        guard isContained(destination, in: base),
              existingParentChainIsContained(for: destination, under: base)
        else { return nil }
        return destination
    }

    public static func resolveURL(repo: String, path: String) -> URL? {
        guard let safePath = normalizedRemoteFilePath(path) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repo)/resolve/main/\(safePath)"
        return components.url
    }

    public static func verificationIssues(
        files: [RemoteFile],
        under directory: URL,
        fileManager: FileManager = .default
    ) -> [VerificationIssue] {
        files.compactMap { file in
            guard let destination = destinationURL(forRemotePath: file.path, under: directory) else {
                return VerificationIssue(path: file.path, reason: "has an unsafe destination")
            }

            guard let attrs = try? fileManager.attributesOfItem(atPath: destination.path),
                  let number = attrs[.size] as? NSNumber
            else {
                return VerificationIssue(path: file.path, reason: "is missing")
            }

            if let expected = file.size, expected > 0, number.int64Value != expected {
                return VerificationIssue(path: file.path, reason: "has the wrong size")
            }
            return nil
        }
    }

    public static func verifyManifest(files: [RemoteFile], under directory: URL) throws {
        let issues = verificationIssues(files: files, under: directory)
        if !issues.isEmpty {
            throw VerificationFailure(issues: issues)
        }
    }

    public static func storageRefusalMessage(neededBytes: Int64, freeBytes: Int64) -> String? {
        guard neededBytes > 0 else { return nil }
        guard neededBytes + storageSafetyMarginBytes > freeBytes else { return nil }
        let needed = ByteCountFormatter.string(fromByteCount: neededBytes, countStyle: .file)
        let free = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
        return "Not enough disk space to finish this download: need \(needed) free, only \(free) available."
    }

    private static func isContained(_ candidate: URL, in base: URL) -> Bool {
        let basePath = base.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == basePath || candidatePath.hasPrefix(basePath + "/")
    }

    private static func existingParentChainIsContained(for destination: URL, under base: URL) -> Bool {
        let fileManager = FileManager.default
        let resolvedBase = base.resolvingSymlinksInPath().standardizedFileURL
        var current = destination.deletingLastPathComponent().standardizedFileURL

        while current.path.hasPrefix(base.path) {
            if fileManager.fileExists(atPath: current.path) {
                let resolved = current.resolvingSymlinksInPath().standardizedFileURL
                guard isContained(resolved, in: resolvedBase) else { return false }
            }
            if current.path == base.path { break }
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }
        return true
    }
}
