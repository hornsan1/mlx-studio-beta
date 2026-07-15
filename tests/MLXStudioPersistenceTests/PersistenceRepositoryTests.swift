import Foundation
import MLXStudioDomain
import SQLite3
import XCTest
@testable import MLXStudioPersistence

final class PersistenceRepositoryTests: XCTestCase {
    func testIndexedModelDualWritesArtifactAndPreservesIdentityOnUpdate() throws {
        try withRepository { repository, databaseURL in
            let first = IndexedModelRecord(
                legacyModelID: "legacy-jangtq-\"quoted\"",
                canonicalURL: URL(fileURLWithPath: "/models/jangtq"),
                displayName: "JANGTQ Model",
                family: "qwen",
                modality: "text",
                totalSizeBytes: 100,
                isJANG: true,
                isJANGTQ: true,
                quantizationBits: 3,
                detectedAt: Date(timeIntervalSince1970: 100),
                source: "hf",
                capabilitiesJSON: "{\"chat\":true}"
            )
            try repository.upsertIndexedModel(first)
            let artifact = try XCTUnwrap(repository.artifact(legacyModelID: first.legacyModelID))
            XCTAssertEqual(artifact.format, .jangTQ)
            XCTAssertEqual(artifact.precision?.rawValue, "3-bit")
            XCTAssertEqual(artifact.state, .ready)

            var updated = first
            updated.displayName = "Renamed JANGTQ Model"
            updated.detectedAt = Date(timeIntervalSince1970: 200)
            try repository.upsertIndexedModel(updated)

            XCTAssertEqual(try repository.artifact(legacyModelID: first.legacyModelID)?.id, artifact.id)
            XCTAssertEqual(
                try repository.indexedModel(legacyModelID: first.legacyModelID)?.displayName,
                updated.displayName
            )
            XCTAssertEqual(try scalar(databaseURL, "SELECT COUNT(*) FROM models;"), 1)
            XCTAssertEqual(try scalar(databaseURL, "SELECT COUNT(*) FROM model_artifacts;"), 1)
            XCTAssertEqual(
                try text(databaseURL, "SELECT json_extract(payload_json, '$.imported_from_legacy_model_id') FROM artifact_manifests;"),
                first.legacyModelID
            )
        }
    }

    func testArtifactFirstReadFallsBackToUnmappedLegacyRows() throws {
        try withRepository { repository, databaseURL in
            try execute(databaseURL, """
            INSERT INTO models VALUES (
                'legacy-only', '/models/legacy-only', 'Legacy Only', 'mistral',
                'text', 12, 0, 0, NULL, 300, 'user:/models', '{}'
            );
            """)

            let record = try XCTUnwrap(repository.indexedModel(legacyModelID: "legacy-only"))
            XCTAssertEqual(record.displayName, "Legacy Only")
            XCTAssertNil(try repository.artifact(legacyModelID: "legacy-only"))
        }
    }

    func testRemovalRetiresIndexRowButPreservesUnavailableArtifact() throws {
        try withRepository { repository, databaseURL in
            let record = IndexedModelRecord(
                legacyModelID: "legacy-delete",
                canonicalURL: URL(fileURLWithPath: "/models/delete"),
                displayName: "Delete Me",
                family: "qwen",
                modality: "text",
                totalSizeBytes: 10,
                isJANG: false,
                isJANGTQ: false,
                quantizationBits: nil,
                detectedAt: Date(timeIntervalSince1970: 400),
                source: "dl",
                capabilitiesJSON: "{}"
            )
            try repository.upsertIndexedModel(record)
            try repository.markUnavailableAndRemoveFromIndex([record.legacyModelID])

            XCTAssertNil(try repository.indexedModel(legacyModelID: record.legacyModelID))
            XCTAssertEqual(
                try repository.artifact(legacyModelID: record.legacyModelID)?.state,
                .unavailable
            )
            XCTAssertEqual(try scalar(databaseURL, "SELECT COUNT(*) FROM models;"), 0)
        }
    }

    func testDurableJobsRestoreLatestSnapshotAndCascadeEventsOnRemoval() throws {
        try withRepository { artifactRepository, databaseURL in
            let jobs = artifactRepository.makeJobRepository()
            let id = JobID()
            let created = Date(timeIntervalSince1970: 500)
            try jobs.upsert(DurableJobRecord(
                id: id,
                type: "model_download",
                state: .running,
                progress: 0.25,
                payloadJSON: "{\"snapshot\":1}",
                createdAt: created,
                startedAt: created,
                updatedAt: created
            ))
            try jobs.upsert(DurableJobRecord(
                id: id,
                type: "model_download",
                state: .paused,
                progress: 0.5,
                payloadJSON: "{\"snapshot\":2}",
                createdAt: created,
                startedAt: created,
                updatedAt: Date(timeIntervalSince1970: 501)
            ))
            try jobs.upsert(DurableJobRecord(
                id: id,
                type: "model_download",
                state: .running,
                progress: 0.3,
                payloadJSON: "{\"snapshot\":\"stale\"}",
                createdAt: created,
                startedAt: created,
                updatedAt: Date(timeIntervalSince1970: 500.5)
            ))

            let reopened = try DurableJobRepository(databaseURL: databaseURL)
            let restored = try XCTUnwrap(reopened.records(type: "model_download").first)
            XCTAssertEqual(restored.id, id)
            XCTAssertEqual(restored.state, .paused)
            XCTAssertEqual(restored.progress, 0.5)
            XCTAssertEqual(restored.payloadJSON, "{\"snapshot\":2}")
            XCTAssertEqual(try scalar(databaseURL, "SELECT COUNT(*) FROM job_events;"), 2)

            try reopened.remove([id])
            XCTAssertEqual(try scalar(databaseURL, "SELECT COUNT(*) FROM jobs;"), 0)
            XCTAssertEqual(try scalar(databaseURL, "SELECT COUNT(*) FROM job_events;"), 0)
        }
    }
}

private extension PersistenceRepositoryTests {
    func withRepository(
        _ body: (ModelArtifactRepository, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersistenceRepositoryTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("models.sqlite3")
        try body(try ModelArtifactRepository(databaseURL: databaseURL), databaseURL)
    }

    func execute(_ databaseURL: URL, _ sql: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database
        else { throw RepositoryTestError.open }
        defer { sqlite3_close_v2(database) }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        defer { sqlite3_free(message) }
        guard result == SQLITE_OK else {
            throw RepositoryTestError.sqlite(message.map { String(cString: $0) } ?? "code \(result)")
        }
    }

    func scalar(_ databaseURL: URL, _ sql: String) throws -> Int {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else { throw RepositoryTestError.open }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RepositoryTestError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw RepositoryTestError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func text(_ databaseURL: URL, _ sql: String) throws -> String {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database
        else { throw RepositoryTestError.open }
        defer { sqlite3_close_v2(database) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw RepositoryTestError.sqlite(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let value = sqlite3_column_text(statement, 0)
        else { throw RepositoryTestError.sqlite(String(cString: sqlite3_errmsg(database))) }
        return String(cString: value)
    }
}

private enum RepositoryTestError: Error {
    case open
    case sqlite(String)
}
