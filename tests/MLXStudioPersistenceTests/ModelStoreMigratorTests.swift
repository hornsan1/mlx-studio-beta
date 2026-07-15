import Foundation
import SQLite3
import XCTest
@testable import MLXStudioPersistence

final class ModelStoreMigratorTests: XCTestCase {
    func testEmptyDatabaseMigratesToLatestSchema() throws {
        try withDatabase { database in
            try ModelStoreMigrator.migrate(database)

            XCTAssertEqual(try scalarInt(database, "PRAGMA user_version;"), 7)
            XCTAssertEqual(try scalarInt(database, "PRAGMA foreign_keys;"), 1)
            XCTAssertEqual(try scalarInt(database, "SELECT COUNT(*) FROM pragma_foreign_key_check;"), 0)
            XCTAssertEqual(
                try tableNames(database),
                [
                    "analysis_runs", "artifact_lineage", "artifact_manifests",
                    "artifact_source_files", "build_runs", "evaluation_cases",
                    "evaluation_results", "evaluation_run_artifacts", "evaluation_runs",
                    "evaluation_suites", "expert_directives", "expert_evidence",
                    "hardware_profiles", "human_judgments", "job_events", "jobs",
                    "model_artifacts", "model_projects", "model_sources", "models",
                    "optimization_plans", "quantization_recipes", "user_dirs",
                    "verification_reports",
                ]
            )
            XCTAssertEqual(
                try foreignKeyTargets(database, table: "analysis_runs"),
                ["evaluation_suites", "jobs", "model_artifacts", "model_projects"]
            )
            XCTAssertEqual(
                try foreignKeyTargets(database, table: "artifact_manifests"),
                [
                    "evaluation_suites", "hardware_profiles", "model_artifacts",
                    "optimization_plans", "quantization_recipes",
                ]
            )
            XCTAssertEqual(
                try foreignKeyTargets(database, table: "build_runs"),
                ["jobs", "model_artifacts", "optimization_plans"]
            )
        }
    }

    func testVersionOneDatabasePreservesAndBackfillsLegacyModel() throws {
        try withDatabase { database in
            try createLegacySchema(database, version: 1)
            try execute(database, """
            INSERT INTO models (
                id, canonical_path, display_name, family, modality, total_size_bytes,
                is_jang, is_mxtq, quant_bits, detected_at, source
            ) VALUES (
                'legacy-mlx', '/models/legacy-mlx', 'Legacy MLX', 'qwen', 'text', 42,
                0, 0, NULL, 1000, 'scan'
            );
            """)

            try ModelStoreMigrator.migrate(database)

            XCTAssertEqual(try scalarInt(database, "PRAGMA user_version;"), 7)
            XCTAssertEqual(try scalarInt(database, "SELECT COUNT(*) FROM models;"), 1)
            XCTAssertEqual(
                try scalarText(database, "SELECT capabilities_json FROM models WHERE id='legacy-mlx';"),
                "{}"
            )
            XCTAssertEqual(
                try scalarText(database, "SELECT format FROM model_artifacts WHERE legacy_model_id='legacy-mlx';"),
                "mlx"
            )
            XCTAssertEqual(
                try scalarText(database, "SELECT state FROM model_artifacts WHERE legacy_model_id='legacy-mlx';"),
                "discovered"
            )
            XCTAssertEqual(
                try scalarText(database, "SELECT source_format FROM model_sources WHERE legacy_model_id='legacy-mlx';"),
                "mlx"
            )
            XCTAssertEqual(try scalarInt(database, "SELECT COUNT(*) FROM artifact_manifests;"), 1)
        }
    }

    func testVersionTwoDatabaseBackfillsJANGFormatsAndIsIdempotent() throws {
        try withDatabase { database in
            try createLegacySchema(database, version: 2)
            try execute(database, """
            INSERT INTO models VALUES
                ('legacy-jang', '/models/jang', 'JANG', 'qwen', 'text', 100, 1, 0, 4, 1001, 'scan', '{"chat":true}'),
                ('legacy-jangtq', '/models/jangtq', 'JANGTQ', 'qwen', 'text', 90, 1, 1, 3, 1002, 'scan', '{}');
            """)

            try ModelStoreMigrator.migrate(database)
            let firstArtifactID = try scalarText(
                database,
                "SELECT id FROM model_artifacts WHERE legacy_model_id='legacy-jang';"
            )
            try ModelStoreMigrator.migrate(database)

            XCTAssertEqual(try scalarInt(database, "SELECT COUNT(*) FROM model_sources;"), 2)
            XCTAssertEqual(try scalarInt(database, "SELECT COUNT(*) FROM model_projects;"), 2)
            XCTAssertEqual(try scalarInt(database, "SELECT COUNT(*) FROM model_artifacts;"), 2)
            XCTAssertEqual(try scalarInt(database, "SELECT COUNT(*) FROM artifact_manifests;"), 2)
            XCTAssertEqual(
                try scalarText(database, "SELECT format FROM model_artifacts WHERE legacy_model_id='legacy-jang';"),
                "jang"
            )
            XCTAssertEqual(
                try scalarText(database, "SELECT format FROM model_artifacts WHERE legacy_model_id='legacy-jangtq';"),
                "jangtq"
            )
            XCTAssertEqual(
                try scalarText(database, "SELECT precision FROM model_artifacts WHERE legacy_model_id='legacy-jangtq';"),
                "3-bit"
            )
            XCTAssertEqual(
                try scalarText(database, "SELECT id FROM model_artifacts WHERE legacy_model_id='legacy-jang';"),
                firstArtifactID
            )
        }
    }

