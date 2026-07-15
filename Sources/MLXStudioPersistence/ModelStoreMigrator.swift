import Foundation
import MLXStudioDomain
import SQLite3

public enum ModelStoreMigrationError: Error, Equatable, Sendable, CustomStringConvertible {
    case newerSchema(Int)
    case unsupportedTargetVersion(Int)
    case sqlite(code: Int32, message: String, statement: String)

    public var description: String {
        switch self {
        case .newerSchema(let version):
            return "models.sqlite3 schema version \(version) is newer than supported"
        case .unsupportedTargetVersion(let version):
            return "models.sqlite3 target schema version \(version) is unsupported"
        case .sqlite(let code, let message, let statement):
            return "SQLite error \(code): \(message) [\(statement)]"
        }
    }
}

/// Transactional schema migration for the canonical project/artifact store.
public enum ModelStoreMigrator {
    public static let latestVersion = 7

    public static func migrate(_ database: OpaquePointer) throws {
        try migrate(database, through: latestVersion, afterApplyingVersion: nil)
    }

    static func migrate(
        _ database: OpaquePointer,
        through targetVersion: Int = latestVersion,
        afterApplyingVersion: ((Int) throws -> Void)?
    ) throws {
        try execute(database, "PRAGMA foreign_keys=ON;")
        let initialVersion = try userVersion(database)
        guard initialVersion <= latestVersion else {
            throw ModelStoreMigrationError.newerSchema(initialVersion)
        }
        guard targetVersion >= initialVersion, targetVersion <= latestVersion else {
            throw ModelStoreMigrationError.unsupportedTargetVersion(targetVersion)
        }

        var version = initialVersion
        while version < targetVersion {
            let nextVersion = version + 1
            // Version 3 declares the final forward references so the latest schema
            // has real SQLite constraints. Their parent tables are introduced in
            // versions 5-7. Version 4 only writes NULL to those forward-reference
            // columns, so suspend enforcement for this compatibility backfill and
            // restore it before any later schema becomes observable.
            let suspendsForwardForeignKeys = nextVersion == 4
            if suspendsForwardForeignKeys {
                try execute(database, "PRAGMA foreign_keys=OFF;")
            }
            try execute(database, "BEGIN IMMEDIATE;")
            do {
                try apply(nextVersion, to: database)
                try afterApplyingVersion?(nextVersion)
                try execute(database, "PRAGMA user_version=\(nextVersion);")
                try execute(database, "COMMIT;")
                if suspendsForwardForeignKeys {
                    try execute(database, "PRAGMA foreign_keys=ON;")
                }
                version = nextVersion
            } catch {
                try? execute(database, "ROLLBACK;")
                if suspendsForwardForeignKeys {
                    try? execute(database, "PRAGMA foreign_keys=ON;")
                }
                throw error
            }
        }
    }

    private static func apply(_ version: Int, to database: OpaquePointer) throws {
        switch version {
        case 1: try createLegacyModelIndex(in: database)
        case 2: try addLegacyCapabilities(in: database)
        case 3: try createArtifactSchema(in: database)
        case 4: try backfillLegacyModels(in: database)
        case 5: try createOptimizationSchema(in: database)
        case 6: try createEvaluationSchema(in: database)
        case 7: try createJobSchema(in: database)
        default: preconditionFailure("Unexpected model-store migration \(version)")
        }
    }
}

// MARK: - Schema versions

private extension ModelStoreMigrator {
    static func createLegacyModelIndex(in database: OpaquePointer) throws {
        try execute(database, """
        CREATE TABLE IF NOT EXISTS models (
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
        CREATE INDEX IF NOT EXISTS idx_models_family ON models(family);
        CREATE INDEX IF NOT EXISTS idx_models_modality ON models(modality);
        CREATE TABLE IF NOT EXISTS user_dirs (
            url TEXT PRIMARY KEY,
            added_at REAL NOT NULL
        );
        """)
    }

