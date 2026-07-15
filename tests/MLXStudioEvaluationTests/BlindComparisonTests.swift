import Foundation
import MLXStudioDomain
import MLXStudioPersistence
import XCTest
@testable import MLXStudioEvaluation

final class BlindComparisonTests: XCTestCase {
    func testAssignmentIsSeededDeterministicAndBalancedAcrossCases() throws {
        let first = ModelArtifactID()
        let second = ModelArtifactID()
        let cases = (0..<7).map {
            EvaluationCase(
                ordinal: $0,
                name: "Case \($0)",
                messages: [.init(role: .user, content: "Prompt \($0)")]
            )
        }

        let assignments = try BlindAssignmentPlanner.assignments(
            candidateIDs: [first, second],
            cases: cases,
            seed: 0x1234
        )
        let repeated = try BlindAssignmentPlanner.assignments(
            candidateIDs: [first, second],
            cases: cases,
            seed: 0x1234
        )

        XCTAssertEqual(assignments, repeated)
        XCTAssertEqual(assignments.count, cases.count)
        let firstAsA = assignments.values.filter { $0.responseAArtifactID == first }.count
        let secondAsA = assignments.values.filter { $0.responseAArtifactID == second }.count
        XCTAssertLessThanOrEqual(abs(firstAsA - secondAsA), 1)
        for assignment in assignments.values {
            XCTAssertNotEqual(assignment.responseAArtifactID, assignment.responseBArtifactID)
            XCTAssertEqual(
                Set([assignment.responseAArtifactID, assignment.responseBArtifactID]),
                Set([first, second])
            )
        }
    }

    func testRevealRequiresChoiceAndPreservesWinnerMapping() throws {
        let assignment = BlindAssignment(
            responseAArtifactID: ModelArtifactID(),
            responseBArtifactID: ModelArtifactID(),
            assignmentSeed: 42,
            ordinal: 0
        )
        let pending = HumanJudgment(
            runID: EvaluationRunID(),
            caseID: EvaluationCaseID(),
            assignment: assignment
        )

        XCTAssertThrowsError(try BlindJudgmentWorkflow.revealing(pending)) { error in
            XCTAssertEqual(error as? BlindComparisonError, .revealRequiresJudgment)
        }
        let chosen = BlindJudgmentWorkflow.choosing(.responseB, in: pending, notes: "Clearer")
        let revealDate = Date(timeIntervalSince1970: 500)
        let revealed = try BlindJudgmentWorkflow.revealing(chosen, at: revealDate)

        XCTAssertEqual(revealed.choice, .responseB)
        XCTAssertEqual(revealed.notes, "Clearer")
        XCTAssertEqual(revealed.revealedAt, revealDate)
        XCTAssertEqual(
            revealed.assignment.artifactID(for: try XCTUnwrap(revealed.choice)),
            assignment.responseBArtifactID
        )
    }

    func testJudgmentAndRevealPersistAcrossRepositoryRestart() throws {
        let context = try makeContext()
        defer { try? FileManager.default.removeItem(at: context.root) }
        let suite = try QuickCompareSuiteFactory.singlePrompt(
            prompt: "Which response is better?",
            generationConfiguration: .init(maximumTokenCount: 32, seed: 42)
        )
        let request = EvaluationRunRequest(
            suite: suite,
            candidates: [
                .init(artifactID: context.first.id, blindLabel: "Response A"),
                .init(artifactID: context.second.id, blindLabel: "Response B"),
            ],
            executionOrder: [context.first.id, context.second.id]
        )
        let repository = try EvaluationRepository(databaseURL: context.databaseURL)
        let manifest = try EvaluationManifestBuilder.build(for: request)
        try repository.saveRun(request: request, manifest: manifest, status: .completed)
        let evaluationCase = try XCTUnwrap(suite.cases.first)
        let assignment = try XCTUnwrap(BlindAssignmentPlanner.assignments(
            candidateIDs: [context.first.id, context.second.id],
            cases: suite.cases,
            seed: UInt64.max
        )[evaluationCase.id])
        let pending = HumanJudgment(
            runID: request.id,
            caseID: evaluationCase.id,
            assignment: assignment,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        try repository.saveHumanJudgment(pending)

        var reopened = try EvaluationRepository(databaseURL: context.databaseURL)
        XCTAssertEqual(try reopened.humanJudgment(
            runID: request.id,
            caseID: evaluationCase.id
        ), pending)

        let chosen = BlindJudgmentWorkflow.choosing(.responseA, in: pending, notes: "Preferred")
        try reopened.saveHumanJudgment(chosen)
        reopened = try EvaluationRepository(databaseURL: context.databaseURL)
        let storedChoice = try XCTUnwrap(reopened.humanJudgment(
            runID: request.id,
            caseID: evaluationCase.id
        ))
        XCTAssertEqual(storedChoice.choice, .responseA)
        XCTAssertNil(storedChoice.revealedAt)

        let revealed = try BlindJudgmentWorkflow.revealing(
            storedChoice,
            at: Date(timeIntervalSince1970: 200)
        )
        try reopened.saveHumanJudgment(revealed)
        reopened = try EvaluationRepository(databaseURL: context.databaseURL)
        XCTAssertEqual(try reopened.humanJudgment(
            runID: request.id,
            caseID: evaluationCase.id
        ), revealed)
        XCTAssertEqual(try reopened.humanJudgments(runID: request.id), [revealed])

        let postRevealMutation = BlindJudgmentWorkflow.choosing(.responseB, in: revealed)
        XCTAssertThrowsError(try reopened.saveHumanJudgment(postRevealMutation))

        let conflicting = HumanJudgment(
            id: pending.id,
            runID: request.id,
            caseID: evaluationCase.id,
            assignment: .init(
                responseAArtifactID: assignment.responseBArtifactID,
                responseBArtifactID: assignment.responseAArtifactID,
                assignmentSeed: assignment.assignmentSeed,
                ordinal: assignment.ordinal
            ),
            choice: .responseA,
            createdAt: pending.createdAt
        )
        XCTAssertThrowsError(try reopened.saveHumanJudgment(conflicting))
    }
}

private extension BlindComparisonTests {
    struct Context {
        let root: URL
        let databaseURL: URL
        let first: ModelArtifact
        let second: ModelArtifact
    }

    func makeContext() throws -> Context {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("blind-comparison-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let databaseURL = root.appendingPathComponent("models.sqlite3")
        let artifacts = try ModelArtifactRepository(databaseURL: databaseURL)
        for (id, name) in [("blind-first", "First"), ("blind-second", "Second")] {
            let url = root.appendingPathComponent(id, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try artifacts.upsertIndexedModel(.init(
                legacyModelID: id,
                canonicalURL: url,
                displayName: name,
                family: "fixture",
                modality: "text",
                totalSizeBytes: 100,
                isJANG: false,
                isJANGTQ: false,
                quantizationBits: nil,
                detectedAt: Date(),
                source: "test",
                capabilitiesJSON: "{}"
            ))
        }
        return Context(
            root: root,
            databaseURL: databaseURL,
            first: try XCTUnwrap(artifacts.artifact(legacyModelID: "blind-first")),
            second: try XCTUnwrap(artifacts.artifact(legacyModelID: "blind-second"))
        )
    }
}