    func testInjectedFailureRollsBackOneVersionAndRetryCompletes() throws {
        try withDatabase { database in
            XCTAssertThrowsError(
                try ModelStoreMigrator.migrate(database) { version in
                    if version == 3 { throw InjectedFailure() }
                }
            )

            XCTAssertEqual(try scalarInt(database, "PRAGMA user_version;"), 2)
            XCTAssertFalse(try tableExists(database, "model_artifacts"))

            try ModelStoreMigrator.migrate(database)
            XCTAssertEqual(try scalarInt(database, "PRAGMA user_version;"), 7)
            XCTAssertTrue(try tableExists(database, "model_artifacts"))
        }
    }

    func testConstraintFailureRollsBackBackfillAndRetryIsClean() throws {
        try withDatabase { database in
            try createLegacySchema(database, version: 2)
            try execute(database, """
            INSERT INTO models VALUES
                ('legacy-collision', '/models/collision', 'Collision', 'qwen', 'text', 10, 0, 0, NULL, 1003, 'scan', '{}');
            """)
            try ModelStoreMigrator.migrate(database, through: 3, afterApplyingVersion: nil)
            try insertConflictingArtifact(database)

            XCTAssertThrowsError(
                try ModelStoreMigrator.migrate(database, through: 4, afterApplyingVersion: nil)
            )
            XCTAssertEqual(try scalarInt(database, "PRAGMA user_version;"), 3)
            XCTAssertEqual(try scalarInt(database, "PRAGMA foreign_keys;"), 1)
            XCTAssertEqual(
                try scalarInt(database, "SELECT COUNT(*) FROM model_sources WHERE legacy_model_id='legacy-collision';"),
                0
            )

            try execute(database, "PRAGMA foreign_keys=OFF;")
            try execute(database, "DELETE FROM model_artifacts WHERE id='collision-artifact';")
            try execute(database, "DELETE FROM model_projects WHERE id='collision-project';")
            try execute(database, "DELETE FROM model_sources WHERE id='collision-source';")
            try execute(database, "PRAGMA foreign_keys=ON;")
            try ModelStoreMigrator.migrate(database)

            XCTAssertEqual(try scalarInt(database, "PRAGMA user_version;"), 7)
            XCTAssertEqual(
                try scalarInt(database, "SELECT COUNT(*) FROM model_artifacts WHERE legacy_model_id='legacy-collision';"),
                1
            )
        }
    }

    func testDuplicateLegacyIdentifierRollsBackAndRetryIsClean() throws {
        try withDatabase { database in
            try createLegacySchema(database, version: 2)
            try execute(database, """
            INSERT INTO models VALUES
                ('legacy-duplicate', '/models/legacy-duplicate', 'Duplicate', 'qwen', 'text', 10, 0, 0, NULL, 1005, 'scan', '{}');
            """)
            try ModelStoreMigrator.migrate(database, through: 3, afterApplyingVersion: nil)
            try execute(database, """
            INSERT INTO model_sources (
                id, legacy_model_id, local_url, source_format, created_at
            ) VALUES (
                'duplicate-source', 'legacy-duplicate', '/models/other', 'mlx', 1
            );
            """)

            XCTAssertThrowsError(
                try ModelStoreMigrator.migrate(database, through: 4, afterApplyingVersion: nil)
            )
            XCTAssertEqual(try scalarInt(database, "PRAGMA user_version;"), 3)
            XCTAssertEqual(try scalarInt(database, "PRAGMA foreign_keys;"), 1)
            XCTAssertEqual(try scalarInt(database, "SELECT COUNT(*) FROM model_artifacts;"), 0)

            try execute(database, "DELETE FROM model_sources WHERE id='duplicate-source';")
            try ModelStoreMigrator.migrate(database)
            XCTAssertEqual(
                try scalarInt(database, "SELECT COUNT(*) FROM model_artifacts WHERE legacy_model_id='legacy-duplicate';"),
                1
            )
        }
    }