    static func addLegacyCapabilities(in database: OpaquePointer) throws {
        guard try !columnExists("capabilities_json", in: "models", database: database) else {
            return
        }
        try execute(
            database,
            "ALTER TABLE models ADD COLUMN capabilities_json TEXT NOT NULL DEFAULT '{}';"
        )
    }

    static func createArtifactSchema(in database: OpaquePointer) throws {
        try execute(database, """
        CREATE TABLE IF NOT EXISTS model_sources (
            id TEXT PRIMARY KEY,
            legacy_model_id TEXT UNIQUE,
            local_url TEXT,
            repository_id TEXT,
            revision TEXT,
            architecture TEXT,
            parameter_count INTEGER,
            active_parameter_count INTEGER,
            expert_topology_json TEXT NOT NULL DEFAULT '{}',
            capabilities_json TEXT NOT NULL DEFAULT '{}',
            source_format TEXT NOT NULL,
            source_precision TEXT,
            created_at REAL NOT NULL,
            CHECK (local_url IS NOT NULL OR repository_id IS NOT NULL)
        );

        CREATE TABLE IF NOT EXISTS model_projects (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            source_id TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            FOREIGN KEY(source_id) REFERENCES model_sources(id)
        );
        CREATE INDEX IF NOT EXISTS idx_model_projects_source ON model_projects(source_id);
        CREATE INDEX IF NOT EXISTS idx_model_projects_updated ON model_projects(updated_at);

        CREATE TABLE IF NOT EXISTS hardware_profiles (
            id TEXT PRIMARY KEY,
            chip_name TEXT NOT NULL,
            unified_memory_bytes INTEGER NOT NULL,
            os_version TEXT NOT NULL,
            gpu_core_count INTEGER,
            cpu_core_count INTEGER,
            available_disk_bytes INTEGER,
            captured_at REAL NOT NULL,
            profile_hash TEXT NOT NULL UNIQUE
        );

        CREATE TABLE IF NOT EXISTS model_artifacts (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            parent_artifact_id TEXT,
            legacy_model_id TEXT UNIQUE,
            name TEXT NOT NULL,
            local_url TEXT NOT NULL,
            canonical_path TEXT NOT NULL UNIQUE,
            format TEXT NOT NULL,
            precision TEXT,
            state TEXT NOT NULL CHECK(state IN ('discovered','importing','ready','unavailable','quarantined')),
            manifest_id TEXT UNIQUE,
            verification_status TEXT NOT NULL CHECK(verification_status IN ('unknown','pending','passed','failed')),
            content_hash TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            FOREIGN KEY(project_id) REFERENCES model_projects(id),
            FOREIGN KEY(parent_artifact_id) REFERENCES model_artifacts(id),
            CHECK(parent_artifact_id IS NULL OR parent_artifact_id <> id)
        );
        CREATE INDEX IF NOT EXISTS idx_model_artifacts_project ON model_artifacts(project_id);
        CREATE INDEX IF NOT EXISTS idx_model_artifacts_parent ON model_artifacts(parent_artifact_id);
        CREATE INDEX IF NOT EXISTS idx_model_artifacts_hash ON model_artifacts(content_hash);
        CREATE INDEX IF NOT EXISTS idx_model_artifacts_state ON model_artifacts(state);

        CREATE TABLE IF NOT EXISTS artifact_manifests (
            id TEXT PRIMARY KEY,
            artifact_id TEXT NOT NULL UNIQUE,
            schema_version INTEGER NOT NULL,
            source_revision TEXT,
            runtime_version TEXT,
            optimizer_version TEXT,
            kernel_version TEXT,
            pruning_plan_id TEXT,
            quantization_recipe_id TEXT,
            calibration_suite_id TEXT,
            hardware_profile_id TEXT,
            manifest_hash TEXT NOT NULL UNIQUE,
            payload_json TEXT NOT NULL DEFAULT '{}',
            created_at REAL NOT NULL,
            FOREIGN KEY(artifact_id) REFERENCES model_artifacts(id) ON DELETE CASCADE,
            FOREIGN KEY(pruning_plan_id) REFERENCES optimization_plans(id),
            FOREIGN KEY(quantization_recipe_id) REFERENCES quantization_recipes(id),
            FOREIGN KEY(calibration_suite_id) REFERENCES evaluation_suites(id),
            FOREIGN KEY(hardware_profile_id) REFERENCES hardware_profiles(id)
        );

        CREATE TABLE IF NOT EXISTS artifact_source_files (
            manifest_id TEXT NOT NULL,
            relative_path TEXT NOT NULL,
            size_bytes INTEGER NOT NULL,
            sha256 TEXT NOT NULL,
            PRIMARY KEY(manifest_id, relative_path),
            FOREIGN KEY(manifest_id) REFERENCES artifact_manifests(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS artifact_lineage (
            parent_artifact_id TEXT NOT NULL,
            child_artifact_id TEXT NOT NULL,
            operation TEXT NOT NULL,
            job_id TEXT,
            manifest_id TEXT,
            created_at REAL NOT NULL,
            PRIMARY KEY(parent_artifact_id, child_artifact_id, operation),
            FOREIGN KEY(parent_artifact_id) REFERENCES model_artifacts(id),
            FOREIGN KEY(child_artifact_id) REFERENCES model_artifacts(id),
            FOREIGN KEY(job_id) REFERENCES jobs(id),
            FOREIGN KEY(manifest_id) REFERENCES artifact_manifests(id),
            CHECK(parent_artifact_id <> child_artifact_id)
        );
        CREATE INDEX IF NOT EXISTS idx_artifact_lineage_child ON artifact_lineage(child_artifact_id);
        """)
    }

