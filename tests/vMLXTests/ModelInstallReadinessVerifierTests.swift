// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import vMLXEngine

final class ModelInstallReadinessVerifierTests: XCTestCase {
    func testChatModelLayoutPassesWithConfigTokenizerAndWeights() throws {
        let root = try makeChatDirectory(tokenizer: .json)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNoThrow(
            try ModelInstallReadinessVerifier.validateChatModel(
                repo: "mlx-community/Qwen3-0.6B-8bit",
                localPath: root
            )
        )
    }

    func testChatModelAcceptsVocabAndMergesTokenizerEvidence() throws {
        let root = try makeChatDirectory(tokenizer: .vocabAndMerges)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(
            ModelInstallReadinessVerifier.chatModelIssues(
                repo: "mlx-community/tiny-bpe",
                localPath: root
            ).isEmpty
        )
    }

    func testChatModelReportsMissingTokenizerAndWeights() throws {
        let root = try makeDirectory(named: "vmlx-chat-incomplete")
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))

        let issues = ModelInstallReadinessVerifier.chatModelIssues(
            repo: "mlx-community/incomplete",
            localPath: root
        )

        XCTAssertTrue(issues.contains("Tokenizer files are missing."))
        XCTAssertTrue(issues.contains("No model weight file was found."))
    }

    func testTokenizerConfigAloneDoesNotCountAsTokenizerEvidence() throws {
        let root = try makeDirectory(named: "vmlx-chat-tokenizer-config-only")
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer_config.json"))
        try Data("weights".utf8).write(to: root.appendingPathComponent("model.safetensors"))

        XCTAssertTrue(
            ModelInstallReadinessVerifier.chatModelIssues(
                repo: "mlx-community/config-only-tokenizer",
                localPath: root
            ).contains("Tokenizer files are missing.")
        )
    }

    func testChatModelReportsMissingDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmlx-chat-missing-\(UUID().uuidString)", isDirectory: true)

        XCTAssertEqual(
            ModelInstallReadinessVerifier.chatModelIssues(
                repo: "mlx-community/missing",
                localPath: root
            ),
            ["Local model directory is missing."]
        )
    }

    func testChatModelManifestVerificationIsPartOfReadiness() throws {
        let root = try makeChatDirectory(tokenizer: .json)
        defer { try? FileManager.default.removeItem(at: root) }

        let cleanManifest = [
            HuggingFaceDownloadSafety.RemoteFile(path: "config.json", size: 2),
            HuggingFaceDownloadSafety.RemoteFile(path: "tokenizer.json", size: 2),
            HuggingFaceDownloadSafety.RemoteFile(path: "model.safetensors", size: 7),
        ]

        XCTAssertTrue(
            ModelInstallReadinessVerifier.chatModelIssues(
                repo: "mlx-community/Qwen3-0.6B-8bit",
                localPath: root,
                manifestFiles: cleanManifest
            ).isEmpty
        )

        let brokenManifest = [
            HuggingFaceDownloadSafety.RemoteFile(path: "model.safetensors", size: 99),
            HuggingFaceDownloadSafety.RemoteFile(path: "missing.safetensors", size: 4),
        ]

        let issues = ModelInstallReadinessVerifier.chatModelIssues(
            repo: "mlx-community/Qwen3-0.6B-8bit",
            localPath: root,
            manifestFiles: brokenManifest
        )

        XCTAssertTrue(issues.contains("model.safetensors has the wrong size"))
        XCTAssertTrue(issues.contains("missing.safetensors is missing"))
    }

    private enum TokenizerFixture {
        case json
        case vocabAndMerges
    }

    private func makeChatDirectory(tokenizer: TokenizerFixture) throws -> URL {
        let root = try makeDirectory(named: "vmlx-chat-ready")
        try Data("{}".utf8).write(to: root.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: root.appendingPathComponent("model.safetensors"))
        switch tokenizer {
        case .json:
            try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
        case .vocabAndMerges:
            try Data("{}".utf8).write(to: root.appendingPathComponent("vocab.json"))
            try Data("#version: 0.2".utf8).write(to: root.appendingPathComponent("merges.txt"))
        }
        return root
    }

    private func makeDirectory(named prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }
}
