import Foundation
import MLXStudioDomain
import SQLite3

public final class OptimizationPlanRepository: @unchecked Sendable {
    private let store: SQLiteStore

    public init(databaseURL: URL = ModelArtifactRepository.defaultDatabaseURL()) throws {
        self.store = try SQLiteStore(databaseURL: databaseURL)
    }

    init(store: SQLiteStore) {
        self.store = store
    }

    public func upsert(_ plan: OptimizationPlan) throws {
        let encoder = Self.encoder()
        let objectiveJSON = try Self.string(encoder.encode(plan.objective))
        let pruningJSON = try Self.string(encoder.encode(PersistedPruningConfiguration(plan)))
        let estimateJSON = try plan.estimate.map { try Self.string(encoder.encode($0)) }

        try store.transaction { database in
            if let recipe = plan.quantizationRecipe {
                try Self.upsert(recipe, createdAt: plan.createdAt, database: database, encoder: encoder)
            }
            try SQLiteStore.execute(database, """
            INSERT INTO optimization_plans (
                id, project_id, source_artifact_id, objective_json,
                pruning_configuration_json, quantization_recipe_id,
                estimated_result_json, validation_status, schema_version,
                created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                project_id=excluded.project_id,
                source_artifact_id=excluded.source_artifact_id,
                objective_json=excluded.objective_json,
                pruning_configuration_json=excluded.pruning_configuration_json,
                quantization_recipe_id=excluded.quantization_recipe_id,
                estimated_result_json=excluded.estimated_result_json,
                validation_status=excluded.validation_status,
                schema_version=excluded.schema_version,
                updated_at=excluded.updated_at
            WHERE excluded.updated_at >= optimization_plans.updated_at;
            """, bindings: [
                .text(plan.id.rawValue), .text(plan.projectID.rawValue),
                .text(plan.sourceArtifactID.rawValue), .text(objectiveJSON),
                .text(pruningJSON),
                plan.quantizationRecipe.map { .text($0.id.rawValue) } ?? .null,
                estimateJSON.map(SQLiteValue.text) ?? .null,
                .text(plan.validation.status.rawValue), .integer(Int64(plan.schemaVersion)),
                .real(plan.createdAt.timeIntervalSince1970),
                .real(plan.updatedAt.timeIntervalSince1970),
            ])
        }
    }

    public func plan(id: OptimizationPlanID) throws -> OptimizationPlan? {
        try plans(predicate: "WHERE p.id=?", bindings: [.text(id.rawValue)]).first
    }

    public func plans(projectID: ModelProjectID? = nil) throws -> [OptimizationPlan] {
        if let projectID {
            return try plans(
                predicate: "WHERE p.project_id=?",
                bindings: [.text(projectID.rawValue)]
            )
        }
        return try plans(predicate: "", bindings: [])
    }

    public func remove(_ identifiers: Set<OptimizationPlanID>) throws {
        guard !identifiers.isEmpty else { return }
        try store.transaction { database in
            for identifier in identifiers {
                try SQLiteStore.execute(
                    database,
                    "DELETE FROM optimization_plans WHERE id=?;",
                    bindings: [.text(identifier.rawValue)]
                )
            }
        }
    }

