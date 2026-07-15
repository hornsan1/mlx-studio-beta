import Foundation
import MLXStudioDomain
import SQLite3

public enum EvaluationPersistenceError: Error, Equatable, Sendable {
    case immutableSuite(EvaluationSuiteID)
    case invalidPayload(String)
}

public struct StoredEvaluationRun: Codable, Hashable, Sendable {
    public let request: EvaluationRunRequest
    public let manifest: EvaluationRunManifest
    public let status: EvaluationRunStatus
    public let endedAt: Date?

    public init(
        request: EvaluationRunRequest,
        manifest: EvaluationRunManifest,
        status: EvaluationRunStatus,
        endedAt: Date? = nil
    ) {
        self.request = request
        self.manifest = manifest
        self.status = status
        self.endedAt = endedAt
    }
}

/// Durable evaluation storage in the canonical models.sqlite3 store.
/// Query-friendly columns remain populated while versioned JSON payloads
/// preserve the complete domain contracts for restart and forward evolution.
public final class EvaluationRepository: @unchecked Sendable {
    private let store: SQLiteStore

    public init(databaseURL: URL = ModelArtifactRepository.defaultDatabaseURL()) throws {
        self.store = try SQLiteStore(databaseURL: databaseURL)
    }

    init(store: SQLiteStore) {
        self.store = store
    }

    public func saveSuite(_ suite: EvaluationSuite, at date: Date = .init()) throws {
        let suite = Self.canonicalSuite(suite)
        let tagsJSON = try Self.encode(suite.tags.sorted())
        try store.transaction { database in
            let runCount = try SQLiteStore.scalarInt(
                database,
                "SELECT COUNT(*) FROM evaluation_runs WHERE suite_id=?;",
                bindings: [.text(suite.id.rawValue)]
            )
            if runCount > 0 {
                let persisted = try Self.readSuites(
                    database: database,
                    sql: """
                    SELECT id, name, revision, tags_json, suite_hash
                    FROM evaluation_suites WHERE id=? LIMIT 1;
                    """,
                    bindings: [.text(suite.id.rawValue)]
                ).first
                guard persisted == suite else {
                    throw EvaluationPersistenceError.immutableSuite(suite.id)
                }
                return
            }

            try SQLiteStore.execute(database, """
            INSERT INTO evaluation_suites (
                id, name, revision, tags_json, suite_hash, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                name=excluded.name, revision=excluded.revision,
                tags_json=excluded.tags_json, suite_hash=excluded.suite_hash,
                updated_at=excluded.updated_at;
            """, bindings: [
                .text(suite.id.rawValue), .text(suite.name), .text(suite.revision),
                .text(tagsJSON), .text(suite.suiteHash),
                .real(date.timeIntervalSince1970), .real(date.timeIntervalSince1970),
            ])

            if runCount == 0 {
                try SQLiteStore.execute(
                    database,
                    "DELETE FROM evaluation_cases WHERE suite_id=?;",
                    bindings: [.text(suite.id.rawValue)]
                )
                for evaluationCase in suite.cases.sorted(by: Self.caseOrder) {
                    try Self.insert(evaluationCase, suiteID: suite.id, database: database)
                }
            }
        }
    }

    public func suites() throws -> [EvaluationSuite] {
        try store.read { database in
            let sql = """
            SELECT id, name, revision, tags_json, suite_hash
            FROM evaluation_suites ORDER BY updated_at DESC, id ASC;
            """
            return try Self.readSuites(database: database, sql: sql, bindings: [])
        }
    }

    public func suite(id: EvaluationSuiteID) throws -> EvaluationSuite? {
        try store.read { database in
            try Self.readSuites(
                database: database,
                sql: """
                SELECT id, name, revision, tags_json, suite_hash
                FROM evaluation_suites WHERE id=? LIMIT 1;
                """,
                bindings: [.text(id.rawValue)]
            ).first
        }
    }

