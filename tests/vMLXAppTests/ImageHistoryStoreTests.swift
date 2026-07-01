import Foundation
import XCTest
import vMLXEngine
@testable import vMLXApp

final class ImageHistoryStoreTests: XCTestCase {
    private var tempDir: URL!
    private var dbURL: URL!
    private var outputURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlxstudio-image-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbURL = tempDir.appendingPathComponent("image_history.sqlite3")
        outputURL = tempDir.appendingPathComponent("output.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: outputURL)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        outputURL = nil
        dbURL = nil
        tempDir = nil
        try super.tearDownWithError()
    }

    func testImageHistoryPersistsUpdatesOrdersAndDeletesRecords() throws {
        let store = ImageHistoryStore(customPath: dbURL)
        let oldID = UUID()
        let newID = UUID()
        let settings = try settingsJSON(
            ImageGenSettings(steps: 4, guidance: 3.5, width: 512, height: 512, seed: 12)
        )

        XCTAssertTrue(store.upsert(ImageGenerationRecord(
            id: oldID,
            modelAlias: "FLUX.2 Klein",
            prompt: "Old prompt",
            settingsJSON: settings,
            outputPath: outputURL.path,
            createdAt: Date(timeIntervalSince1970: 100),
            durationMs: 900,
            status: .completed
        )))
        XCTAssertTrue(store.upsert(ImageGenerationRecord(
            id: newID,
            modelAlias: "Z-Image Turbo",
            prompt: "Newest prompt",
            settingsJSON: settings,
            outputPath: outputURL.path,
            createdAt: Date(timeIntervalSince1970: 200),
            durationMs: 700,
            status: .completed
        )))

        var records = store.all()
        XCTAssertEqual(records.map(\.id), [newID, oldID])
        XCTAssertEqual(records.first?.modelAlias, "Z-Image Turbo")

        XCTAssertTrue(store.upsert(ImageGenerationRecord(
            id: newID,
            modelAlias: "Z-Image Turbo",
            prompt: "Updated prompt",
            settingsJSON: settings,
            outputPath: outputURL.path,
            createdAt: Date(timeIntervalSince1970: 200),
            durationMs: 111,
            status: .failed
        )))
        records = store.all()
        XCTAssertEqual(records.first?.prompt, "Updated prompt")
        XCTAssertEqual(records.first?.durationMs, 111)
        XCTAssertEqual(records.first?.status, .failed)

        XCTAssertTrue(store.delete(oldID))
        XCTAssertEqual(store.all().map(\.id), [newID])
    }

    func testImageMetadataSidecarPersistsPromptSettingsAndRuntimeProofPath() throws {
        let settings = ImageGenSettings(
            steps: 6,
            guidance: 1.5,
            width: 256,
            height: 256,
            seed: 42,
            scheduler: "beta"
        )
        let record = ImageGenerationRecord(
            modelAlias: "Z-Image Turbo",
            prompt: "Sidecar prompt",
            settingsJSON: try settingsJSON(settings),
            outputPath: outputURL.path,
            createdAt: Date(timeIntervalSince1970: 500),
            durationMs: 1200,
            status: .completed
        )

        let sidecarURL = try XCTUnwrap(
            record.writeMetadataSidecar(
                runtimeName: "z-image-turbo",
                modelPath: "/tmp/model"
            )
        )
        let data = try Data(contentsOf: sidecarURL)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decodedSettings = try XCTUnwrap(json["settings"] as? [String: Any])

        XCTAssertEqual(json["prompt"] as? String, "Sidecar prompt")
        XCTAssertEqual(json["modelAlias"] as? String, "Z-Image Turbo")
        XCTAssertEqual(json["runtimeName"] as? String, "z-image-turbo")
        XCTAssertEqual(json["modelPath"] as? String, "/tmp/model")
        XCTAssertEqual(decodedSettings["width"] as? Int, 256)
        XCTAssertEqual(decodedSettings["height"] as? Int, 256)
        XCTAssertEqual(decodedSettings["seed"] as? Int, 42)
        XCTAssertEqual(record.metadataSidecarStatus, .saved)
    }