    private func plans(
        predicate: String,
        bindings: [SQLiteValue]
    ) throws -> [OptimizationPlan] {
        try store.read { database in
            let sql = """
            SELECT p.id, p.project_id, p.source_artifact_id, p.objective_json,
                   p.pruning_configuration_json, p.estimated_result_json,
                   p.validation_status, p.schema_version, p.created_at, p.updated_at,
                   q.id, q.name, q.technology, q.profile, q.calibration_suite_id,
                   q.tensor_role_rules_json, q.schema_version
            FROM optimization_plans p
            LEFT JOIN quantization_recipes q ON q.id=p.quantization_recipe_id
            \(predicate)
            ORDER BY p.updated_at DESC, p.id ASC;
            """
            var statement: OpaquePointer?
            try SQLiteStore.prepare(database, sql, statement: &statement)
            defer { sqlite3_finalize(statement) }
            try SQLiteStore.bind(bindings, to: statement, database: database, sql: sql)
            let decoder = Self.decoder()
            var result: [OptimizationPlan] = []
            while true {
                let step = sqlite3_step(statement)
                if step == SQLITE_DONE { return result }
                guard step == SQLITE_ROW else { throw SQLiteStore.error(database, step, sql) }
                guard
                    let id = OptimizationPlanID(rawValue: SQLiteStore.text(statement, 0)),
                    let projectID = ModelProjectID(rawValue: SQLiteStore.text(statement, 1)),
                    let artifactID = ModelArtifactID(rawValue: SQLiteStore.text(statement, 2)),
                    let status = PlanValidationStatus(rawValue: SQLiteStore.text(statement, 6))
                else { continue }
                let objective = try decoder.decode(
                    OptimizationObjective.self,
                    from: Data(SQLiteStore.text(statement, 3).utf8)
                )
                let pruning = try decoder.decode(
                    PersistedPruningConfiguration.self,
                    from: Data(SQLiteStore.text(statement, 4).utf8)
                )
                let estimate = try SQLiteStore.optionalText(statement, 5).map {
                    try decoder.decode(OptimizationEstimate.self, from: Data($0.utf8))
                }
                let recipe = try Self.readRecipe(statement, decoder: decoder)
                result.append(OptimizationPlan(
                    id: id,
                    projectID: projectID,
                    sourceArtifactID: artifactID,
                    objective: objective,
                    strategy: pruning.strategy,
                    pruningConstraints: pruning.constraints,
                    strategyProposedRemovals: pruning.strategyProposedRemovals,
                    expertDirectives: pruning.expertDirectives,
                    quantizationRecipe: recipe,
                    estimate: estimate,
                    validation: PlanValidationResult(
                        status: status,
                        errors: pruning.validationErrors,
                        warnings: pruning.validationWarnings
                    ),
                    schemaVersion: Int(sqlite3_column_int64(statement, 7)),
                    createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 8)),
                    updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 9))
                ))
            }
        }
    }

    private static func upsert(
        _ recipe: QuantizationRecipe,
        createdAt: Date,
        database: OpaquePointer,
        encoder: JSONEncoder
    ) throws {
        let rules = try string(encoder.encode(recipe.tensorRoleRules))
        try SQLiteStore.execute(database, """
        INSERT INTO quantization_recipes (
            id, name, technology, profile, tensor_role_rules_json,
            calibration_suite_id, schema_version, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name=excluded.name, technology=excluded.technology,
            profile=excluded.profile,
            tensor_role_rules_json=excluded.tensor_role_rules_json,
            calibration_suite_id=excluded.calibration_suite_id,
            schema_version=excluded.schema_version;
        """, bindings: [
            .text(recipe.id.rawValue), .text(recipe.name),
            .text(recipe.technology.rawValue), .text(recipe.profile), .text(rules),
            recipe.calibrationSuiteID.map { .text($0.rawValue) } ?? .null,
            .integer(Int64(recipe.schemaVersion)), .real(createdAt.timeIntervalSince1970),
        ])
    }

    private static func readRecipe(
        _ statement: OpaquePointer?,
        decoder: JSONDecoder
    ) throws -> QuantizationRecipe? {
        guard let rawID = SQLiteStore.optionalText(statement, 10),
              let id = QuantizationRecipeID(rawValue: rawID),
              let technology = QuantizationTechnology(
                rawValue: SQLiteStore.text(statement, 12)
              ) else { return nil }
        let rules = try decoder.decode(
            [String: String].self,
            from: Data(SQLiteStore.text(statement, 15).utf8)
        )
        return QuantizationRecipe(
            id: id,
            name: SQLiteStore.text(statement, 11),
            technology: technology,
            profile: SQLiteStore.text(statement, 13),
            calibrationSuiteID: SQLiteStore.optionalText(statement, 14)
                .flatMap(EvaluationSuiteID.init(rawValue:)),
            tensorRoleRules: rules,
            schemaVersion: Int(sqlite3_column_int64(statement, 16))
        )
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func string(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw OptimizationPlanRepositoryError.invalidUTF8
        }
        return value
    }
}

public enum OptimizationPlanRepositoryError: Error, Equatable, Sendable {
    case invalidUTF8
}

private struct PersistedPruningConfiguration: Codable {
    let strategy: StrategyDescriptor?
    let constraints: PruningConstraints
    let strategyProposedRemovals: Set<ExpertCoordinate>?
    let expertDirectives: [ExpertDirective]
    let validationErrors: [String]
    let validationWarnings: [String]

    init(_ plan: OptimizationPlan) {
        strategy = plan.strategy
        constraints = plan.pruningConstraints
        strategyProposedRemovals = plan.strategyProposedRemovals
        expertDirectives = plan.expertDirectives
        validationErrors = plan.validation.errors
        validationWarnings = plan.validation.warnings
    }
}