    public func saveRun(
        request: EvaluationRunRequest,
        manifest: EvaluationRunManifest,
        status: EvaluationRunStatus = .pending
    ) throws {
        guard manifest.runID == request.id,
              manifest.suiteID == request.suite.id,
              manifest.suiteHash == request.suite.suiteHash
        else { throw EvaluationPersistenceError.invalidPayload("run manifest identity mismatch") }
        try saveSuite(request.suite, at: request.createdAt)
        let executionOrderJSON = try Self.encode(request.executionOrder)
        let requestJSON = try Self.encode(request)
        let manifestJSON = try Self.encode(manifest)
        try store.transaction { database in
            let existingCount = try SQLiteStore.scalarInt(
                database,
                "SELECT COUNT(*) FROM evaluation_runs WHERE id=?;",
                bindings: [.text(request.id.rawValue)]
            )
            let mismatchCount = try SQLiteStore.scalarInt(
                database,
                """
                SELECT COUNT(*) FROM evaluation_runs
                WHERE id=? AND (request_json<>? OR manifest_json<>? OR manifest_hash<>?);
                """,
                bindings: [
                    .text(request.id.rawValue), .text(requestJSON),
                    .text(manifestJSON), .text(manifest.manifestHash),
                ]
            )
            guard mismatchCount == 0 else {
                throw EvaluationPersistenceError.invalidPayload("evaluation run is immutable")
            }
            try SQLiteStore.execute(database, """
            INSERT INTO evaluation_runs (
                id, suite_id, hardware_profile_id, runtime_version, kernel_version,
                execution_order_json, status, started_at, ended_at,
                request_json, manifest_json, manifest_hash
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                status=excluded.status;
            """, bindings: [
                .text(request.id.rawValue), .text(request.suite.id.rawValue),
                request.hardwareProfileID.map { .text($0.rawValue) } ?? .null,
                request.runtimeVersion.map(SQLiteValue.text) ?? .null,
                request.kernelVersion.map(SQLiteValue.text) ?? .null,
                .text(executionOrderJSON), .text(status.rawValue),
                .real(request.createdAt.timeIntervalSince1970),
                .text(requestJSON), .text(manifestJSON), .text(manifest.manifestHash),
            ])
            if existingCount == 0 {
                for candidate in request.candidates {
                    try SQLiteStore.execute(database, """
                    INSERT INTO evaluation_run_artifacts (
                        run_id, artifact_id, blind_label, artifact_hash
                    ) VALUES (?, ?, ?, ?);
                    """, bindings: [
                        .text(request.id.rawValue), .text(candidate.artifactID.rawValue),
                        .text(candidate.blindLabel),
                        candidate.artifactHash.map(SQLiteValue.text) ?? .null,
                    ])
                }
            }
        }
    }

