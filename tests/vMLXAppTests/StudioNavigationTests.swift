import XCTest
@testable import vMLXApp

final class StudioNavigationTests: XCTestCase {
    func testPrimaryNavigationIsStableAcrossExperienceModes() {
        let expected: [AppState.Mode] = [.home, .chat, .models, .optimize, .evaluate]
        XCTAssertEqual(AppState.Mode.visible(for: .beginner), expected)
        XCTAssertEqual(AppState.Mode.visible(for: .advanced), expected)
    }

    func testSecondaryNavigationDoesNotPromoteAdvancedTools() {
        XCTAssertEqual(AppState.Mode.secondary(for: .beginner), [.create])
        XCTAssertEqual(AppState.Mode.secondary(for: .advanced), [.create, .server, .diagnostics])
    }

    func testEveryModeAppearsInExactlyOneNavigationGroup() {
        let primary = Set(AppState.Mode.visible(for: .advanced))
        let secondary = Set(AppState.Mode.secondary(for: .advanced))
        XCTAssertTrue(primary.isDisjoint(with: secondary))
        XCTAssertEqual(primary.union(secondary), Set(AppState.Mode.allCases))
    }

    func testUnifiedMemoryProbeNeverExceedsPhysicalMemory() {
        let snapshot = StudioUnifiedMemorySnapshot.current()
        XCTAssertGreaterThan(snapshot.totalBytes, 0)
        XCTAssertLessThanOrEqual(snapshot.availableBytes, snapshot.totalBytes)
    }
}