    func testMetadataSidecarStatusDetectsMissingAndStaleFiles() throws {
        let record = ImageGenerationRecord(
            modelAlias: "Z-Image Turbo",
            prompt: "Sidecar status prompt",
            settingsJSON: try settingsJSON(ImageGenSettings()),
            outputPath: outputURL.path,
            status: .completed
        )

        XCTAssertEqual(record.metadataSidecarStatus, .missing)

        try """
        {
          "schemaVersion": 1,
          "id": "\(record.id.uuidString)",
          "modelAlias": "Different Model",
          "prompt": "\(record.prompt)",
          "outputPath": "\(outputURL.path)",
          "status": "completed"
        }
        """.write(to: try XCTUnwrap(record.metadataSidecarURL), atomically: true, encoding: .utf8)

        switch record.metadataSidecarStatus {
        case .stale(let reason):
            XCTAssertTrue(reason.contains("modelAlias"))
        default:
            XCTFail("Expected stale sidecar status")
        }
    }

    func testImageMetadataExportWritesSafeJSONFile() throws {
        let settings = ImageGenSettings(
            steps: 8,
            guidance: 2.25,
            width: 384,
            height: 256,
            seed: 77
        )
        let record = ImageGenerationRecord(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            modelAlias: "Z/Image: Turbo?",
            prompt: "Export metadata prompt",
            settingsJSON: try settingsJSON(settings),
            outputPath: outputURL.path,
            createdAt: Date(timeIntervalSince1970: 600),
            durationMs: 1400,
            status: .completed
        )
        let directory = tempDir.appendingPathComponent("metadata-exports", isDirectory: true)

        let url = try record.writeMetadataExport(to: directory)
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decodedSettings = try XCTUnwrap(json["settings"] as? [String: Any])

        XCTAssertEqual(url.lastPathComponent, "Z-Image- Turbo--AAAAAAAA.json")
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertEqual(json["prompt"] as? String, "Export metadata prompt")
        XCTAssertEqual(json["modelAlias"] as? String, "Z/Image: Turbo?")
        XCTAssertEqual(json["outputPath"] as? String, outputURL.path)
        XCTAssertEqual(decodedSettings["width"] as? Int, 384)
        XCTAssertEqual(decodedSettings["height"] as? Int, 256)
        XCTAssertEqual(decodedSettings["seed"] as? Int, 77)
    }

    func testDeleteOutputAndSidecarRemovesBothArtifacts() throws {
        let record = ImageGenerationRecord(
            modelAlias: "Z-Image Turbo",
            prompt: "Delete artifacts prompt",
            settingsJSON: try settingsJSON(ImageGenSettings()),
            outputPath: outputURL.path,
            status: .completed
        )
        let sidecarURL = try XCTUnwrap(record.writeMetadataSidecar())

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecarURL.path))

        record.deleteOutputAndSidecar()

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecarURL.path))
    }

    func testFailedImageHistoryRecordPersistsAndExportsWithoutOutputPath() throws {
        let store = ImageHistoryStore(customPath: dbURL)
        let id = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
        let settings = ImageGenSettings(
            steps: 3,
            guidance: 1.25,
            width: 256,
            height: 192,
            seed: 101
        )
        let record = ImageGenerationRecord(
            id: id,
            modelAlias: "Failed Image Model",
            prompt: "Failed image prompt",
            settingsJSON: try settingsJSON(settings),
            outputPath: nil,
            createdAt: Date(timeIntervalSince1970: 700),
            durationMs: 250,
            status: .failed
        )

        XCTAssertTrue(store.upsert(record))
        let persisted = try XCTUnwrap(store.all().first)
        XCTAssertEqual(persisted.id, id)
        XCTAssertEqual(persisted.status, .failed)
        XCTAssertNil(persisted.outputPath)

        let directory = tempDir.appendingPathComponent("failed-metadata-exports", isDirectory: true)
        let url = try persisted.writeMetadataExport(to: directory)
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let decodedSettings = try XCTUnwrap(json["settings"] as? [String: Any])

        XCTAssertEqual(url.lastPathComponent, "Failed Image Model-BBBBBBBB.json")
        XCTAssertEqual(json["prompt"] as? String, "Failed image prompt")
        XCTAssertEqual(json["modelAlias"] as? String, "Failed Image Model")
        XCTAssertEqual(json["status"] as? String, "failed")
        XCTAssertNil(json["outputPath"] as? String)
        XCTAssertEqual(decodedSettings["width"] as? Int, 256)
        XCTAssertEqual(decodedSettings["height"] as? Int, 192)
        XCTAssertEqual(decodedSettings["seed"] as? Int, 101)
    }

    private func settingsJSON(_ settings: ImageGenSettings) throws -> String {
        let data = try JSONEncoder().encode(settings)
        return String(decoding: data, as: UTF8.self)
    }
}
