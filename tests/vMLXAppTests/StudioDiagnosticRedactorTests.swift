import Foundation
import XCTest
@testable import vMLXApp

final class StudioDiagnosticRedactorTests: XCTestCase {
    func testRedactsTokensBearerValuesAndHomePath() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/Users/hermes"
        let raw = """
        failed token=hf_smokesecret123456 at \(home)/models/private \
        Authorization: Bearer smoke-secret-123456 api_key=plain-secret
        """

        let redacted = StudioDiagnosticRedactor.redact(raw)

        XCTAssertFalse(redacted.contains(home))
        XCTAssertFalse(redacted.contains("hf_smokesecret123456"))
        XCTAssertFalse(redacted.contains("smoke-secret-123456"))
        XCTAssertFalse(redacted.contains("plain-secret"))
        XCTAssertTrue(redacted.contains("~/models/private"))
        XCTAssertTrue(redacted.contains("token=[redacted]"))
        XCTAssertTrue(redacted.contains("Bearer [redacted]"))
        XCTAssertTrue(redacted.contains("api_key=[redacted]"))
    }

    func testDiagnosticBriefIncludesRedactedRecoveryPath() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/Users/hermes"
        let issue = StudioDiagnosticIssue(
            source: .chatStream,
            severity: .error,
            title: "Smoke diagnostic issue",
            message: "Smoke stream failed token=hf_smokesecret123456",
            context: "Smoke Model at \(home)/private/model Authorization: Bearer smoke-secret-123456"
        )

        let brief = StudioDiagnosticBriefFormatter.incidentBrief(for: issue, openIssueCount: 2)

        XCTAssertTrue(brief.contains("MLX Studio Diagnostics Brief"))
        XCTAssertTrue(brief.contains("Recorded:"))
        XCTAssertTrue(brief.contains("Freshness: Fresh -"))
        XCTAssertTrue(brief.contains("Message: Smoke stream failed token=[redacted]"))
        XCTAssertTrue(brief.contains("MLX Studio Recovery Path"))
        XCTAssertTrue(brief.contains("1. Confirm impact: Workflow blocked (Gate retry or continue)"))
        XCTAssertTrue(brief.contains("2. Inspect evidence: Smoke Model at ~/private/model Authorization: Bearer [redacted] (Match source against logs)"))
        XCTAssertTrue(brief.contains("Recovery action: Manual only - use Chat Retry; no prompt is resent here"))
        XCTAssertTrue(brief.contains("3. Execute move: Retry or inspect logs (Manual only - use Chat Retry; no prompt is resent here)"))
        XCTAssertTrue(brief.contains("Open issues: 2"))
        XCTAssertFalse(brief.contains(home))
        XCTAssertFalse(brief.contains("hf_smokesecret123456"))
        XCTAssertFalse(brief.contains("smoke-secret-123456"))
    }

    func testRecoveryPathFormatterReturnsCopyableSteps() {
        let issue = StudioDiagnosticIssue(
            source: .server,
            severity: .warning,
            title: "Server binding issue",
            message: "Port busy",
            context: "127.0.0.1:8080"
        )

        let steps = StudioDiagnosticBriefFormatter.recoverySteps(for: issue)
        let recoveryPath = StudioDiagnosticBriefFormatter.recoveryPath(for: issue)

        XCTAssertEqual(steps.map(\.title), ["Confirm impact", "Inspect evidence", "Execute move"])
        XCTAssertEqual(steps.first?.value, "Needs attention")
        XCTAssertEqual(steps.last?.value, "Check binding")
        XCTAssertEqual(steps.last?.caption, "Safe command: lsof -nP -iTCP:8080 -sTCP:LISTEN")
        XCTAssertTrue(steps[1].isEvidence)
        XCTAssertTrue(recoveryPath.contains("MLX Studio Recovery Path"))
        XCTAssertTrue(recoveryPath.contains("3. Execute move: Check binding (Safe command: lsof -nP -iTCP:8080 -sTCP:LISTEN)"))
    }

    func testFreshnessFormatterLabelsFreshAndStaleIssues() {
        let referenceDate = Date(timeIntervalSinceReferenceDate: 20_000)
        let fresh = StudioDiagnosticIssue(
            source: .chatStream,
            severity: .error,
            title: "Fresh issue",
            message: "Stream failed",
            context: "Smoke model",
            createdAt: referenceDate.addingTimeInterval(-120)
        )
        let stale = StudioDiagnosticIssue(
            source: .server,
            severity: .warning,
            title: "Stale issue",
            message: "Port busy",
            context: "127.0.0.1:8080",
            createdAt: referenceDate.addingTimeInterval(-3_600)
        )

        XCTAssertEqual(
            StudioDiagnosticBriefFormatter.freshnessLabel(for: fresh, relativeTo: referenceDate),
            "Fresh"
        )
        XCTAssertEqual(
            StudioDiagnosticBriefFormatter.freshnessText(for: fresh, relativeTo: referenceDate),
            "Fresh - 2 min old"
        )
        XCTAssertEqual(
            StudioDiagnosticBriefFormatter.freshnessLabel(for: stale, relativeTo: referenceDate),
            "Stale"
        )
        XCTAssertEqual(
            StudioDiagnosticBriefFormatter.freshnessText(for: stale, relativeTo: referenceDate),
            "Stale - 1 hr old"
        )
    }

    func testAdvancedModelsRecoveryPathUsesSafeNoOp() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/Users/hermes"
        let issue = StudioDiagnosticIssue(
            source: .advancedModels,
            severity: .error,
            title: "Model tools benchmark failed",
            message: "Decode failed token=hf_smokesecret123456",
            context: "Qwen smoke at \(home)/models/qwen Authorization: Bearer smoke-secret-123456"
        )

        let brief = StudioDiagnosticBriefFormatter.incidentBrief(for: issue, openIssueCount: 1)

        XCTAssertTrue(brief.contains("Source: Model Tools"))
        XCTAssertTrue(brief.contains("Message: Decode failed token=[redacted]"))
        XCTAssertTrue(brief.contains("Evidence: Qwen smoke at ~/models/qwen Authorization: Bearer [redacted]"))
        XCTAssertTrue(brief.contains("Next move: Review job output"))
        XCTAssertTrue(brief.contains("Recovery action: Safe no-op - open the Models > Model Tools job row; no model files are changed"))
        XCTAssertTrue(brief.contains("3. Execute move: Review job output (Safe no-op - open the Models > Model Tools job row; no model files are changed)"))
        XCTAssertFalse(brief.contains(home))
        XCTAssertFalse(brief.contains("hf_smokesecret123456"))
        XCTAssertFalse(brief.contains("smoke-secret-123456"))
    }

    func testMissingImageFrameworkRecoveryExplainsTheActualBlocker() {
        let issue = StudioDiagnosticIssue(
            source: .imageGeneration,
            severity: .error,
            title: "mflux runtime failed",
            message: "Python.framework/Versions/3.14/Python is missing",
            context: "mflux-venv/bin/python3.14"
        )

        let steps = StudioDiagnosticBriefFormatter.recoverySteps(for: issue)

        XCTAssertEqual(steps.last?.value, "Repair image runtime")
        XCTAssertTrue(steps.last?.caption.contains("Reinstall the current signed MLX Studio build") == true)
        XCTAssertTrue(steps.last?.caption.contains("refresh Create proof") == true)
    }

    func testDiagnosticIssueStoreLoadsNewestIssueFirst() throws {
        StudioDiagnosticIssueStore.clear()
        defer { StudioDiagnosticIssueStore.clear() }

        let older = StudioDiagnosticIssue(
            source: .server,
            severity: .warning,
            title: "Older server issue",
            message: "Port busy",
            context: "127.0.0.1:8000",
            createdAt: Date(timeIntervalSinceReferenceDate: 100)
        )
        let newer = StudioDiagnosticIssue(
            source: .chatStream,
            severity: .error,
            title: "Newest chat issue",
            message: "Stream failed",
            context: "Smoke model",
            createdAt: Date(timeIntervalSinceReferenceDate: 200)
        )
        let encoded = try JSONEncoder().encode([older, newer])

        UserDefaults.standard.set(encoded, forKey: StudioDiagnosticIssueStore.storageKey)

        let loaded = StudioDiagnosticIssueStore.load(limit: 2)
        XCTAssertEqual(loaded.map(\.title), ["Newest chat issue", "Older server issue"])
    }

    func testAdvancedModelDiagnosticRecordsRedactedSource() {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? "/Users/hermes"
        StudioDiagnosticIssueStore.clear()
        defer { StudioDiagnosticIssueStore.clear() }

        let issue = StudioModelToolsDiagnostic.recordFailure(
            kind: .benchmark,
            model: ModelRef(
                id: "qwen-smoke",
                displayName: "Qwen smoke",
                repo: nil,
                localURL: URL(fileURLWithPath: "\(home)/models/qwen")
            ),
            message: "Benchmark failed token=hf_smokesecret123456"
        )
        let loaded = StudioDiagnosticIssueStore.load(limit: 1)

        XCTAssertEqual(issue.source, .advancedModels)
        XCTAssertEqual(issue.title, "Model tools benchmark failed")
        XCTAssertTrue(issue.redactedMessage.contains("token=[redacted]"))
        XCTAssertTrue(issue.redactedCompactContext.contains("Qwen smoke at ~/models/qwen"))
        XCTAssertFalse(issue.redactedCompactContext.contains(home))
        XCTAssertEqual(loaded.first?.source, .advancedModels)
        XCTAssertEqual(loaded.first?.title, "Model tools benchmark failed")
    }
}