    func testArtifactAndJobConstraintsAreEnforced() throws {
        try withDatabase { database in
            try createLegacySchema(database, version: 2)
            try execute(database, """
            INSERT INTO models VALUES
                ('legacy-constraints', '/models/constraints', 'Constraints', 'qwen', 'text', 10, 0, 0, NULL, 1004, 'scan', '{}');
            """)
            try ModelStoreMigrator.migrate(database)
            let artifactID = try scalarText(
                database,
                "SELECT id FROM model_artifacts WHERE legacy_model_id='legacy-constraints';"
            )

            XCTAssertEqual(
                executeResult(
                    database,
                    "UPDATE model_artifacts SET parent_artifact_id='\(artifactID)' WHERE id='\(artifactID)';"
                ),
                SQLITE_CONSTRAINT
            )
            XCTAssertEqual(
                executeResult(
                    database,
                    "INSERT INTO jobs (id, type, state, progress, created_at, updated_at) VALUES ('bad-job', 'test', 'pending', 1.5, 1, 1);"
                ),
                SQLITE_CONSTRAINT
            )
            XCTAssertEqual(
                executeResult(
                    database,
                    "INSERT INTO expert_directives (plan_id, layer, expert, directive, updated_at) VALUES ('missing', 0, 0, 'automatic', 1);"
                ),
                SQLITE_CONSTRAINT
            )
        }
    }

    func testNewerDatabaseIsRejectedWithoutMutation() throws {
        try withDatabase { database in
            try execute(database, "PRAGMA user_version=99;")

            XCTAssertThrowsError(try ModelStoreMigrator.migrate(database)) { error in
                XCTAssertEqual(error as? ModelStoreMigrationError, .newerSchema(99))
            }
            XCTAssertEqual(try scalarInt(database, "PRAGMA user_version;"), 99)
            XCTAssertEqual(try tableNames(database), [])
        }
    }

    func testInstalledDatabaseBackupUpgradesWithoutMutatingSourceWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["MLX_STUDIO_INSTALLED_MODELS_DB"] else {
            throw XCTSkip("Set MLX_STUDIO_INSTALLED_MODELS_DB to exercise a read-only installed-store snapshot")
        }
        let url = URL(fileURLWithPath: path)
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: path)
        var source: OpaquePointer?
        let openResult = sqlite3_open_v2(
            path,
            &source,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let source else {
            throw SQLiteTestError(message: "read-only source open failed with SQLite code \(openResult)")
        }
        defer { sqlite3_close_v2(source) }

        let sourceVersion = try scalarInt(source, "PRAGMA user_version;")
        let sourceModelCount = try scalarInt(source, "SELECT COUNT(*) FROM models;")
        try withDatabase { destination in
            try backup(from: source, to: destination)
            try ModelStoreMigrator.migrate(destination)

            XCTAssertEqual(try scalarInt(destination, "PRAGMA user_version;"), 7)
            XCTAssertEqual(try scalarInt(destination, "SELECT COUNT(*) FROM models;"), sourceModelCount)
            XCTAssertEqual(
                try scalarInt(destination, "SELECT COUNT(*) FROM model_artifacts WHERE legacy_model_id IS NOT NULL;"),
                sourceModelCount
            )
            XCTAssertEqual(
                try scalarInt(destination, "SELECT COUNT(*) FROM pragma_foreign_key_check;"),
                0
            )
        }

        XCTAssertLessThanOrEqual(sourceVersion, ModelStoreMigrator.latestVersion)
        XCTAssertEqual(try scalarInt(source, "PRAGMA user_version;"), sourceVersion)
        let attributesAfter = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(
            attributesAfter[.modificationDate] as? Date,
            attributesBefore[.modificationDate] as? Date
        )
        XCTAssertEqual(attributesAfter[.size] as? NSNumber, attributesBefore[.size] as? NSNumber)
    }
}

private struct InjectedFailure: Error {}

private extension ModelStoreMigratorTests {
    func withDatabase(_ body: (OpaquePointer) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MLXStudioPersistenceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("models.sqlite3")
        var database: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let database else {
            throw SQLiteTestError(message: "open failed with SQLite code \(result)")
        }
        defer { sqlite3_close_v2(database) }

        try body(database)
    }

