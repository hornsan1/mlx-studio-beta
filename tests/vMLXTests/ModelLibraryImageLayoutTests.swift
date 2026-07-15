// SPDX-License-Identifier: Apache-2.0

import Foundation
import MLXStudioDomain
import SQLite3
import XCTest
@testable import vMLXEngine

final class ModelLibraryImageLayoutTests: XCTestCase {
    func testForcedScanPreservesLineageDerivedArtifactsOutsideScanRoots() {
        let parentID = ModelArtifactID()
        let derived = ModelArtifact(
            projectID: ModelProjectID(),
            parentArtifactID: parentID,
            name: "Verified Optimize Output",
            localURL: URL(fileURLWithPath: "/artifacts/verified-output"),
            format: .jang,
            state: .ready,
            verificationStatus: .passed
        )
        let stale = ModelLibrary.staleScanManagedIDs(
            existingIDs: ["legacy-scan-row", derived.id.rawValue],
            discoveredIDs: [],
            artifactForID: { $0 == derived.id ? derived : nil }
        )

        XCTAssertEqual(stale, ["legacy-scan-row"])
    }

    func testIncompleteSafetensorShardSetIsNotReady() throws {
        let root = try makeDirectory(named: "incomplete-shards")
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("first".utf8).write(
            to: root.appendingPathComponent("model-00001-of-00002.safetensors")
        )

        XCTAssertFalse(ModelLibrary.hasCompleteSafetensorShardSets(at: root))
    }

    func testCompleteSafetensorShardSetIsReady() throws {
        let root = try makeDirectory(named: "complete-shards")
        defer { try? FileManager.default.removeItem(at: root) }

        for index in 1...2 {
            try Data("shard \(index)".utf8).write(
                to: root.appendingPathComponent(
                    String(format: "model-%05d-of-%05d.safetensors", index, 2)
                )
            )
        }

        XCTAssertTrue(ModelLibrary.hasCompleteSafetensorShardSets(at: root))
    }

    func testUnshardedSafetensorModelRemainsReady() throws {
        let root = try makeDirectory(named: "unsharded-model")
        defer { try? FileManager.default.removeItem(at: root) }

        try Data("weights".utf8).write(to: root.appendingPathComponent("model.safetensors"))

        XCTAssertTrue(ModelLibrary.hasCompleteSafetensorShardSets(at: root))
    }

    func testIncompleteShardedModelIsNotDiscoveredUntilAllShardsArrive() async throws {
        let root = try makeDirectory(named: "model-library-shard-discovery")
        defer { try? FileManager.default.removeItem(at: root) }

        let model = root.appendingPathComponent("chat-model", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{\"model_type\":\"qwen3\"}".utf8).write(
            to: model.appendingPathComponent("config.json")
        )
        try writeDiscoveryWeight(
            to: model.appendingPathComponent("model-00001-of-00002.safetensors")
        )

        let database = ModelLibraryDB(customPath: root.appendingPathComponent("models.sqlite3"))
        let library = ModelLibrary(database: database)
        await library.addUserDir(root)

        let incompleteEntries = await library.scan(force: true)
        XCTAssertFalse(incompleteEntries.contains {
            $0.canonicalPath == model.standardizedFileURL
        })

        try writeDiscoveryWeight(
            to: model.appendingPathComponent("model-00002-of-00002.safetensors")
        )

        let entries = await library.scan(force: true)
        XCTAssertEqual(
            entries.filter { $0.canonicalPath == model.standardizedFileURL }.count,
            1
        )
    }

    func testJANGTQDiscoveryDualWritesArtifactAndDeletionPreservesHistory() async throws {
        let root = try makeDirectory(named: "model-library-artifact")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = root.appendingPathComponent("jangtq-model", isDirectory: true)
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("{\"model_type\":\"qwen3\"}".utf8).write(
            to: model.appendingPathComponent("config.json")
        )
        try Data("{\"quantization\":{\"method\":\"mxtq\",\"bits\":3}}".utf8).write(
            to: model.appendingPathComponent("jang_config.json")
        )
        try writeDiscoveryWeight(to: model.appendingPathComponent("model.safetensors"))

        let database = ModelLibraryDB(customPath: root.appendingPathComponent("models.sqlite3"))
        let library = ModelLibrary(database: database)
        await library.addUserDir(root)
        let entries = await library.scan(force: true)
        let entry = try XCTUnwrap(entries.first {
            $0.canonicalPath == model.standardizedFileURL
        })
        XCTAssertTrue(entry.isJANG)
        XCTAssertTrue(entry.isMXTQ)
        XCTAssertEqual(entry.quantBits, 3)
        let artifactValue = await library.artifact(forEntryID: entry.id)
        let artifact = try XCTUnwrap(artifactValue)
        XCTAssertEqual(artifact.format.rawValue, "jangtq")
        XCTAssertEqual(artifact.state.rawValue, "ready")

        await library.markLoadStarted(model)
        await XCTAssertThrowsErrorAsync {
            _ = try await library.deleteEntry(byId: entry.id)
        }
        await library.markLoadFinished(model)
        let deleted = try await library.deleteEntry(byId: entry.id)
        XCTAssertTrue(deleted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.path))
        let deletedEntry = await library.entry(byId: entry.id)
        let retiredArtifact = await library.artifact(forEntryID: entry.id)
        XCTAssertNil(deletedEntry)
        XCTAssertEqual(retiredArtifact?.state.rawValue, "unavailable")
    }

