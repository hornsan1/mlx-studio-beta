import XCTest
import vMLXEngine
@testable import vMLXApp

final class StudioServerLifecycleGuardTests: XCTestCase {
    func testLoadedChatEngineDoesNotImplyHTTPListenerHealth() {
        let health = StudioServerHealthResolver.resolve(
            engineState: .running,
            hasSessionProcess: false,
            httpRunning: false,
            httpError: nil
        )
        XCTAssertEqual(health.status, .stopped)
        XCTAssertEqual(health.label, "Stopped")
    }

    func testListenerAndRunningSessionAreBothRequiredForAcceptingState() {
        let health = StudioServerHealthResolver.resolve(
            engineState: .running,
            hasSessionProcess: true,
            httpRunning: true,
            httpError: nil
        )
        XCTAssertEqual(health.status, .running)
        XCTAssertEqual(health.label, "Running")
    }

    func testRunningSessionWithListenerIsStartSuccess() {
        XCTAssertNil(StudioServerLifecycleGuard.startFailureMessage(
            sessionState: .running,
            hasSessionProcess: true,
            httpRunning: true,
            httpError: nil
        ))
    }

    func testRunningEngineWithoutListenerIsFailure() {
        XCTAssertEqual(
            StudioServerLifecycleGuard.startFailureMessage(
                sessionState: .running,
                hasSessionProcess: false,
                httpRunning: false,
                httpError: nil
            ),
            "HTTP listener did not start."
        )
    }

    func testEngineLoadErrorBecomesFailureMessage() {
        XCTAssertEqual(
            StudioServerLifecycleGuard.startFailureMessage(
                sessionState: .error("Missing field 'hidden_size'"),
                hasSessionProcess: false,
                httpRunning: false,
                httpError: nil
            ),
            "Engine load failed: Missing field 'hidden_size'"
        )
    }

    func testHttpErrorWinsOverStaleSessionState() {
        XCTAssertEqual(
            StudioServerLifecycleGuard.startFailureMessage(
                sessionState: .running,
                hasSessionProcess: true,
                httpRunning: true,
                httpError: "port 8000 is already in use"
            ),
            "HTTP listener failed: port 8000 is already in use"
        )
    }
}