    static func createOptimizationSchema(in database: OpaquePointer) throws {
        try execute(database, """
        CREATE TABLE IF NOT EXISTS quantization_recipes (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            technology TEXT NOT NULL CHECK(technology IN ('jang','jangtq')),
            profile TEXT NOT NULL,
            tensor_role_rules_json TEXT NOT NULL DEFAULT '{}',
            calibration_suite_id TEXT,
            schema_version INTEGER NOT NULL,
            created_at REAL NOT NULL,
            FOREIGN KEY(calibration_suite_id) REFERENCES evaluation_suites(id)
        );

        CREATE TABLE IF NOT EXISTS optimization_plans (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            source_artifact_id TEXT NOT NULL,
            objective_json TEXT NOT NULL,
            pruning_configuration_json TEXT NOT NULL,
            quantization_recipe_id TEXT,
            estimated_result_json TEXT,
            validation_status TEXT NOT NULL CHECK(validation_status IN ('unchecked','valid','invalid')),
            schema_version INTEGER NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            FOREIGN KEY(project_id) REFERENCES model_projects(id),
            FOREIGN KEY(source_artifact_id) REFERENCES model_artifacts(id),
            FOREIGN KEY(quantization_recipe_id) REFERENCES quantization_recipes(id)
        );
        CREATE INDEX IF NOT EXISTS idx_optimization_plans_project ON optimization_plans(project_id);
        CREATE INDEX IF NOT EXISTS idx_optimization_plans_source ON optimization_plans(source_artifact_id);

        CREATE TABLE IF NOT EXISTS analysis_runs (
            id TEXT PRIMARY KEY,
            project_id TEXT NOT NULL,
            artifact_id TEXT NOT NULL,
            strategy_identifier TEXT NOT NULL,
            strategy_version TEXT NOT NULL,
            suite_id TEXT NOT NULL,
            job_id TEXT,
            status TEXT NOT NULL,
            result_json TEXT,
            started_at REAL NOT NULL,
            ended_at REAL,
            FOREIGN KEY(project_id) REFERENCES model_projects(id),
            FOREIGN KEY(artifact_id) REFERENCES model_artifacts(id),
            FOREIGN KEY(suite_id) REFERENCES evaluation_suites(id),
            FOREIGN KEY(job_id) REFERENCES jobs(id)
        );
        CREATE INDEX IF NOT EXISTS idx_analysis_runs_project ON analysis_runs(project_id);
        CREATE INDEX IF NOT EXISTS idx_analysis_runs_artifact ON analysis_runs(artifact_id);

        CREATE TABLE IF NOT EXISTS expert_evidence (
            analysis_run_id TEXT NOT NULL,
            layer INTEGER NOT NULL,
            expert INTEGER NOT NULL,
            percentile REAL,
            route_count INTEGER,
            gate_mass REAL,
            contribution REAL,
            confidence REAL,
            domain_scores_json TEXT NOT NULL DEFAULT '{}',
            warnings_json TEXT NOT NULL DEFAULT '[]',
            PRIMARY KEY(analysis_run_id, layer, expert),
            FOREIGN KEY(analysis_run_id) REFERENCES analysis_runs(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS expert_directives (
            plan_id TEXT NOT NULL,
            layer INTEGER NOT NULL,
            expert INTEGER NOT NULL,
            directive TEXT NOT NULL CHECK(directive IN ('auto','keep','remove')),
            updated_at REAL NOT NULL,
            PRIMARY KEY(plan_id, layer, expert),
            FOREIGN KEY(plan_id) REFERENCES optimization_plans(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS build_runs (
            id TEXT PRIMARY KEY,
            plan_id TEXT NOT NULL,
            job_id TEXT NOT NULL UNIQUE,
            output_artifact_id TEXT,
            worker_identifier TEXT NOT NULL,
            tool_versions_json TEXT NOT NULL DEFAULT '{}',
            command_manifest_json TEXT NOT NULL,
            partial_output_policy TEXT NOT NULL,
            status TEXT NOT NULL,
            started_at REAL NOT NULL,
            ended_at REAL,
            FOREIGN KEY(plan_id) REFERENCES optimization_plans(id),
            FOREIGN KEY(job_id) REFERENCES jobs(id),
            FOREIGN KEY(output_artifact_id) REFERENCES model_artifacts(id)
        );

        CREATE TABLE IF NOT EXISTS verification_reports (
            id TEXT PRIMARY KEY,
            artifact_id TEXT NOT NULL,
            job_id TEXT,
            status TEXT NOT NULL,
            checks_json TEXT NOT NULL,
            diagnostic_export_url TEXT,
            runtime_smoke_generation_id TEXT,
            created_at REAL NOT NULL,
            FOREIGN KEY(artifact_id) REFERENCES model_artifacts(id),
            FOREIGN KEY(job_id) REFERENCES jobs(id)
        );
        CREATE INDEX IF NOT EXISTS idx_verification_reports_artifact ON verification_reports(artifact_id);
        """)
    }

