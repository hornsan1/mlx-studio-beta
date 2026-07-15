import Foundation
import MLXStudioDomain

public enum BlindComparisonError: Error, Equatable, LocalizedError, Sendable {
    case requiresTwoCandidates(Int)
    case duplicateCandidate(ModelArtifactID)
    case revealRequiresJudgment

    public var errorDescription: String? {
        switch self {
        case .requiresTwoCandidates(let count):
            return "Blind A/B requires exactly two candidates; found \(count)."
        case .duplicateCandidate(let id):
            return "Blind A/B candidate \(id.rawValue) is duplicated."
        case .revealRequiresJudgment:
            return "Choose Response A, Response B, or Tie before revealing identities."
        }
    }
}

/// Produces a deterministic, randomized, balanced label assignment. Ordered
/// cases alternate which artifact is Response A, so exposure differs by at
/// most one case while the seed randomly determines who receives the first
/// position.
public enum BlindAssignmentPlanner {
    public static func assignments(
        candidateIDs: [ModelArtifactID],
        cases: [EvaluationCase],
        seed: UInt64
    ) throws -> [EvaluationCaseID: BlindAssignment] {
        guard candidateIDs.count == 2 else {
            throw BlindComparisonError.requiresTwoCandidates(candidateIDs.count)
        }
        guard candidateIDs[0] != candidateIDs[1] else {
            throw BlindComparisonError.duplicateCandidate(candidateIDs[0])
        }
        let orderedCases = cases.sorted {
            $0.ordinal == $1.ordinal
                ? $0.id.rawValue < $1.id.rawValue : $0.ordinal < $1.ordinal
        }
        let startsWithFirst = splitMix64(seed) & 1 == 0
        return Dictionary(uniqueKeysWithValues: orderedCases.enumerated().map { index, item in
            let firstIsA = index.isMultiple(of: 2) == startsWithFirst
            let assignment = BlindAssignment(
                responseAArtifactID: firstIsA ? candidateIDs[0] : candidateIDs[1],
                responseBArtifactID: firstIsA ? candidateIDs[1] : candidateIDs[0],
                assignmentSeed: seed,
                ordinal: index
            )
            return (item.id, assignment)
        })
    }

    private static func splitMix64(_ value: UInt64) -> UInt64 {
        var z = value &+ 0x9e3779b97f4a7c15
        z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
        z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
        return z ^ (z >> 31)
    }
}

public enum BlindJudgmentWorkflow {
    public static func choosing(
        _ choice: BlindResponseChoice,
        in judgment: HumanJudgment,
        notes: String? = nil
    ) -> HumanJudgment {
        HumanJudgment(
            id: judgment.id,
            runID: judgment.runID,
            caseID: judgment.caseID,
            assignment: judgment.assignment,
            choice: choice,
            notes: notes,
            revealedAt: judgment.revealedAt,
            createdAt: judgment.createdAt
        )
    }

    public static func revealing(
        _ judgment: HumanJudgment,
        at date: Date = .init()
    ) throws -> HumanJudgment {
        guard judgment.choice != nil else {
            throw BlindComparisonError.revealRequiresJudgment
        }
        return HumanJudgment(
            id: judgment.id,
            runID: judgment.runID,
            caseID: judgment.caseID,
            assignment: judgment.assignment,
            choice: judgment.choice,
            notes: judgment.notes,
            revealedAt: judgment.revealedAt ?? date,
            createdAt: judgment.createdAt
        )
    }
}
