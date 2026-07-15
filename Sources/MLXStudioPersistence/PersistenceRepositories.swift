import Foundation
import MLXStudioDomain
import SQLite3

public enum DerivedArtifactRegistrationError: Error, Equatable, Sendable {
    case inconsistentIdentity
    case invalidManifestEncoding
}

public struct IndexedModelRecord: Codable, Hashable, Sendable {
    public let legacyModelID: String
    public var canonicalURL: URL
    public var displayName: String
    public var family: String
    public var modality: String
    public var totalSizeBytes: Int64
    public var isJANG: Bool
    public var isJANGTQ: Bool
    public var quantizationBits: Int?
    public var detectedAt: Date
    public var source: String
    public var capabilitiesJSON: String

    public init(
        legacyModelID: String,
        canonicalURL: URL,
        displayName: String,
        family: String,
        modality: String,
        totalSizeBytes: Int64,
        isJANG: Bool,
        isJANGTQ: Bool,
        quantizationBits: Int?,
        detectedAt: Date,
        source: String,
        capabilitiesJSON: String
    ) {
        self.legacyModelID = legacyModelID
        self.canonicalURL = canonicalURL
        self.displayName = displayName
        self.family = family
        self.modality = modality
        self.totalSizeBytes = totalSizeBytes
        self.isJANG = isJANG
        self.isJANGTQ = isJANGTQ
        self.quantizationBits = quantizationBits
        self.detectedAt = detectedAt
        self.source = source
        self.capabilitiesJSON = capabilitiesJSON
    }
}

public enum DurableJobState: String, Codable, CaseIterable, Hashable, Sendable {
    case pending
    case running
    case paused
    case completed
    case cancelled
    case failed
}

public struct DurableJobRecord: Codable, Hashable, Sendable {
    public let id: JobID
    public var type: String
    public var projectID: ModelProjectID?
    public var artifactID: ModelArtifactID?
    public var state: DurableJobState
    public var progress: Double
    public var currentStage: String?
    public var peakMemoryBytes: Int64?
    public var errorJSON: String?
    public var recoveryInstructions: String?
    public var payloadJSON: String
    public let createdAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var updatedAt: Date

    public init(
        id: JobID = .init(),
        type: String,
        projectID: ModelProjectID? = nil,
        artifactID: ModelArtifactID? = nil,
        state: DurableJobState = .pending,
        progress: Double = 0,
        currentStage: String? = nil,
        peakMemoryBytes: Int64? = nil,
        errorJSON: String? = nil,
        recoveryInstructions: String? = nil,
        payloadJSON: String = "{}",
        createdAt: Date = .init(),
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        updatedAt: Date = .init()
    ) {
        self.id = id
        self.type = type
        self.projectID = projectID
        self.artifactID = artifactID
        self.state = state
        self.progress = min(max(progress, 0), 1)
        self.currentStage = currentStage
        self.peakMemoryBytes = peakMemoryBytes
        self.errorJSON = errorJSON
        self.recoveryInstructions = recoveryInstructions
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.updatedAt = updatedAt
    }
}

public struct ArtifactBuildRun: Codable, Hashable, Sendable {
    public let id: String
    public let planID: OptimizationPlanID
    public let jobID: JobID
    public let outputArtifactID: ModelArtifactID
    public let workerIdentifier: String
    public let toolVersionsJSON: String
    public let commandManifestJSON: String
    public let partialOutputPolicy: PartialOutputPolicy
    public let status: String
    public let startedAt: Date
    public let endedAt: Date