    static func createEvaluationSchema(in database: OpaquePointer) throws {
        try execute(database, """
        CREATE TABLE IF NOT EXISTS evaluation_suites (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            revision TEXT NOT NULL,
            tags_json TEXT NOT NULL DEFAULT '[]',
            suite_hash TEXT NOT NULL UNIQUE,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(name, revision)
        );

        CREATE TABLE IF NOT EXISTS evaluation_cases (
            id TEXT PRIMARY KEY,
            suite_id TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            prompt TEXT NOT NULL,
            system_prompt TEXT,
            domain TEXT,
            tags_json TEXT NOT NULL DEFAULT '[]',
            expected_kind TEXT,
            expected_value TEXT,
            generation_configuration_json TEXT NOT NULL,
            weight REAL NOT NULL DEFAULT 1,
            UNIQUE(suite_id, ordinal),
            FOREIGN KEY(suite_id) REFERENCES evaluation_suites(id) ON DELETE CASCADE
        );

        CREATE TABLE IF NOT EXISTS evaluation_runs (
            id TEXT PRIMARY KEY,
            suite_id TEXT NOT NULL,
            hardware_profile_id TEXT,
            runtime_version TEXT,
            kernel_version TEXT,
            execution_order_json TEXT NOT NULL,
            status TEXT NOT NULL CHECK(status IN ('pending','running','completed','cancelled','failed')),
            started_at REAL NOT NULL,
            ended_at REAL,
            FOREIGN KEY(suite_id) REFERENCES evaluation_suites(id),
            FOREIGN KEY(hardware_profile_id) REFERENCES hardware_profiles(id)
        );

        CREATE TABLE IF NOT EXISTS evaluation_run_artifacts (
            run_id TEXT NOT NULL,
            artifact_id TEXT NOT NULL,
            blind_label TEXT NOT NULL,
            artifact_hash TEXT,
            PRIMARY KEY(run_id, artifact_id),
            UNIQUE(run_id, blind_label),
            FOREIGN KEY(run_id) REFERENCES evaluation_runs(id) ON DELETE CASCADE,
            FOREIGN KEY(artifact_id) REFERENCES model_artifacts(id)
        );

        CREATE TABLE IF NOT EXISTS evaluation_results (
            id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL,
            case_id TEXT NOT NULL,
            artifact_id TEXT NOT NULL,
            generation_id TEXT NOT NULL,
            output_text TEXT NOT NULL,
            score_kind TEXT,
            score_value REAL,
            score_payload_json TEXT,
            runtime_metrics_json TEXT NOT NULL,
            error_json TEXT,
            created_at REAL NOT NULL,
            UNIQUE(run_id, case_id, artifact_id),
            FOREIGN KEY(run_id) REFERENCES evaluation_runs(id) ON DELETE CASCADE,
            FOREIGN KEY(case_id) REFERENCES evaluation_cases(id),
            FOREIGN KEY(artifact_id) REFERENCES model_artifacts(id)
        );

        CREATE TABLE IF NOT EXISTS human_judgments (
            id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL,
            case_id TEXT NOT NULL,
            assignment_json TEXT NOT NULL,
            choice TEXT,
            notes TEXT,
            revealed_at REAL,
            created_at REAL NOT NULL,
            FOREIGN KEY(run_id) REFERENCES evaluation_runs(id) ON DELETE CASCADE,
            FOREIGN KEY(case_id) REFERENCES evaluation_cases(id)
        );
        CREATE INDEX IF NOT EXISTS idx_evaluation_cases_suite ON evaluation_cases(suite_id);
        CREATE INDEX IF NOT EXISTS idx_evaluation_runs_suite ON evaluation_runs(suite_id);
        CREATE INDEX IF NOT EXISTS idx_evaluation_results_run ON evaluation_results(run_id);
        """)
    }