    public func run(id: EvaluationRunID) throws -> StoredEvaluationRun? {
        try store.read { database in
            let sql = """
            SELECT request_json, manifest_json, status, ended_at
            FROM evaluation_runs WHERE id=? LIMIT 1;
            """
            var statement: OpaquePointer?
            try SQLiteStore.prepare(database, sql, statement: &statement)
            defer { sqlite3_finalize(statement) }
            try SQLiteStore.bind([.text(id.rawValue)], to: statement, database: database, sql: sql)
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return nil }
            guard result == SQLITE_ROW else { throw SQLiteStore.error(database, result, sql) }
            guard let status = EvaluationRunStatus(rawValue: SQLiteStore.text(statement, 2)) else {
                throw EvaluationPersistenceError.invalidPayload("invalid evaluation run status")
            }
            return StoredEvaluationRun(
                request: try Self.decode(EvaluationRunRequest.self, from: SQLiteStore.text(statement, 0)),
                manifest: try Self.decode(EvaluationRunManifest.self, from: SQLiteStore.text(statement, 1)),
                status: status,
                endedAt: SQLiteStore.optionalDate(statement, 3)
            )
        }
    }

    /// Returns durable runs newest first so application surfaces can discover
    /// interrupted work after a process restart and offer an explicit resume.
    public func runs() throws -> [StoredEvaluationRun] {
        try store.read { database in
            let sql = """
            SELECT request_json, manifest_json, status, ended_at
            FROM evaluation_runs ORDER BY started_at DESC, id ASC;
            """
            var statement: OpaquePointer?
            try SQLiteStore.prepare(database, sql, statement: &statement)
            defer { sqlite3_finalize(statement) }
            var runs: [StoredEvaluationRun] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return runs }
                guard result == SQLITE_ROW else { throw SQLiteStore.error(database, result, sql) }
                guard let status = EvaluationRunStatus(rawValue: SQLiteStore.text(statement, 2)) else {
                    throw EvaluationPersistenceError.invalidPayload(
                        "invalid evaluation run status"
                    )
                }
                runs.append(StoredEvaluationRun(
                    request: try Self.decode(
                        EvaluationRunRequest.self,
                        from: SQLiteStore.text(statement, 0)
                    ),
                    manifest: try Self.decode(
                        EvaluationRunManifest.self,
                        from: SQLiteStore.text(statement, 1)
                    ),
                    status: status,
                    endedAt: SQLiteStore.optionalDate(statement, 3)
                ))
            }
        }
    }

    public func setRunStatus(
        _ status: EvaluationRunStatus,
        runID: EvaluationRunID,
        endedAt: Date? = nil
    ) throws {
        try store.write { database in
            try SQLiteStore.execute(database, """
            UPDATE evaluation_runs SET status=?, ended_at=? WHERE id=?;
            """, bindings: [
                .text(status.rawValue),
                endedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .text(runID.rawValue),
            ])
        }
    }

    public func saveCaseResult(
        _ result: EvaluationCaseResult,
        runID: EvaluationRunID,
        createdAt: Date = .init()
    ) throws {
        let generation = result.generationResult
        let score = result.score
        let errorJSON = try result.errorDescription.map {
            try Self.encode(["description": $0])
        }
        try store.write { database in
            try SQLiteStore.execute(database, """
            INSERT INTO evaluation_results (
                id, run_id, case_id, artifact_id, generation_id, output_text,
                score_kind, score_value, score_payload_json, runtime_metrics_json,
                error_json, created_at, case_result_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(run_id, case_id, artifact_id) DO UPDATE SET
                generation_id=excluded.generation_id,
                output_text=excluded.output_text,
                score_kind=excluded.score_kind,
                score_value=excluded.score_value,
                score_payload_json=excluded.score_payload_json,
                runtime_metrics_json=excluded.runtime_metrics_json,
                error_json=excluded.error_json,
                created_at=excluded.created_at,
                case_result_json=excluded.case_result_json;
            """, bindings: [
                .text(UUID().uuidString.lowercased()), .text(runID.rawValue),
                .text(result.caseID.rawValue), .text(result.artifactID.rawValue),
                .text(generation?.generationID.rawValue ?? ""),
                .text(generation?.text ?? ""),
                score.map { .text($0.kind.rawValue) } ?? .null,
                score.map { .real($0.value) } ?? .null,
                score.map { try .text(Self.encode($0)) } ?? .null,
                .text(try Self.encode(generation?.metrics ?? RuntimeMetrics())),
                errorJSON.map(SQLiteValue.text) ?? .null,
                .real(createdAt.timeIntervalSince1970),
                .text(try Self.encode(result)),
            ])
        }
    }

    public func caseResults(runID: EvaluationRunID) throws -> [EvaluationCaseResult] {
        try store.read { database in
            let sql = """
            SELECT case_result_json FROM evaluation_results
            WHERE run_id=? ORDER BY created_at ASC, id ASC;
            """
            var statement: OpaquePointer?
            try SQLiteStore.prepare(database, sql, statement: &statement)
            defer { sqlite3_finalize(statement) }
            try SQLiteStore.bind([.text(runID.rawValue)], to: statement, database: database, sql: sql)
            var results: [EvaluationCaseResult] = []
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return results }
                guard result == SQLITE_ROW else { throw SQLiteStore.error(database, result, sql) }
                results.append(try Self.decode(
                    EvaluationCaseResult.self,
                    from: SQLiteStore.text(statement, 0)
                ))
            }
        }
    }

    public func saveHumanJudgment(_ judgment: HumanJudgment) throws {
        guard judgment.assignment.responseAArtifactID != judgment.assignment.responseBArtifactID else {
            throw EvaluationPersistenceError.invalidPayload("blind assignment candidates must differ")
        }
        guard judgment.revealedAt == nil || judgment.choice != nil else {
            throw EvaluationPersistenceError.invalidPayload("blind identity reveal requires a judgment")
        }
        let assignmentJSON = try Self.encode(judgment.assignment)
        try store.transaction { database in
            let existing = try Self.readHumanJudgments(
                database: database,
                sql: """
                SELECT id, run_id, case_id, assignment_json, choice, notes, revealed_at, created_at
                FROM human_judgments WHERE id=? LIMIT 1;
                """,
                bindings: [.text(judgment.id.rawValue)]
            ).first
            if let existing, existing.revealedAt != nil, existing != judgment {
                throw EvaluationPersistenceError.invalidPayload(
                    "revealed human judgment is immutable"
                )
            }
            let duplicateLogicalJudgment = try SQLiteStore.scalarInt(
                database,
                "SELECT COUNT(*) FROM human_judgments WHERE run_id=? AND case_id=? AND id<>?;",
                bindings: [
                    .text(judgment.runID.rawValue), .text(judgment.caseID.rawValue),
                    .text(judgment.id.rawValue),
                ]
            )
            guard duplicateLogicalJudgment == 0 else {
                throw EvaluationPersistenceError.invalidPayload(
                    "one human judgment is allowed per evaluation run and case"
                )
            }
            let immutableMismatch = try SQLiteStore.scalarInt(
                database,
                """
                SELECT COUNT(*) FROM human_judgments
                WHERE id=? AND (run_id<>? OR case_id<>? OR assignment_json<>?);
                """,
                bindings: [
                    .text(judgment.id.rawValue), .text(judgment.runID.rawValue),
                    .text(judgment.caseID.rawValue), .text(assignmentJSON),
                ]
            )
            guard immutableMismatch == 0 else {
                throw EvaluationPersistenceError.invalidPayload(
                    "human judgment assignment is immutable"
                )
            }
            try SQLiteStore.execute(database, """
            INSERT INTO human_judgments (
                id, run_id, case_id, assignment_json, choice, notes, revealed_at, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                choice=excluded.choice, notes=excluded.notes, revealed_at=excluded.revealed_at;
            """, bindings: [
                .text(judgment.id.rawValue), .text(judgment.runID.rawValue),
                .text(judgment.caseID.rawValue), .text(assignmentJSON),
                judgment.choice.map { .text($0.rawValue) } ?? .null,
                judgment.notes.map(SQLiteValue.text) ?? .null,
                judgment.revealedAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                .real(judgment.createdAt.timeIntervalSince1970),
            ])
        }
    }

    public func humanJudgment(
        runID: EvaluationRunID,
        caseID: EvaluationCaseID
    ) throws -> HumanJudgment? {
        try store.read { database in
            try Self.readHumanJudgments(
                database: database,
                sql: """
                SELECT id, run_id, case_id, assignment_json, choice, notes, revealed_at, created_at
                FROM human_judgments WHERE run_id=? AND case_id=?
                ORDER BY created_at ASC, id ASC LIMIT 1;
                """,
                bindings: [.text(runID.rawValue), .text(caseID.rawValue)]
            ).first
        }
    }

    public func humanJudgments(runID: EvaluationRunID) throws -> [HumanJudgment] {
        try store.read { database in
            try Self.readHumanJudgments(
                database: database,
                sql: """
                SELECT id, run_id, case_id, assignment_json, choice, notes, revealed_at, created_at
                FROM human_judgments WHERE run_id=? ORDER BY created_at ASC, id ASC;
                """,
                bindings: [.text(runID.rawValue)]
            )
        }
    }
}