    public init(
        id: String = UUID().uuidString,
        planID: OptimizationPlanID,
        jobID: JobID,
        outputArtifactID: ModelArtifactID,
        workerIdentifier: String,
        toolVersionsJSON: String,
        commandManifestJSON: String,
        partialOutputPolicy: PartialOutputPolicy,
        status: String,
        startedAt: Date,
        endedAt: Date
    ) {
        self.id = id
        self.planID = planID
        self.jobID = jobID
        self.outputArtifactID = outputArtifactID
        self.workerIdentifier = workerIdentifier
        self.toolVersionsJSON = toolVersionsJSON
        self.commandManifestJSON = commandManifestJSON
        self.partialOutputPolicy = partialOutputPolicy
        self.status = status
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

public struct ArtifactVerificationReport: Codable, Hashable, Sendable {
    public let id: String
    public let artifactID: ModelArtifactID
    public let jobID: JobID
    public let status: VerificationStatus
    public let checksJSON: String
    public let diagnosticExportURL: URL?
    public let runtimeSmokeGenerationID: String?
    public let createdAt: Date

    public init(
        id: String = UUID().uuidString,
        artifactID: ModelArtifactID,
        jobID: JobID,
        status: VerificationStatus,
        checksJSON: String,
        diagnosticExportURL: URL? = nil,
        runtimeSmokeGenerationID: String? = nil,
        createdAt: Date = .init()
    ) {
        self.id = id
        self.artifactID = artifactID
        self.jobID = jobID
        self.status = status
        self.checksJSON = checksJSON
        self.diagnosticExportURL = diagnosticExportURL
        self.runtimeSmokeGenerationID = runtimeSmokeGenerationID
        self.createdAt = createdAt
    }
}

public final class ModelArtifactRepository: @unchecked Sendable {
    private let store: SQLiteStore

    public static func defaultDatabaseURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("vMLX/models.sqlite3")
    }

    public init(databaseURL: URL = ModelArtifactRepository.defaultDatabaseURL()) throws {
        self.store = try SQLiteStore(databaseURL: databaseURL)
    }

    fileprivate init(store: SQLiteStore) {
        self.store = store
    }

    public func makeJobRepository() -> DurableJobRepository {
        DurableJobRepository(store: store)
    }

    public func makeEvaluationRepository() -> EvaluationRepository {
        EvaluationRepository(store: store)
    }

    public func makeOptimizationPlanRepository() -> OptimizationPlanRepository {
        OptimizationPlanRepository(store: store)
    }

    public func upsertIndexedModel(_ record: IndexedModelRecord) throws {
        try store.transaction { database in
            try SQLiteStore.execute(database, """
            INSERT INTO models (
                id, canonical_path, display_name, family, modality,
                total_size_bytes, is_jang, is_mxtq, quant_bits,
                detected_at, source, capabilities_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                canonical_path=excluded.canonical_path,
                display_name=excluded.display_name,
                family=excluded.family,
                modality=excluded.modality,
                total_size_bytes=excluded.total_size_bytes,
                is_jang=excluded.is_jang,
                is_mxtq=excluded.is_mxtq,
                quant_bits=excluded.quant_bits,
                detected_at=excluded.detected_at,
                source=excluded.source,
                capabilities_json=excluded.capabilities_json;
            """, bindings: record.legacyBindings)

            let format = record.isJANGTQ ? "jangtq" : (record.isJANG ? "jang" : "mlx")
            let precision = record.quantizationBits.map { "\($0)-bit" }
            if let identifiers = try Self.artifactIdentifiers(
                legacyModelID: record.legacyModelID,
                database: database
            ) {
                try SQLiteStore.execute(database, """
                UPDATE model_sources SET
                    local_url=?, architecture=?, capabilities_json=?,
                    source_format=?, source_precision=?
                WHERE id=?;
                """, bindings: [
                    .text(record.canonicalURL.path), .text(record.family),
                    .text(record.capabilitiesJSON), .text(format),
                    precision.map(SQLiteValue.text) ?? .null, .text(identifiers.sourceID),
                ])
                try SQLiteStore.execute(database, """
                UPDATE model_projects SET name=?, updated_at=? WHERE id=?;
                """, bindings: [
                    .text(record.displayName), .real(record.detectedAt.timeIntervalSince1970),
                    .text(identifiers.projectID),
                ])
                try SQLiteStore.execute(database, """
                UPDATE model_artifacts SET
                    name=?, local_url=?, canonical_path=?, format=?, precision=?,
                    state='ready', updated_at=?
                WHERE id=?;
                """, bindings: [
                    .text(record.displayName), .text(record.canonicalURL.path),
                    .text(record.canonicalURL.path), .text(format),
                    precision.map(SQLiteValue.text) ?? .null,
                    .real(record.detectedAt.timeIntervalSince1970), .text(identifiers.artifactID),
                ])
            } else {
                try Self.insertArtifactGraph(
                    for: record,
                    format: format,
                    precision: precision,
                    database: database
                )
            }
        }
    }

    public func indexedModels() throws -> [IndexedModelRecord] {
        try store.read { database in
            try readIndexedModels(database: database, predicate: nil)
        }
    }

    public func indexedModel(legacyModelID: String) throws -> IndexedModelRecord? {
        try store.read { database in
            try readIndexedModels(database: database, predicate: legacyModelID).first
        }
    }

    public func markUnavailableAndRemoveFromIndex(_ legacyModelIDs: Set<String>) throws {
        guard !legacyModelIDs.isEmpty else { return }
        try store.transaction { database in
            for identifier in legacyModelIDs {
                try SQLiteStore.execute(database, """
                UPDATE model_artifacts SET state='unavailable', updated_at=?
                WHERE legacy_model_id=?;
                """, bindings: [.real(Date().timeIntervalSince1970), .text(identifier)])
                try SQLiteStore.execute(
                    database,
                    "DELETE FROM models WHERE id=?;",
                    bindings: [.text(identifier)]
                )
            }
        }
    }

    public func mostRecentDetectionDate() throws -> Date? {
        try store.read { database in
            guard let value = try SQLiteStore.optionalDouble(
                database,
                "SELECT MAX(detected_at) FROM models;"
            ) else { return nil }
            return Date(timeIntervalSince1970: value)
        }
    }

    public func artifacts() throws -> [ModelArtifact] {
        try store.read { database in try readArtifacts(database: database, identifier: nil) }
    }

    public func artifact(id: ModelArtifactID) throws -> ModelArtifact? {
        try store.read { database in
            try readArtifacts(database: database, identifier: id.rawValue).first
        }
    }

    public func artifact(legacyModelID: String) throws -> ModelArtifact? {
        try store.read { database in
            try readArtifacts(database: database, legacyModelID: legacyModelID).first
        }
    }

    /// Atomically publishes a verified derived artifact, its reproducibility
    /// manifest, and its parent/child lineage. The caller must finish runtime
    /// verification before invoking this method.
    public func registerDerivedArtifact(
        _ artifact: ModelArtifact,
        manifest: ArtifactManifest,
        lineage: ArtifactLineage,
        buildRun: ArtifactBuildRun? = nil,
        verificationReport: ArtifactVerificationReport? = nil
    ) throws {
        guard artifact.manifestID == manifest.id,
              manifest.artifactID == artifact.id,
              lineage.childArtifactID == artifact.id,
              lineage.parentArtifactID == artifact.parentArtifactID,
              lineage.manifestID == manifest.id,
              buildRun?.outputArtifactID == artifact.id || buildRun == nil,
              verificationReport?.artifactID == artifact.id || verificationReport == nil else {
            throw DerivedArtifactRegistrationError.inconsistentIdentity
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payload = try Self.utf8(encoder.encode(manifest))
        try store.transaction { database in
            try SQLiteStore.execute(database, """
            INSERT INTO model_artifacts (
                id, project_id, parent_artifact_id, name, local_url,
                canonical_path, format, precision, state, manifest_id,
                verification_status, content_hash, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, bindings: [
                .text(artifact.id.rawValue), .text(artifact.projectID.rawValue),
                artifact.parentArtifactID.map { .text($0.rawValue) } ?? .null,
                .text(artifact.name), .text(artifact.localURL.path),
                .text(artifact.localURL.standardizedFileURL.path),
                .text(artifact.format.rawValue),
                artifact.precision.map { .text($0.rawValue) } ?? .null,
                .text(artifact.state.rawValue), .text(manifest.id.rawValue),
                .text(artifact.verificationStatus.rawValue),
                artifact.contentHash.map(SQLiteValue.text) ?? .null,
                .real(artifact.createdAt.timeIntervalSince1970),
                .real(artifact.updatedAt.timeIntervalSince1970),
            ])
            try SQLiteStore.execute(database, """
            INSERT INTO artifact_manifests (
                id, artifact_id, schema_version, source_revision,
                runtime_version, optimizer_version, kernel_version,
                pruning_plan_id, quantization_recipe_id,
                calibration_suite_id, hardware_profile_id, manifest_hash,
                payload_json, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """, bindings: [
                .text(manifest.id.rawValue), .text(manifest.artifactID.rawValue),
                .integer(Int64(manifest.schemaVersion)),
                manifest.sourceRevision.map(SQLiteValue.text) ?? .null,
                manifest.runtimeVersion.map(SQLiteValue.text) ?? .null,
                manifest.optimizerVersion.map(SQLiteValue.text) ?? .null,
                manifest.kernelVersion.map(SQLiteValue.text) ?? .null,
                manifest.optimizationPlanID.map { .text($0.rawValue) } ?? .null,
                manifest.quantizationRecipeID.map { .text($0.rawValue) } ?? .null,
                manifest.calibrationSuiteID.map { .text($0.rawValue) } ?? .null,
                manifest.hardwareProfileID.map { .text($0.rawValue) } ?? .null,
                .text(manifest.manifestHash), .text(payload),
                .real(manifest.createdAt.timeIntervalSince1970),
            ])
            for file in manifest.sourceFiles {
                try SQLiteStore.execute(database, """
                INSERT INTO artifact_source_files (
                    manifest_id, relative_path, size_bytes, sha256
                ) VALUES (?, ?, ?, ?);
                """, bindings: [
                    .text(manifest.id.rawValue), .text(file.relativePath),
                    .integer(file.sizeBytes), .text(file.sha256),
                ])
            }
            try SQLiteStore.execute(database, """
            INSERT INTO artifact_lineage (
                parent_artifact_id, child_artifact_id, operation,
                job_id, manifest_id, created_at
            ) VALUES (?, ?, ?, ?, ?, ?);
            """, bindings: [
                .text(lineage.parentArtifactID.rawValue),
                .text(lineage.childArtifactID.rawValue),
                .text(lineage.operation.rawValue),
                lineage.jobID.map { .text($0.rawValue) } ?? .null,
                lineage.manifestID.map { .text($0.rawValue) } ?? .null,
                .real(lineage.createdAt.timeIntervalSince1970),
            ])
            if let buildRun {
                try SQLiteStore.execute(database, """
                INSERT INTO build_runs (
                    id, plan_id, job_id, output_artifact_id, worker_identifier,
                    tool_versions_json, command_manifest_json, partial_output_policy,
                    status, started_at, ended_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
                """, bindings: [
                    .text(buildRun.id), .text(buildRun.planID.rawValue),
                    .text(buildRun.jobID.rawValue), .text(buildRun.outputArtifactID.rawValue),
                    .text(buildRun.workerIdentifier), .text(buildRun.toolVersionsJSON),
                    .text(buildRun.commandManifestJSON),
                    .text(buildRun.partialOutputPolicy.rawValue), .text(buildRun.status),
                    .real(buildRun.startedAt.timeIntervalSince1970),
                    .real(buildRun.endedAt.timeIntervalSince1970),
                ])
            }
            if let verificationReport {
                try SQLiteStore.execute(database, """
                INSERT INTO verification_reports (
                    id, artifact_id, job_id, status, checks_json,
                    diagnostic_export_url, runtime_smoke_generation_id, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?);
                """, bindings: [
                    .text(verificationReport.id), .text(verificationReport.artifactID.rawValue),
                    .text(verificationReport.jobID.rawValue),
                    .text(verificationReport.status.rawValue),
                    .text(verificationReport.checksJSON),
                    verificationReport.diagnosticExportURL.map { .text($0.path) } ?? .null,
                    verificationReport.runtimeSmokeGenerationID.map(SQLiteValue.text) ?? .null,
                    .real(verificationReport.createdAt.timeIntervalSince1970),
                ])
            }
        }
    }

    private static func utf8(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw DerivedArtifactRegistrationError.invalidManifestEncoding
        }
        return value
    }

    public func userDirectories() throws -> [URL] {
        try store.read { database in
            try SQLiteStore.textColumn(
                database,
                "SELECT url FROM user_dirs ORDER BY added_at ASC;"
            ).map { URL(fileURLWithPath: $0) }
        }
    }

    public func addUserDirectory(_ url: URL, at date: Date = .init()) throws {
        try store.write { database in
            try SQLiteStore.execute(database, """
            INSERT OR IGNORE INTO user_dirs (url, added_at) VALUES (?, ?);
            """, bindings: [.text(url.path), .real(date.timeIntervalSince1970)])
        }
    }

    public func removeUserDirectory(_ url: URL) throws {
        try store.write { database in
            try SQLiteStore.execute(
                database,
                "DELETE FROM user_dirs WHERE url=?;",
                bindings: [.text(url.path)]
            )
        }
    }
}

public final class DurableJobRepository: @unchecked Sendable {
    private let store: SQLiteStore

    public init(databaseURL: URL = ModelArtifactRepository.defaultDatabaseURL()) throws {
        self.store = try SQLiteStore(databaseURL: databaseURL)
    }

    fileprivate init(store: SQLiteStore) {
        self.store = store
    }

    public func upsert(_ record: DurableJobRecord) throws {
        try store.transaction { database in
            try SQLiteStore.execute(database, """
            INSERT INTO jobs (
                id, type, project_id, artifact_id, state, progress, current_stage,
                peak_memory_bytes, error_json, recovery_instructions,
                created_at, started_at, ended_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                type=excluded.type, project_id=excluded.project_id,
                artifact_id=excluded.artifact_id, state=excluded.state,
                progress=excluded.progress, current_stage=excluded.current_stage,
                peak_memory_bytes=excluded.peak_memory_bytes,
                error_json=excluded.error_json,
                recovery_instructions=excluded.recovery_instructions,
                started_at=excluded.started_at, ended_at=excluded.ended_at,
                updated_at=excluded.updated_at
            WHERE excluded.updated_at >= jobs.updated_at;
            """, bindings: record.bindings)
            let sequence = try SQLiteStore.scalarInt(
                database,
                "SELECT COALESCE(MAX(sequence), -1) + 1 FROM job_events WHERE job_id=?;",
                bindings: [.text(record.id.rawValue)]
            )
            try SQLiteStore.execute(database, """
            INSERT INTO job_events (job_id, sequence, event_type, payload_json, created_at)
            SELECT ?, ?, 'snapshot', ?, ?
            WHERE (SELECT updated_at FROM jobs WHERE id=?) = ?;
            """, bindings: [
                .text(record.id.rawValue), .integer(Int64(sequence)),
                .text(record.payloadJSON), .real(record.updatedAt.timeIntervalSince1970),
                .text(record.id.rawValue), .real(record.updatedAt.timeIntervalSince1970),
            ])
        }
    }

    public func records(type: String? = nil) throws -> [DurableJobRecord] {
        try store.read { database in
            let predicate = type == nil ? "" : "WHERE j.type=?"
            let bindings = type.map { [SQLiteValue.text($0)] } ?? []
            let sql = """
            SELECT j.id, j.type, j.project_id, j.artifact_id, j.state, j.progress,
                   j.current_stage, j.peak_memory_bytes, j.error_json,
                   j.recovery_instructions, j.created_at, j.started_at, j.ended_at,
                   j.updated_at,
                   COALESCE((
                       SELECT e.payload_json FROM job_events e
                       WHERE e.job_id=j.id AND e.event_type='snapshot'
                       ORDER BY e.sequence DESC LIMIT 1
                   ), '{}')
            FROM jobs j \(predicate)
            ORDER BY j.created_at ASC, j.id ASC;
            """
            return try readJobs(database: database, sql: sql, bindings: bindings)
        }
    }

    public func record(id: JobID) throws -> DurableJobRecord? {
        try store.read { database in
            let sql = """
            SELECT j.id, j.type, j.project_id, j.artifact_id, j.state, j.progress,
                   j.current_stage, j.peak_memory_bytes, j.error_json,
                   j.recovery_instructions, j.created_at, j.started_at, j.ended_at,
                   j.updated_at,
                   COALESCE((
                       SELECT e.payload_json FROM job_events e
                       WHERE e.job_id=j.id AND e.event_type='snapshot'
                       ORDER BY e.sequence DESC LIMIT 1
                   ), '{}')
            FROM jobs j WHERE j.id=? LIMIT 1;
            """
            return try readJobs(
                database: database,
                sql: sql,
                bindings: [.text(id.rawValue)]
            ).first
        }
    }

    public func remove(_ identifiers: Set<JobID>) throws {
        guard !identifiers.isEmpty else { return }
        try store.transaction { database in
            for identifier in identifiers {
                try SQLiteStore.execute(
                    database,
                    "DELETE FROM jobs WHERE id=?;",
                    bindings: [.text(identifier.rawValue)]
                )
            }
        }
    }
}

private extension ModelArtifactRepository {
    struct ArtifactIdentifiers {
        let sourceID: String
        let projectID: String
        let artifactID: String
    }

    static func artifactIdentifiers(
        legacyModelID: String,
        database: OpaquePointer
    ) throws -> ArtifactIdentifiers? {
        let sql = """
        SELECT s.id, p.id, a.id
        FROM model_artifacts a
        JOIN model_projects p ON p.id=a.project_id
        JOIN model_sources s ON s.id=p.source_id
        WHERE a.legacy_model_id=? LIMIT 1;
        """
        var statement: OpaquePointer?
        try SQLiteStore.prepare(database, sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        try SQLiteStore.bind([.text(legacyModelID)], to: statement, database: database, sql: sql)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else { throw SQLiteStore.error(database, result, sql) }
        return ArtifactIdentifiers(
            sourceID: SQLiteStore.text(statement, 0),
            projectID: SQLiteStore.text(statement, 1),
            artifactID: SQLiteStore.text(statement, 2)
        )
    }

    static func insertArtifactGraph(
        for record: IndexedModelRecord,
        format: String,
        precision: String?,
        database: OpaquePointer
    ) throws {
        let sourceID = ModelSourceID().rawValue
        let projectID = ModelProjectID().rawValue
        let artifactID = ModelArtifactID().rawValue
        let manifestID = ArtifactManifestID().rawValue
        let timestamp = record.detectedAt.timeIntervalSince1970
        let manifestPayload = try legacyManifestPayload(record.legacyModelID)
        try SQLiteStore.execute(database, """
        INSERT INTO model_sources (
            id, legacy_model_id, local_url, architecture, expert_topology_json,
            capabilities_json, source_format, source_precision, created_at
        ) VALUES (?, ?, ?, ?, '{}', ?, ?, ?, ?);
        """, bindings: [
            .text(sourceID), .text(record.legacyModelID), .text(record.canonicalURL.path),
            .text(record.family), .text(record.capabilitiesJSON), .text(format),
            precision.map(SQLiteValue.text) ?? .null, .real(timestamp),
        ])
        try SQLiteStore.execute(database, """
        INSERT INTO model_projects (id, name, source_id, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?);
        """, bindings: [
            .text(projectID), .text(record.displayName), .text(sourceID),
            .real(timestamp), .real(timestamp),
        ])
        try SQLiteStore.execute(database, """
        INSERT INTO model_artifacts (
            id, project_id, legacy_model_id, name, local_url, canonical_path,
            format, precision, state, manifest_id, verification_status,
            created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'ready', ?, 'unknown', ?, ?);
        """, bindings: [
            .text(artifactID), .text(projectID), .text(record.legacyModelID),
            .text(record.displayName), .text(record.canonicalURL.path),
            .text(record.canonicalURL.path), .text(format),
            precision.map(SQLiteValue.text) ?? .null, .text(manifestID),
            .real(timestamp), .real(timestamp),
        ])
        try SQLiteStore.execute(database, """
        INSERT INTO artifact_manifests (
            id, artifact_id, schema_version, manifest_hash, payload_json, created_at
        ) VALUES (?, ?, 1, ?, ?, ?);
        """, bindings: [
            .text(manifestID), .text(artifactID), .text("legacy:\(record.legacyModelID)"),
            .text(manifestPayload),
            .real(timestamp),
        ])
    }

    static func legacyManifestPayload(_ legacyModelID: String) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: ["imported_from_legacy_model_id": legacyModelID],
            options: [.sortedKeys]
        )
        guard let payload = String(data: data, encoding: .utf8) else {
            throw ModelStoreMigrationError.sqlite(
                code: SQLITE_MISMATCH,
                message: "Unable to encode artifact manifest JSON",
                statement: legacyModelID
            )
        }
        return payload
    }

    func readIndexedModels(
        database: OpaquePointer,
        predicate legacyModelID: String?
    ) throws -> [IndexedModelRecord] {
        let filter = legacyModelID == nil ? "" : "AND m.id=?"
        let derivedFilter = legacyModelID == nil ? "" : "AND a.id=?"
        let sql = """
        SELECT m.id, a.canonical_path, a.name, m.family, m.modality,
               m.total_size_bytes, m.is_jang, m.is_mxtq, m.quant_bits,
               m.detected_at, m.source, m.capabilities_json
        FROM model_artifacts a
        JOIN models m ON m.id=a.legacy_model_id
        WHERE a.state <> 'unavailable' \(filter)
        UNION ALL
        SELECT m.id, m.canonical_path, m.display_name, m.family, m.modality,
               m.total_size_bytes, m.is_jang, m.is_mxtq, m.quant_bits,
               m.detected_at, m.source, m.capabilities_json
        FROM models m
        WHERE NOT EXISTS (
            SELECT 1 FROM model_artifacts a WHERE a.legacy_model_id=m.id
        ) \(legacyModelID == nil ? "" : "AND m.id=?")
        UNION ALL
        SELECT a.id, a.canonical_path, a.name,
               COALESCE(pm.family, 'unknown'), COALESCE(pm.modality, 'text'),
               COALESCE((
                 SELECT SUM(sf.size_bytes)
                 FROM artifact_source_files sf
                 WHERE sf.manifest_id=a.manifest_id
               ), 0),
               CASE WHEN a.format IN ('jang','jangtq') THEN 1 ELSE 0 END,
               CASE WHEN a.format='jangtq' THEN 1 ELSE 0 END,
               CASE
                 WHEN a.precision GLOB '*[0-9]-bit' THEN CAST(a.precision AS INTEGER)
                 ELSE NULL
               END,
               a.created_at,
               'user:' || a.canonical_path,
               COALESCE(pm.capabilities_json, '{}')
        FROM model_artifacts a
        LEFT JOIN model_artifacts pa ON pa.id=a.parent_artifact_id
        LEFT JOIN models pm ON pm.id=pa.legacy_model_id
        WHERE a.legacy_model_id IS NULL
          AND a.state='ready'
          AND a.verification_status='passed'
          \(derivedFilter)
        ORDER BY 3 ASC;
        """
        let bindings: [SQLiteValue] = legacyModelID.map {
            [.text($0), .text($0), .text($0)]
        } ?? []
        var statement: OpaquePointer?
        try SQLiteStore.prepare(database, sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        try SQLiteStore.bind(bindings, to: statement, database: database, sql: sql)
        var records: [IndexedModelRecord] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return records }
            guard result == SQLITE_ROW else { throw SQLiteStore.error(database, result, sql) }
            records.append(IndexedModelRecord(
                legacyModelID: SQLiteStore.text(statement, 0),
                canonicalURL: URL(fileURLWithPath: SQLiteStore.text(statement, 1)),
                displayName: SQLiteStore.text(statement, 2),
                family: SQLiteStore.text(statement, 3),
                modality: SQLiteStore.text(statement, 4),
                totalSizeBytes: sqlite3_column_int64(statement, 5),
                isJANG: sqlite3_column_int(statement, 6) != 0,
                isJANGTQ: sqlite3_column_int(statement, 7) != 0,
                quantizationBits: sqlite3_column_type(statement, 8) == SQLITE_NULL
                    ? nil : Int(sqlite3_column_int(statement, 8)),
                detectedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9)),
                source: SQLiteStore.text(statement, 10),
                capabilitiesJSON: SQLiteStore.text(statement, 11)
            ))
        }
    }

    func readArtifacts(
        database: OpaquePointer,
        identifier: String? = nil,
        legacyModelID: String? = nil
    ) throws -> [ModelArtifact] {
        let predicate: String
        let bindings: [SQLiteValue]
        if let identifier {
            predicate = "WHERE id=?"
            bindings = [.text(identifier)]
        } else if let legacyModelID {
            predicate = "WHERE legacy_model_id=?"
            bindings = [.text(legacyModelID)]
        } else {
            predicate = ""
            bindings = []
        }
        let sql = """
        SELECT id, project_id, parent_artifact_id, legacy_model_id, name,
               local_url, format, precision, state, manifest_id,
               verification_status, content_hash, created_at, updated_at
        FROM model_artifacts \(predicate) ORDER BY created_at ASC, id ASC;
        """
        var statement: OpaquePointer?
        try SQLiteStore.prepare(database, sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        try SQLiteStore.bind(bindings, to: statement, database: database, sql: sql)
        var artifacts: [ModelArtifact] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return artifacts }
            guard result == SQLITE_ROW else { throw SQLiteStore.error(database, result, sql) }
            guard
                let id = ModelArtifactID(rawValue: SQLiteStore.text(statement, 0)),
                let projectID = ModelProjectID(rawValue: SQLiteStore.text(statement, 1)),
                let state = ArtifactState(rawValue: SQLiteStore.text(statement, 8)),
                let verification = VerificationStatus(rawValue: SQLiteStore.text(statement, 10))
            else { continue }
            artifacts.append(ModelArtifact(
                id: id,
                projectID: projectID,
                parentArtifactID: SQLiteStore.optionalText(statement, 2).flatMap(ModelArtifactID.init(rawValue:)),
                legacyModelID: SQLiteStore.optionalText(statement, 3),
                name: SQLiteStore.text(statement, 4),
                localURL: URL(fileURLWithPath: SQLiteStore.text(statement, 5)),
                format: .init(rawValue: SQLiteStore.text(statement, 6)),
                precision: SQLiteStore.optionalText(statement, 7).map(ArtifactPrecision.init(rawValue:)),
                state: state,
                manifestID: SQLiteStore.optionalText(statement, 9).flatMap(ArtifactManifestID.init(rawValue:)),
                verificationStatus: verification,
                contentHash: SQLiteStore.optionalText(statement, 11),
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 12)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13))
            ))
        }
    }
}

private extension IndexedModelRecord {
    var legacyBindings: [SQLiteValue] {
        [
            .text(legacyModelID), .text(canonicalURL.path), .text(displayName),
            .text(family), .text(modality), .integer(totalSizeBytes),
            .integer(isJANG ? 1 : 0), .integer(isJANGTQ ? 1 : 0),
            quantizationBits.map { .integer(Int64($0)) } ?? .null,
            .real(detectedAt.timeIntervalSince1970), .text(source),
            .text(capabilitiesJSON),
        ]
    }
}

private extension DurableJobRecord {
    var bindings: [SQLiteValue] {
        [
            .text(id.rawValue), .text(type),
            projectID.map { .text($0.rawValue) } ?? .null,
            artifactID.map { .text($0.rawValue) } ?? .null,
            .text(state.rawValue), .real(progress),
            currentStage.map(SQLiteValue.text) ?? .null,
            peakMemoryBytes.map(SQLiteValue.integer) ?? .null,
            errorJSON.map(SQLiteValue.text) ?? .null,
            recoveryInstructions.map(SQLiteValue.text) ?? .null,
            .real(createdAt.timeIntervalSince1970),
            startedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            endedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
            .real(updatedAt.timeIntervalSince1970),
        ]
    }
}

private func readJobs(
    database: OpaquePointer,
    sql: String,
    bindings: [SQLiteValue]
) throws -> [DurableJobRecord] {
    var statement: OpaquePointer?
    try SQLiteStore.prepare(database, sql, statement: &statement)
    defer { sqlite3_finalize(statement) }
    try SQLiteStore.bind(bindings, to: statement, database: database, sql: sql)
    var records: [DurableJobRecord] = []
    while true {
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return records }
        guard result == SQLITE_ROW else { throw SQLiteStore.error(database, result, sql) }
        guard
            let id = JobID(rawValue: SQLiteStore.text(statement, 0)),
            let state = DurableJobState(rawValue: SQLiteStore.text(statement, 4))
        else { continue }
        records.append(DurableJobRecord(
            id: id,
            type: SQLiteStore.text(statement, 1),
            projectID: SQLiteStore.optionalText(statement, 2).flatMap(ModelProjectID.init(rawValue:)),
            artifactID: SQLiteStore.optionalText(statement, 3).flatMap(ModelArtifactID.init(rawValue:)),
            state: state,
            progress: sqlite3_column_double(statement, 5),
            currentStage: SQLiteStore.optionalText(statement, 6),
            peakMemoryBytes: sqlite3_column_type(statement, 7) == SQLITE_NULL
                ? nil : sqlite3_column_int64(statement, 7),
            errorJSON: SQLiteStore.optionalText(statement, 8),
            recoveryInstructions: SQLiteStore.optionalText(statement, 9),
            payloadJSON: SQLiteStore.text(statement, 14),
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 10)),
            startedAt: SQLiteStore.optionalDate(statement, 11),
            endedAt: SQLiteStore.optionalDate(statement, 12),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 13))
        ))
    }
}

enum SQLiteValue {
    case text(String)
    case integer(Int64)
    case real(Double)
    case null
}

final class SQLiteStore: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var database: OpaquePointer?

    init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(databaseURL.path, &database, flags, nil)
        guard result == SQLITE_OK, let database else {
            throw ModelStoreMigrationError.sqlite(
                code: result,
                message: "Unable to open models.sqlite3",
                statement: databaseURL.path
            )
        }
        do {
            try Self.execute(database, "PRAGMA journal_mode=WAL;")
            try Self.execute(database, "PRAGMA synchronous=NORMAL;")
            try ModelStoreMigrator.migrate(database)
        } catch {
            sqlite3_close_v2(database)
            self.database = nil
            throw error
        }
    }

    deinit {
        if let database { sqlite3_close_v2(database) }
    }

    func read<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try lock.withLock {
            guard let database else {
                throw ModelStoreMigrationError.sqlite(
                    code: SQLITE_MISUSE,
                    message: "models.sqlite3 is closed",
                    statement: "read"
                )
            }
            return try body(database)
        }
    }

    func write<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try read(body)
    }

    func transaction<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        try write { database in
            try Self.execute(database, "BEGIN IMMEDIATE;")
            do {
                let value = try body(database)
                try Self.execute(database, "COMMIT;")
                return value
            } catch {
                try? Self.execute(database, "ROLLBACK;")
                throw error
            }
        }
    }

    static func execute(
        _ database: OpaquePointer,
        _ sql: String,
        bindings: [SQLiteValue] = []
    ) throws {
        if bindings.isEmpty {
            var message: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database, sql, nil, nil, &message)
            defer { sqlite3_free(message) }
            guard result == SQLITE_OK else { throw error(database, result, sql, message) }
            return
        }
        var statement: OpaquePointer?
        try prepare(database, sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement, database: database, sql: sql)
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { throw error(database, result, sql) }
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
        guard result == SQLITE_ROW else { throw error(database, result, sql) }
        return Int(sqlite3_column_int64(statement, 0))
    }

    static func optionalDouble(_ database: OpaquePointer, _ sql: String) throws -> Double? {
        var statement: OpaquePointer?
        try prepare(database, sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else { throw error(database, result, sql) }
        return sqlite3_column_type(statement, 0) == SQLITE_NULL
            ? nil : sqlite3_column_double(statement, 0)
    }

    static func textColumn(_ database: OpaquePointer, _ sql: String) throws -> [String] {
        var statement: OpaquePointer?
        try prepare(database, sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        var values: [String] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return values }
            guard result == SQLITE_ROW else { throw error(database, result, sql) }
            values.append(text(statement, 0))
        }
    }

    static func prepare(
        _ database: OpaquePointer,
        _ sql: String,
        statement: inout OpaquePointer?
    ) throws {
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK else { throw error(database, result, sql) }
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
            case .text(let value):
                result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case .integer(let value):
                result = sqlite3_bind_int64(statement, index, value)
            case .real(let value):
                result = sqlite3_bind_double(statement, index, value)
            case .null:
                result = sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw error(database, result, sql) }
        }
    }

    static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    static func optionalText(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : text(statement, column)
    }

    static func optionalDate(_ statement: OpaquePointer?, _ column: Int32) -> Date? {
        sqlite3_column_type(statement, column) == SQLITE_NULL
            ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    static func error(
        _ database: OpaquePointer,
        _ code: Int32,
        _ statement: String,
        _ explicitMessage: UnsafeMutablePointer<CChar>? = nil
    ) -> ModelStoreMigrationError {
        .sqlite(
            code: code,
            message: explicitMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database)),
            statement: statement
        )
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