    static func createJobSchema(in database: OpaquePointer) throws {
        try execute(database, """
        CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            project_id TEXT,
            artifact_id TEXT,
            state TEXT NOT NULL CHECK(state IN ('pending','running','paused','completed','cancelled','failed')),
            progress REAL NOT NULL DEFAULT 0 CHECK(progress >= 0 AND progress <= 1),
            current_stage TEXT,
            log_url TEXT,
            diagnostic_export_url TEXT,
            peak_memory_bytes INTEGER,
            error_json TEXT,
            recovery_instructions TEXT,
            created_at REAL NOT NULL,
            started_at REAL,
            ended_at REAL,
            updated_at REAL NOT NULL,
            FOREIGN KEY(project_id) REFERENCES model_projects(id),
            FOREIGN KEY(artifact_id) REFERENCES model_artifacts(id)
        );

        CREATE TABLE IF NOT EXISTS job_events (
            job_id TEXT NOT NULL,
            sequence INTEGER NOT NULL,
            event_type TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            created_at REAL NOT NULL,
            PRIMARY KEY(job_id, sequence),
            FOREIGN KEY(job_id) REFERENCES jobs(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_jobs_project ON jobs(project_id);
        CREATE INDEX IF NOT EXISTS idx_jobs_artifact ON jobs(artifact_id);
        CREATE INDEX IF NOT EXISTS idx_jobs_state ON jobs(state);
        """)
    }
}