private extension EvaluationRepository {
    static func insert(
        _ evaluationCase: EvaluationCase,
        suiteID: EvaluationSuiteID,
        database: OpaquePointer
    ) throws {
        let systemPrompt = evaluationCase.messages.first { $0.role == .system }?.content
        let prompt = evaluationCase.messages.first { $0.role == .user }?.content ?? ""
        try SQLiteStore.execute(database, """
        INSERT INTO evaluation_cases (
            id, suite_id, ordinal, prompt, system_prompt, domain, tags_json,
            expected_kind, expected_value, generation_configuration_json,
            weight, case_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, bindings: [
            .text(evaluationCase.id.rawValue), .text(suiteID.rawValue),
            .integer(Int64(evaluationCase.ordinal)), .text(prompt),
            systemPrompt.map(SQLiteValue.text) ?? .null,
            evaluationCase.domain.map(SQLiteValue.text) ?? .null,
            .text(try encode(evaluationCase.tags.sorted())),
            evaluationCase.expectation.map { .text($0.kind.rawValue) } ?? .null,
            evaluationCase.expectation?.value.map(SQLiteValue.text) ?? .null,
            .text(try encode(evaluationCase.generationConfiguration)),
            .real(evaluationCase.weight), .text(try encode(evaluationCase)),
        ])
    }

    static func readSuites(
        database: OpaquePointer,
        sql: String,
        bindings: [SQLiteValue]
    ) throws -> [EvaluationSuite] {
        var statement: OpaquePointer?
        try SQLiteStore.prepare(database, sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        try SQLiteStore.bind(bindings, to: statement, database: database, sql: sql)
        var suites: [EvaluationSuite] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return suites }
            guard result == SQLITE_ROW else { throw SQLiteStore.error(database, result, sql) }
            guard let id = EvaluationSuiteID(rawValue: SQLiteStore.text(statement, 0)) else {
                throw EvaluationPersistenceError.invalidPayload("invalid evaluation suite identifier")
            }
            suites.append(EvaluationSuite(
                id: id,
                name: SQLiteStore.text(statement, 1),
                revision: SQLiteStore.text(statement, 2),
                tags: Set(try decode([String].self, from: SQLiteStore.text(statement, 3))),
                cases: try readCases(database: database, suiteID: id),
                suiteHash: SQLiteStore.text(statement, 4)
            ))
        }
    }

    static func readCases(
        database: OpaquePointer,
        suiteID: EvaluationSuiteID
    ) throws -> [EvaluationCase] {
        let sql = """
        SELECT case_json FROM evaluation_cases
        WHERE suite_id=? ORDER BY ordinal ASC, id ASC;
        """
        var statement: OpaquePointer?
        try SQLiteStore.prepare(database, sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        try SQLiteStore.bind([.text(suiteID.rawValue)], to: statement, database: database, sql: sql)
        var cases: [EvaluationCase] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return cases }
            guard result == SQLITE_ROW else { throw SQLiteStore.error(database, result, sql) }
            cases.append(try decode(EvaluationCase.self, from: SQLiteStore.text(statement, 0)))
        }
    }

    static func readHumanJudgments(
        database: OpaquePointer,
        sql: String,
        bindings: [SQLiteValue]
    ) throws -> [HumanJudgment] {
        var statement: OpaquePointer?
        try SQLiteStore.prepare(database, sql, statement: &statement)
        defer { sqlite3_finalize(statement) }
        try SQLiteStore.bind(bindings, to: statement, database: database, sql: sql)
        var judgments: [HumanJudgment] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return judgments }
            guard result == SQLITE_ROW else { throw SQLiteStore.error(database, result, sql) }
            guard let id = HumanJudgmentID(rawValue: SQLiteStore.text(statement, 0)),
                  let runID = EvaluationRunID(rawValue: SQLiteStore.text(statement, 1)),
                  let caseID = EvaluationCaseID(rawValue: SQLiteStore.text(statement, 2))
            else {
                throw EvaluationPersistenceError.invalidPayload("invalid human judgment identifier")
            }
            let choiceText = SQLiteStore.optionalText(statement, 4)
            let choice = try choiceText.map { value -> BlindResponseChoice in
                guard let choice = BlindResponseChoice(rawValue: value) else {
                    throw EvaluationPersistenceError.invalidPayload("invalid blind response choice")
                }
                return choice
            }
            let revealedAt = sqlite3_column_type(statement, 6) == SQLITE_NULL
                ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, 6))
            judgments.append(HumanJudgment(
                id: id,
                runID: runID,
                caseID: caseID,
                assignment: try decode(
                    BlindAssignment.self,
                    from: SQLiteStore.text(statement, 3)
                ),
                choice: choice,
                notes: SQLiteStore.optionalText(statement, 5),
                revealedAt: revealedAt,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
            ))
        }
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let data = json.data(using: .utf8) else {
            throw EvaluationPersistenceError.invalidPayload("evaluation payload is not UTF-8")
        }
        return try decoder.decode(type, from: data)
    }

    static func caseOrder(_ lhs: EvaluationCase, _ rhs: EvaluationCase) -> Bool {
        lhs.ordinal == rhs.ordinal
            ? lhs.id.rawValue < rhs.id.rawValue
            : lhs.ordinal < rhs.ordinal
    }

    static func canonicalSuite(_ suite: EvaluationSuite) -> EvaluationSuite {
        EvaluationSuite(
            id: suite.id,
            name: suite.name,
            revision: suite.revision,
            tags: suite.tags,
            cases: suite.cases.sorted(by: caseOrder),
            suiteHash: suite.suiteHash
        )
    }
}
