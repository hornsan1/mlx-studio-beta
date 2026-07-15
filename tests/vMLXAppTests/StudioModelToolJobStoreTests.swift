import Foundation
import XCTest
@testable import vMLXApp

@MainActor
final class StudioModelToolJobStoreTests: XCTestCase {
    func testInspectJobLifecycleAppearsInQueue() async throws {
        let databaseURL = temporaryDatabaseURL()
        defer { removeDatabase(at: databaseURL) }
        let service = try StudioModelToolJobStore(databaseURL: databaseURL)
        let model = ModelRef(
            id: "smoke-model",
            displayName: "Smoke Model",
            repo: nil,
            localURL: URL(fileURLWithPath: "/tmp/smoke-model")
        )

        let id = try service.start(
            kind: .inspect,
            model: model,
            message: "Queued inspection"
        )
        try service.update(
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

        let restored = try StudioModelToolJobStore(databaseURL: databaseURL)
        let restoredJobs = try await restored.listJobs()
        XCTAssertEqual(restoredJobs, jobs)
    }

    private func temporaryDatabaseURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-studio-model-tools-\(UUID().uuidString).sqlite3")
    }

    private func removeDatabase(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
    }
}