// MARK: - Legacy backfill

private extension ModelStoreMigrator {
    struct LegacyModel {
        let id: String
        let canonicalPath: String
        let displayName: String
        let family: String
        let isJANG: Bool
        let isJANGTQ: Bool
        let quantBits: Int?
        let detectedAt: Double
        let capabilitiesJSON: String
    }

    static func backfillLegacyModels(in database: OpaquePointer) throws {
        let legacyModels = try readLegacyModels(from: database)
        for model in legacyModels {
            if try scalarInt(
                database,
                "SELECT COUNT(*) FROM model_artifacts WHERE legacy_model_id=?;",
                bindings: [.text(model.id)]
            ) > 0 {
                continue
            }

            let sourceID = ModelSourceID().rawValue
            let projectID = ModelProjectID().rawValue
            let artifactID = ModelArtifactID().rawValue
            let manifestID = ArtifactManifestID().rawValue
            let format = model.isJANGTQ ? "jangtq" : (model.isJANG ? "jang" : "mlx")
            let precision = model.quantBits.map { "\($0)-bit" }
            let payload = try legacyManifestPayload(modelID: model.id)

            try execute(database, """
            INSERT INTO model_sources (
                id, legacy_model_id, local_url, repository_id, revision, architecture,
                parameter_count, active_parameter_count, expert_topology_json,
                capabilities_json, source_format, source_precision, created_at
            ) VALUES (?, ?, ?, NULL, NULL, ?, NULL, NULL, '{}', ?, ?, ?, ?);
            """, bindings: [
                .text(sourceID), .text(model.id), .text(model.canonicalPath),
                .text(model.family), .text(model.capabilitiesJSON), .text(format),
                precision.map(SQLiteValue.text) ?? .null, .real(model.detectedAt),
            ])

            try execute(database, """
            INSERT INTO model_projects (id, name, source_id, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?);
            """, bindings: [
                .text(projectID), .text(model.displayName), .text(sourceID),
                .real(model.detectedAt), .real(model.detectedAt),
            ])

            try execute(database, """
            INSERT INTO model_artifacts (
                id, project_id, parent_artifact_id, legacy_model_id, name, local_url,
                canonical_path, format, precision, state, manifest_id,
                verification_status, content_hash, created_at, updated_at
            ) VALUES (?, ?, NULL, ?, ?, ?, ?, ?, ?, 'discovered', ?, 'unknown', NULL, ?, ?);
            """, bindings: [
                .text(artifactID), .text(projectID), .text(model.id),
                .text(model.displayName), .text(model.canonicalPath),
                .text(model.canonicalPath), .text(format),
                precision.map(SQLiteValue.text) ?? .null, .text(manifestID),
                .real(model.detectedAt), .real(model.detectedAt),
            ])

            try execute(database, """
            INSERT INTO artifact_manifests (
                id, artifact_id, schema_version, source_revision, runtime_version,
                optimizer_version, kernel_version, pruning_plan_id,
                quantization_recipe_id, calibration_suite_id, hardware_profile_id,
                manifest_hash, payload_json, created_at
            ) VALUES (?, ?, 1, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, ?, ?, ?);
            """, bindings: [
                .text(manifestID), .text(artifactID), .text("legacy:\(model.id)"),
                .text(payload), .real(model.detectedAt),
            ])
        }
    }