    func createLegacySchema(_ database: OpaquePointer, version: Int) throws {
        try execute(database, """
        CREATE TABLE models (
            id TEXT PRIMARY KEY,
            canonical_path TEXT NOT NULL UNIQUE,
            display_name TEXT NOT NULL,
            family TEXT NOT NULL,
            modality TEXT NOT NULL,
            total_size_bytes INTEGER NOT NULL,
            is_jang INTEGER NOT NULL,
            is_mxtq INTEGER NOT NULL,
            quant_bits INTEGER,
            detected_at REAL NOT NULL,
            source TEXT NOT NULL
        );
        CREATE INDEX idx_models_family ON models(family);
        CREATE INDEX idx_models_modality ON models(modality);
        CREATE TABLE user_dirs (
            url TEXT PRIMARY KEY,
            added_at REAL NOT NULL
        );
        """)
        if version == 2 {
            try execute(
                database,
                "ALTER TABLE models ADD COLUMN capabilities_json TEXT NOT NULL DEFAULT '{}';"
            )
        }
        try execute(database, "PRAGMA user_version=\(version);")
    }

    func insertConflictingArtifact(_ database: OpaquePointer) throws {
        // Build a deliberately inconsistent v3 fixture. Normal application code
        // cannot write artifact rows until the store reaches the latest version.
        try execute(database, "PRAGMA foreign_keys=OFF;")
        defer { try? execute(database, "PRAGMA foreign_keys=ON;") }
        try execute(database, """
        INSERT INTO model_sources (
            id, local_url, source_format, created_at
        ) VALUES (
            'collision-source', '/models/other', 'mlx', 1
        );
        INSERT INTO model_projects (
            id, name, source_id, created_at, updated_at
        ) VALUES (
            'collision-project', 'Collision', 'collision-source', 1, 1
        );
        INSERT INTO model_artifacts (
            id, project_id, name, local_url, canonical_path, format, state,
            verification_status, created_at, updated_at
        ) VALUES (
            'collision-artifact', 'collision-project', 'Collision', '/models/collision',
            '/models/collision', 'mlx', 'ready', 'unknown', 1, 1
        );
        """)
    }

    func execute(_ database: OpaquePointer, _ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        defer { sqlite3_free(error) }
        guard result == SQLITE_OK else {
            throw SQLiteTestError(
                message: error.map { String(cString: $0) } ?? "SQLite code \(result)"
            )
        }
    }

    func executeResult(_ database: OpaquePointer, _ sql: String) -> Int32 {
        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &error)
        sqlite3_free(error)
        return result
    }

    func backup(from source: OpaquePointer, to destination: OpaquePointer) throws {
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw SQLiteTestError(message: String(cString: sqlite3_errmsg(destination)))
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw SQLiteTestError(
                message: "SQLite backup failed with step \(stepResult), finish \(finishResult)"
            )
        }
    }

    func scalarInt(_ database: OpaquePointer, _ sql: String) throws -> Int {
        Int(try scalarInt64(database, sql))
    }

    func scalarInt64(_ database: OpaquePointer, _ sql: String) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteTestError(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteTestError(message: String(cString: sqlite3_errmsg(database)))
        }
        return sqlite3_column_int64(statement, 0)
    }

    func scalarText(_ database: OpaquePointer, _ sql: String) throws -> String {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteTestError(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let value = sqlite3_column_text(statement, 0) else {
            throw SQLiteTestError(message: String(cString: sqlite3_errmsg(database)))
        }
        return String(cString: value)
    }

    func tableExists(_ database: OpaquePointer, _ table: String) throws -> Bool {
        try scalarInt(
            database,
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='\(table)';"
        ) == 1
    }

    func tableNames(_ database: OpaquePointer) throws -> [String] {
        let sql = "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name;"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteTestError(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var names: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let value = sqlite3_column_text(statement, 0) else {
                    throw SQLiteTestError(message: "table name was NULL")
                }
                names.append(String(cString: value))
            case SQLITE_DONE:
                return names
            default:
                throw SQLiteTestError(message: String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    func foreignKeyTargets(_ database: OpaquePointer, table: String) throws -> [String] {
        let sql = "PRAGMA foreign_key_list(\(table));"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLiteTestError(message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }

        var targets: [String] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                guard let value = sqlite3_column_text(statement, 2) else {
                    throw SQLiteTestError(message: "foreign-key target was NULL")
                }
                targets.append(String(cString: value))
            case SQLITE_DONE:
                return targets.sorted()
            default:
                throw SQLiteTestError(message: String(cString: sqlite3_errmsg(database)))
            }
        }
    }
}

private struct SQLiteTestError: Error {
    let message: String
}
