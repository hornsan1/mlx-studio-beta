// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import vMLXEngine

final class DownloadManagerJobCodableTests: XCTestCase {
    func testDecodesOlderSidecarJobWithoutManifestFiles() throws {
        let data = """
        {
          "id": "00000000-0000-0000-0000-000000000123",
          "repo": "mlx-community/Qwen3-0.6B-8bit",
          "displayName": "Qwen3 0.6B 8-bit",
          "totalBytes": 0,
          "receivedBytes": 0,
          "bytesPerSecond": 0,
          "etaSeconds": null,
          "status": "queued",
          "error": null,
          "startedAt": 0,
          "localPath": null
        }
        """.data(using: .utf8)!

        let job = try JSONDecoder().decode(DownloadManager.Job.self, from: data)

        XCTAssertEqual(job.manifestFiles, [])
        XCTAssertFalse(job.requiresHFAuth)
    }

    func testManifestFilesRoundTripThroughJobCodable() throws {
        let manifest = [
            HuggingFaceDownloadSafety.RemoteFile(path: "config.json", size: 12),
            HuggingFaceDownloadSafety.RemoteFile(path: "model.safetensors", size: 34),
        ]
        let job = DownloadManager.Job(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000456")!,
            repo: "mlx-community/test-image-model",
            displayName: "Test Image Model",
            totalBytes: 46,
            receivedBytes: 46,
            status: .completed,
            startedAt: Date(timeIntervalSinceReferenceDate: 0),
            manifestFiles: manifest
        )

        let data = try JSONEncoder().encode(job)
        let decoded = try JSONDecoder().decode(DownloadManager.Job.self, from: data)

        XCTAssertEqual(decoded.manifestFiles, manifest)
    }
}