    static func readLegacyModels(from database: OpaquePointer) throws -> [LegacyModel] {
        let sql = """
        SELECT id, canonical_path, display_name, family, is_jang, is_mxtq,
               quant_bits, detected_at, capabilities_json
        FROM models ORDER BY id;
        """
        var statement: OpaquePointer?
        try prepare(database, sql, statement: &statement)
        defer { sqlite3_finalize(statement) }

        var models: [LegacyModel] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw sqliteError(database, code: result, statement: sql)
            }
            models.append(LegacyModel(
                id: text(statement, column: 0),
                canonicalPath: text(statement, column: 1),
                displayName: text(statement, column: 2),
                family: text(statement, column: 3),
                isJANG: sqlite3_column_int(statement, 4) != 0,
                isJANGTQ: sqlite3_column_int(statement, 5) != 0,
                quantBits: sqlite3_column_type(statement, 6) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int(statement, 6)),
                detectedAt: sqlite3_column_double(statement, 7),
                capabilitiesJSON: text(statement, column: 8)
            ))
        }
        return models
    }

    static func legacyManifestPayload(modelID: String) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: ["imported_from_legacy_model_id": modelID],
            options: [.sortedKeys]
        )
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - SQLite helpers

private extension ModelStoreMigrator {
    enum SQLiteValue {
        case text(String)
        case real(Double)
        case null
    }

    static func userVersion(_ database: OpaquePointer) throws -> Int {
        try scalarInt(database, "PRAGMA user_version;")
    }

    static func columnExists(
        _ column: String,
        in table: String,
        database: OpaquePointer
    ) throws -> Bool {
        let sql = "PRAGMA table_info(\(table));"
        var statement: OpaquePointer?
        try prepare(database, sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        while true {
            let result = sqlite3_step(statement)
            switch result {
            case SQLITE_ROW:
                if text(statement, column: 1) == column { return true }
            case SQLITE_DONE:
                return false
            default:
                throw sqliteError(database, code: result, statement: sql)
            }
        }
    }

    static func scalarInt(
        _ database: OpaquePointer,
        _ sql: String,
        bindings: [SQLiteValue] = []
    ) throws -> Int {
        var statement: OpaquePointer?
        try prepare(database, sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement, database: database, sql: sql)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            throw sqliteError(database, code: result, statement: sql)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    static func execute(
        _ database: OpaquePointer,
        _ sql: String,
        bindings: [SQLiteValue] = []
    ) throws {
        if bindings.isEmpty {
            var error: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database, sql, nil, nil, &error)
            guard result == SQLITE_OK else {
                let message = error.map { String(cString: $0) }
                    ?? String(cString: sqlite3_errmsg(database))
                sqlite3_free(error)
                throw ModelStoreMigrationError.sqlite(
                    code: result,
                    message: message,
                    statement: sql
                )
            }
            return
        }

        var statement: OpaquePointer?
        try prepare(database, sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement, database: database, sql: sql)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw sqliteError(database, code: result, statement: sql)
        }
    }

    static func prepare(
        _ database: OpaquePointer,
        _ sql: String,
        statement: inout OpaquePointer?
    ) throws {
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw sqliteError(database, code: result, statement: sql)
        }
    }

    static func bind(
        _ bindings: [SQLiteValue],
        to statement: OpaquePointer?,
        database: OpaquePointer,
        sql: String
    ) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .text(let string):
                result = sqlite3_bind_text(statement, index, string, -1, sqliteTransient)
            case .real(let double):
                result = sqlite3_bind_double(statement, index, double)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else {
                throw sqliteError(database, code: result, statement: sql)
            }
        }
    }

    static func sqliteError(
        _ database: OpaquePointer,
        code: Int32,
        statement: String
    ) -> ModelStoreMigrationError {
        .sqlite(
            code: code,
            message: String(cString: sqlite3_errmsg(database)),
            statement: statement
        )
    }

    static func text(_ statement: OpaquePointer?, column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
