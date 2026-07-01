import Foundation
import vMLXFluxKit

public enum ImageModelInstallVerifier {
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
            var message = "Image model \(repo) is not ready for vMLX image generation."
            if let localPath {
                message += " Checked \(localPath.path)."
            }
            if !issues.isEmpty {
                message += " \(issues.joined(separator: " "))"
            }
            return message
        }

        public var description: String {
            errorDescription ?? "Image model \(repo) failed verification."
        }
    }

    public static func validate(
        runtimeName: String?,
        repo: String,
        localPath: URL,
        manifestFiles: [HuggingFaceDownloadSafety.RemoteFile] = []
    ) throws {
        let foundIssues = issues(
            runtimeName: runtimeName,
            repo: repo,
            localPath: localPath,
            manifestFiles: manifestFiles
        )
        if !foundIssues.isEmpty {
            throw VerificationFailure(
                repo: repo,
                localPath: localPath,
                issues: foundIssues
            )
        }
    }

    public static func issues(
        runtimeName: String?,
        repo: String,
        localPath: URL,
        manifestFiles: [HuggingFaceDownloadSafety.RemoteFile] = []
    ) -> [String] {
        let normalized = normalize(runtimeName ?? repo)
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: localPath.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return ["Local model directory is missing."]
        }

        let layoutIssues: [String]
        switch normalized {
        case "flux1-schnell", "flux1-dev":
            layoutIssues = WeightLoader.componentLayoutIssues(
                in: localPath,
                requiredComponents: ["transformer", "text_encoder", "text_encoder_2", "vae"],
                requiredFiles: [
                    "tokenizer/tokenizer.json",
                    "tokenizer_2/tokenizer.json",
                ]
            )

        case "z-image-turbo":
            layoutIssues = WeightLoader.componentLayoutIssues(
                in: localPath,
                requiredComponents: ["transformer", "text_encoder", "vae"],
                requiredFiles: ["tokenizer/tokenizer.json"]
            )

        case "flux2-klein":
            layoutIssues = WeightLoader.componentLayoutIssues(
                in: localPath,
                requiredComponents: ["transformer", "text_encoder", "vae"],
                requiredFiles: ["tokenizer/tokenizer.json"]
            )

        case "qwen-image":
            return ["Qwen-Image is scaffolded in this beta, but not prompt-proven by the vMLX image runtime yet."]

        default:
            return ["Unsupported image runtime '\(runtimeName ?? repo)'."]
        }

        let manifestIssues = HuggingFaceDownloadSafety.verificationIssues(
            files: manifestFiles,
            under: localPath
        ).map { "\($0.path) \($0.reason)" }
        return layoutIssues + manifestIssues
    }

    private static func normalize(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.contains("flux") && lower.contains("schnell") {
            return "flux1-schnell"
        }
        if lower.contains("flux") && lower.contains("dev") {
            return "flux1-dev"
        }
        if lower.contains("flux") && lower.contains("klein") {
            return "flux2-klein"
        }
        if lower.contains("z-image") || lower.contains("zimage") {
            return "z-image-turbo"
        }
        if lower.contains("qwen-image") || lower.contains("qwen image") {
            return "qwen-image"
        }
        return lower
    }
}
