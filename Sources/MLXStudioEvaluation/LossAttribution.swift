import Foundation
import MLXStudioDomain

public enum LossAttributionError: Error, Equatable, LocalizedError, Sendable {
    case duplicateVariant(LossAttributionVariant)
    case duplicateArtifact(ModelArtifactID)
    case observationDoesNotMatchPlan(LossAttributionVariant, ModelArtifactID)

    public var errorDescription: String? {
        switch self {
        case .duplicateVariant(let variant):
            return "Loss Attribution variant \(variant.code) is assigned more than once."
        case .duplicateArtifact(let artifactID):
            return "Loss Attribution artifact \(artifactID.rawValue) is assigned to multiple variants."
        case .observationDoesNotMatchPlan(let variant, let artifactID):
            return "Observation \(variant.code) does not match planned artifact \(artifactID.rawValue)."
        }
    }
}

public enum LossAttributionPlanner {
    public static func plan(
        artifacts: [LossAttributionArtifact]
    ) throws -> LossAttributionExperimentPlan {
        if let duplicate = duplicate(in: artifacts.map(\.variant)) {
            throw LossAttributionError.duplicateVariant(duplicate)
        }
        if let duplicate = duplicate(in: artifacts.map(\.artifactID)) {
            throw LossAttributionError.duplicateArtifact(duplicate)
        }
        let ordered = artifacts.sorted { lhs, rhs in
            variantOrder(lhs.variant) < variantOrder(rhs.variant)
        }
        let assigned = Set(ordered.map(\.variant))
        let missing = LossAttributionVariant.allCases.filter { !assigned.contains($0) }
        let comparisons = LossAttributionComparisonKind.allCases.map { kind in
            LossAttributionComparisonPlan(
                kind: kind,
                state: state(
                    hasSource: assigned.contains(kind.sourceVariant),
                    hasTarget: assigned.contains(kind.targetVariant)
                )
            )
        }
        return LossAttributionExperimentPlan(
            artifacts: ordered,
            comparisons: comparisons,
            missingVariants: missing,
            usesFullMatrix: missing.isEmpty
        )
    }

    public static func candidates(
        for plan: LossAttributionExperimentPlan
    ) -> [EvaluationCandidate] {
        plan.artifacts.map { artifact in
            EvaluationCandidate(
                artifactID: artifact.artifactID,
                blindLabel: "\(artifact.variant.code) — \(artifact.variant.displayName)",
                artifactHash: artifact.artifactHash
            )
        }
    }

    private static func state(
        hasSource: Bool,
        hasTarget: Bool
    ) -> LossAttributionMeasurementState {
        switch (hasSource, hasTarget) {
        case (true, true): .notEvaluated
        case (false, true): .missingSource
        case (true, false): .missingTarget
        case (false, false): .missingBoth
        }
    }
}

public enum LossAttributionLineageValidator {
    public static func issue(
        assignments: [LossAttributionVariant: ModelArtifact],
        artifactUniverse: [ModelArtifact]
    ) -> String? {
        let selected = Array(assignments.values)
        guard let projectID = selected.first?.projectID else { return nil }
        guard selected.allSatisfy({ $0.projectID == projectID }) else {
            return "All Loss Attribution variants must belong to one canonical model project."
        }

        for (variant, artifact) in assignments {
            let expectedQuantized = variant == .baseQuantized || variant == .prunedQuantized
            if expectedQuantized != isQuantized(artifact) {
                return "Variant \(variant.code) does not match its required precision role."
            }
        }

        if let a = assignments[.baseOriginalPrecision] {
            if let b = assignments[.baseQuantized],
               !isDescendant(b, of: a, universe: artifactUniverse) {
                return "Variant B must be a verified quantized descendant of variant A."
            }
            if let c = assignments[.prunedOriginalPrecision],
               !isDescendant(c, of: a, universe: artifactUniverse) {
                return "Variant C must be a verified pruned descendant of variant A."
            }
            if assignments[.prunedOriginalPrecision] == nil,
               let d = assignments[.prunedQuantized],
               !isDescendant(d, of: a, universe: artifactUniverse) {
                return "Variant D must descend from variant A through verified lineage."
            }
        }
        if let c = assignments[.prunedOriginalPrecision],
           let d = assignments[.prunedQuantized],
           !isDescendant(d, of: c, universe: artifactUniverse) {
            return "Variant D must be a verified quantized descendant of variant C."
        }
        return nil
    }