    func testInstalledModelIndexBackupOpensThroughArtifactRepositoryWhenProvided() async throws {
        guard let sourcePath = ProcessInfo.processInfo.environment["MLX_STUDIO_INSTALLED_MODELS_DB"] else {
            throw XCTSkip("Set MLX_STUDIO_INSTALLED_MODELS_DB for the read-only installed-model smoke")
        }
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: sourcePath)
        let root = try makeDirectory(named: "installed-model-index-smoke")
        defer { try? FileManager.default.removeItem(at: root) }
        let destinationURL = root.appendingPathComponent("models.sqlite3")
        let expectedCount = try backupDatabase(from: sourceURL, to: destinationURL)

        let database = ModelLibraryDB(customPath: destinationURL)
        XCTAssertNil(database.migrationErrorDescription)
        let library = ModelLibrary(database: database)
        let entries = await library.entries()
        XCTAssertEqual(entries.count, expectedCount)
        for entry in entries {
            let artifact = await library.artifact(forEntryID: entry.id)
            XCTAssertNotNil(artifact)
        }

        let attributesAfter = try FileManager.default.attributesOfItem(atPath: sourcePath)
        XCTAssertEqual(attributesAfter[.size] as? NSNumber, attributesBefore[.size] as? NSNumber)
        XCTAssertEqual(
            attributesAfter[.modificationDate] as? Date,
            attributesBefore[.modificationDate] as? Date
        )
    }

    func testFlux2ComponentLayoutIsLoadableImageRuntimeLayout() throws {
        let root = try makeImageLayoutDirectory(named: "flux2-klein")
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(ModelLibrary.hasImageRuntimeLayout(at: root))
        XCTAssertEqual(
            ModelLibrary.imageRuntimeNameHint(in: "mlx-community/flux2-klein-4b-4bit \(root.path)"),
            "flux2-klein"
        )
    }

    func testKrea2ImageRuntimeHintIsRecognized() throws {
        let root = try makeImageLayoutDirectory(named: "krea-2-turbo")
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            ModelLibrary.imageRuntimeNameHint(in: "krea/Krea-2-Turbo \(root.path)"),
            "krea-2-turbo"
        )
    }

    func testImageLayoutRequiresTokenizerAndVAE() throws {
        let missingTokenizer = try makeImageLayoutDirectory(named: "flux-without-tokenizer")
        defer { try? FileManager.default.removeItem(at: missingTokenizer) }
        try FileManager.default.removeItem(
            at: missingTokenizer.appendingPathComponent("tokenizer/tokenizer.json")
        )

        XCTAssertFalse(ModelLibrary.hasImageRuntimeLayout(at: missingTokenizer))

        let missingVAE = try makeImageLayoutDirectory(named: "flux-without-vae")
        defer { try? FileManager.default.removeItem(at: missingVAE) }
        try FileManager.default.removeItem(
            at: missingVAE.appendingPathComponent("vae/0.safetensors")
        )

        XCTAssertFalse(ModelLibrary.hasImageRuntimeLayout(at: missingVAE))
    }

    private func makeImageLayoutDirectory(named name: String) throws -> URL {
        let root = try makeDirectory(named: name)
        for component in ["transformer", "text_encoder", "vae", "tokenizer"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(component, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        try Data("stub".utf8).write(to: root.appendingPathComponent("transformer/0.safetensors"))
        try Data("stub".utf8).write(to: root.appendingPathComponent("text_encoder/0.safetensors"))
        try Data("stub".utf8).write(to: root.appendingPathComponent("vae/0.safetensors"))
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer/tokenizer.json"))
        return root
    }

    private func makeDirectory(named name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.standardizedFileURL
    }

    private func writeDiscoveryWeight(to url: URL) throws {
        let size = 8 * 1024 * 1024
        try Data(repeating: 0, count: size).write(to: url)
    }

    private func backupDatabase(from sourceURL: URL, to destinationURL: URL) throws -> Int {
        var source: OpaquePointer?
        var destination: OpaquePointer?
        guard sqlite3_open_v2(
            sourceURL.path,
            &source,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let source else { throw ModelLibraryBackupError.openSource }
        defer { sqlite3_close_v2(source) }
        guard sqlite3_open_v2(
            destinationURL.path,
            &destination,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let destination else { throw ModelLibraryBackupError.openDestination }
        defer { sqlite3_close_v2(destination) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(source, "SELECT COUNT(*) FROM models;", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW
        else { throw ModelLibraryBackupError.count }
        let count = Int(sqlite3_column_int64(statement, 0))
        sqlite3_finalize(statement)

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw ModelLibraryBackupError.backup
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw ModelLibraryBackupError.backup
        }
        return count
    }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected expression to throw", file: file, line: line)
    } catch {}
}

private enum ModelLibraryBackupError: Error {
    case openSource
    case openDestination
    case count
    case backup
}
