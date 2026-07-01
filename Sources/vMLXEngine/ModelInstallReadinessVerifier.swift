import Foundation

public enum ModelInstallReadinessVerifier {
    public struct VerificationFailure: Error, LocalizedError, CustomStringConvertible, Equatable, Sendable {
        public let repo: String
        public let localPath: URL?
        public let issues: [String]

        public init(repo: String, localPath: URL?, issues: [String]) {
            self.repo = repo
            self.localPath = localPath
            self.issues = issues
        }

        public var errorDescription: String? {
            var message = "Downloaded \(repo), but the local model is not ready for vMLX."
            if let localPath {
                message += " Checked \(localPath.path)."
            }
            if !issues.isEmpty {
                message += " \(issues.joined(separator: " "))"
            }
            return message
        }

        public var description: String {
            errorDescription ?? "Downloaded \(repo), but the local model is not ready for vMLX."
        }
    }

    public static func validateChatModel(
        repo: String,
        localPath: URL,
        manifestFiles: [HuggingFaceDownloadSafety.RemoteFile] = [],
        manifestRoot: URL? = nil
    ) throws {
        let foundIssues = chatModelIssues(
            repo: repo,
            localPath: localPath,
            manifestFiles: manifestFiles,
            manifestRoot: manifestRoot
        )
        if !foundIssues.isEmpty {
            throw VerificationFailure(
                repo: repo,
                localPath: localPath,
                issues: foundIssues
            )
        }
    }

    public static func chatModelIssues(
        repo: String,
        localPath: URL,
        manifestFiles: [HuggingFaceDownloadSafety.RemoteFile] = [],
        manifestRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> [String] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: localPath.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return ["Local model directory is missing."]
        }

        var issues: [String] = []
        if !fileManager.fileExists(atPath: localPath.appendingPathComponent("config.json").path) {
            issues.append("config.json is missing.")
        }
        if !hasTokenizerEvidence(in: localPath, fileManager: fileManager) {
            issues.append("Tokenizer files are missing.")
        }
        if !hasWeightEvidence(in: localPath, fileManager: fileManager) {
            issues.append("No model weight file was found.")
        }

        if !manifestFiles.isEmpty {
            let manifestIssues = HuggingFaceDownloadSafety.verificationIssues(
                files: manifestFiles,
                under: manifestRoot ?? localPath,
                fileManager: fileManager
            )
            issues.append(contentsOf: manifestIssues.map { "\($0.path) \($0.reason)" })
        }

        return issues
    }

    private static func hasTokenizerEvidence(in directory: URL, fileManager: FileManager) -> Bool {
        let directPaths = [
            "tokenizer.json",
            "tokenizer.model",
            "spiece.model"
        ]
        if directPaths.contains(where: { fileManager.fileExists(atPath: directory.appendingPathComponent($0).path) }) {
            return true
        }
        let vocab = directory.appendingPathComponent("vocab.json")
        let merges = directory.appendingPathComponent("merges.txt")
        return fileManager.fileExists(atPath: vocab.path)
            && fileManager.fileExists(atPath: merges.path)
    }

    private static func hasWeightEvidence(in directory: URL, fileManager: FileManager) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return false }

        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "safetensors" || ext == "bin" || ext == "gguf" else { continue }
            let resolved = url.resolvingSymlinksInPath()
            if fileManager.fileExists(atPath: resolved.path) {
                return true
            }
        }
        return false
    }
}
