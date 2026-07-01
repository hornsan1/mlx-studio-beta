// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import vMLXEngine

final class HuggingFaceDownloadSafetyTests: XCTestCase {
    func testNormalizesPortableRelativePaths() {
        XCTAssertEqual(
            HuggingFaceDownloadSafety.normalizedRemoteFilePath("config.json"),
            "config.json"
        )
        XCTAssertEqual(
            HuggingFaceDownloadSafety.normalizedRemoteFilePath("shards/model.safetensors"),
            "shards/model.safetensors"
        )
    }

    func testRejectsEscapingOrPlatformSpecificRemotePaths() {
        for path in [
            "",
            "/tmp/model.safetensors",
            "../model.safetensors",
            "weights/../model.safetensors",
            "weights//model.safetensors",
            "weights/./model.safetensors",
            "weights\\model.safetensors",
            "weights/model.safetensors\0",
        ] {
            XCTAssertNil(
                HuggingFaceDownloadSafety.normalizedRemoteFilePath(path),
                "accepted \(path)"
            )
        }
    }

    func testDestinationURLStaysInsideModelDirectory() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let destination = try XCTUnwrap(
            HuggingFaceDownloadSafety.destinationURL(
                forRemotePath: "shards/model-00001.safetensors",
                under: root
            )
        )

        XCTAssertEqual(
            destination.path,
            root.appendingPathComponent("shards/model-00001.safetensors").path
        )
    }

    func testDestinationURLRejectsSymlinkedParentEscapes() throws {
        let root = try makeDirectory()
        let outside = try makeDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let link = root.appendingPathComponent("shards", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertNil(
            HuggingFaceDownloadSafety.destinationURL(
                forRemotePath: "shards/model-00001.safetensors",
                under: root
            )
        )
    }

    func testManifestVerificationReportsMissingAndWrongSizeFiles() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("abc".utf8).write(to: root.appendingPathComponent("config.json"))
        try Data("weights".utf8).write(to: root.appendingPathComponent("model.safetensors"))

        let issues = HuggingFaceDownloadSafety.verificationIssues(
            files: [
                .init(path: "config.json", size: 3),
                .init(path: "model.safetensors", size: 99),
                .init(path: "tokenizer.json", size: 2),
            ],
            under: root
        )

        XCTAssertEqual(issues.count, 2)
        XCTAssertTrue(issues.contains { $0.path == "model.safetensors" })
        XCTAssertTrue(issues.contains { $0.path == "tokenizer.json" })
    }

    func testStorageRefusalUsesSafetyMargin() {
        let margin = HuggingFaceDownloadSafety.storageSafetyMarginBytes
        XCTAssertNil(
            HuggingFaceDownloadSafety.storageRefusalMessage(
                neededBytes: 1_000,
                freeBytes: 1_000 + margin
            )
        )
        XCTAssertNotNil(
            HuggingFaceDownloadSafety.storageRefusalMessage(
                neededBytes: 1_000,
                freeBytes: 999 + margin
            )
        )
    }

    func testResolveURLEncodesPathComponents() {
        let url = HuggingFaceDownloadSafety.resolveURL(
            repo: "mlx-community/Test Model",
            path: "weights/model 1.safetensors"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://huggingface.co/mlx-community/Test%20Model/resolve/main/weights/model%201.safetensors"
        )
        XCTAssertNil(HuggingFaceDownloadSafety.resolveURL(repo: "mlx-community/test", path: "../config.json"))
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmlx-hf-safety-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }
}