    private static func isQuantized(_ artifact: ModelArtifact) -> Bool {
        if artifact.format == .jang || artifact.format == .jangTQ { return true }
        guard let precision = artifact.precision?.rawValue.lowercased() else { return false }
        if ["bf16", "bfloat16", "fp16", "float16", "fp32", "float32"].contains(precision) {
            return false
        }
        return precision.contains("bit") || precision.contains("jang")
    }

    private static func isDescendant(
        _ candidate: ModelArtifact,
        of ancestor: ModelArtifact,
        universe: [ModelArtifact]
    ) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: universe.map { ($0.id, $0) })
        var parentID = candidate.parentArtifactID
        var visited: Set<ModelArtifactID> = []
        while let current = parentID, visited.insert(current).inserted {
            if current == ancestor.id { return true }
            parentID = byID[current]?.parentArtifactID
        }
        return false
    }
}

public enum LossAttributionObservationBuilder {
    public static func build(
        plan: LossAttributionExperimentPlan,
        outcome: PromptSuiteOutcome,
        artifactSizeBytes: [ModelArtifactID: Int64] = [:]
    ) -> [LossAttributionObservation] {
        plan.artifacts.map { assignment in
            let scorecard = outcome.scorecards.first {
                $0.artifactID == assignment.artifactID
            }
            let results = outcome.result.caseResults.filter {
                $0.artifactID == assignment.artifactID
            }
            let peakMemory = results.compactMap {
                $0.generationResult?.metrics.peakMemoryBytes
            }.max()
            let rate: Double?
            if let scorecard, scorecard.totalDurationSeconds > 0 {
                rate = Double(scorecard.generatedTokenCount) / scorecard.totalDurationSeconds
            } else {
                rate = nil
            }
            return LossAttributionObservation(
                variant: assignment.variant,
                artifactID: assignment.artifactID,
                qualityScore: scorecard?.overall.weightedScore,
                artifactSizeBytes: artifactSizeBytes[assignment.artifactID],
                peakMemoryBytes: peakMemory,
                generatedTokensPerSecond: rate
            )
        }
    }
}

