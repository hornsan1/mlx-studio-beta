import Foundation
import XCTest
@testable import vMLXApp

@MainActor
final class StudioJobServiceTests: XCTestCase {
    func testInspectJobLifecycleAppearsInQueue() async throws {
        let service = StudioJobService()
        let model = ModelRef(
            id: "smoke-model",
            displayName: "Smoke Model",
            repo: nil,
            localURL: URL(fileURLWithPath: "/tmp/smoke-model")
        )

        let id = service.start(
            kind: .inspect,
            model: model,
            message: "Queued inspection"
        )
        service.update(
            id,
            status: .completed,
            progress: 1,
            message: "Inspection completed"
        )

        let jobs = try await service.listJobs()
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs.first?.kind, .inspect)
        XCTAssertEqual(jobs.first?.status, .completed)
        XCTAssertEqual(jobs.first?.message, "Inspection completed")
    }
}