public enum LossAttributionReportBuilder {
    public static func build(
        runID: EvaluationRunID,
        plan: LossAttributionExperimentPlan,
        observations: [LossAttributionObservation],
        judgments: [HumanJudgment] = []
    ) throws -> LossAttributionReport {
        if let duplicate = duplicate(in: observations.map(\.variant)) {
            throw LossAttributionError.duplicateVariant(duplicate)
        }
        let planned = Dictionary(uniqueKeysWithValues: plan.artifacts.map {
            ($0.variant, $0)
        })
        for observation in observations {
            guard planned[observation.variant]?.artifactID == observation.artifactID else {
                throw LossAttributionError.observationDoesNotMatchPlan(
                    observation.variant,
                    observation.artifactID
                )
            }
        }
        let observed = Dictionary(uniqueKeysWithValues: observations.map {
            ($0.variant, $0)
        })
        let reports = plan.comparisons.map { comparison -> LossAttributionComparisonReport in
            let kind = comparison.kind
            guard comparison.state == .notEvaluated else {
                return LossAttributionComparisonReport(
                    kind: kind,
                    state: comparison.state
                )
            }
            guard let source = observed[kind.sourceVariant],
                  let target = observed[kind.targetVariant]
            else {
                return LossAttributionComparisonReport(
                    kind: kind,
                    state: .notEvaluated,
                    humanPreference: humanPreference(
                        kind: kind,
                        planned: planned,
                        judgments: judgments
                    )
                )
            }
            let quality = source.qualityScore.flatMap { sourceScore in
                target.qualityScore.map {
                    LossAttributionQualityReport(
                        sourceScore: sourceScore,
                        targetScore: $0
                    )
                }
            }
            let performance = performance(source: source, target: target)
            return LossAttributionComparisonReport(
                kind: kind,
                state: .measured,
                quality: quality,
                performance: performance,
                humanPreference: humanPreference(
                    kind: kind,
                    planned: planned,
                    judgments: judgments
                )
            )
        }
        let byKind = Dictionary(uniqueKeysWithValues: reports.map { ($0.kind, $0) })
        let quantizedAfterPruning = byKind[.quantizationAfterPruning]?.quality?.change
        let baseQuantization = byKind[.baseQuantization]?.quality?.change
        let interaction: Double?
        if let quantizedAfterPruning, let baseQuantization {
            interaction = quantizedAfterPruning - baseQuantization
        } else {
            interaction = nil
        }
        return LossAttributionReport(
            runID: runID,
            plan: plan,
            comparisons: reports,
            qualityInteractionEffect: interaction
        )
    }

    private static func performance(
        source: LossAttributionObservation,
        target: LossAttributionObservation
    ) -> LossAttributionPerformanceReport? {
        let storage = savings(source.artifactSizeBytes, target.artifactSizeBytes)
        let memory = savings(source.peakMemoryBytes, target.peakMemoryBytes)
        let rate = change(source.generatedTokensPerSecond, target.generatedTokensPerSecond)
        guard storage != nil || memory != nil || rate != nil else { return nil }
        return LossAttributionPerformanceReport(
            storageSavingsFraction: storage,
            peakMemorySavingsFraction: memory,
            generationRateChangeFraction: rate
        )
    }

    private static func humanPreference(
        kind: LossAttributionComparisonKind,
        planned: [LossAttributionVariant: LossAttributionArtifact],
        judgments: [HumanJudgment]
    ) -> LossAttributionHumanPreferenceReport {
        guard let sourceID = planned[kind.sourceVariant]?.artifactID,
              let targetID = planned[kind.targetVariant]?.artifactID
        else { return .init() }
        var source = 0
        var target = 0
        var ties = 0
        var bothFailed = 0
        for judgment in judgments where
            Set([
                judgment.assignment.responseAArtifactID,
                judgment.assignment.responseBArtifactID,
            ]) == Set([sourceID, targetID])
        {
            switch judgment.choice {
            case .responseA, .responseB:
                let preferred = judgment.choice.flatMap {
                    judgment.assignment.artifactID(for: $0)
                }
                if preferred == sourceID { source += 1 }
                if preferred == targetID { target += 1 }
            case .tie:
                ties += 1
            case .bothFailed:
                bothFailed += 1
            case nil:
                break
            }
        }
        return LossAttributionHumanPreferenceReport(
            sourcePreferredCount: source,
            targetPreferredCount: target,
            tieCount: ties,
            bothFailedCount: bothFailed
        )
    }
}

private func variantOrder(_ variant: LossAttributionVariant) -> Int {
    LossAttributionVariant.allCases.firstIndex(of: variant) ?? .max
}

private func duplicate<Value: Hashable>(in values: [Value]) -> Value? {
    var seen: Set<Value> = []
    return values.first { !seen.insert($0).inserted }
}

private func savings(_ source: Int64?, _ target: Int64?) -> Double? {
    guard let source, source > 0, let target else { return nil }
    return Double(source - target) / Double(source)
}

private func change(_ source: Double?, _ target: Double?) -> Double? {
    guard let source, source != 0, let target else { return nil }
    return (target - source) / source
}
