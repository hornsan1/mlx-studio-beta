import Foundation
import XCTest
import vMLXEngine
@testable import vMLXApp

@MainActor
final class StudioModelInstallCoordinatorTests: XCTestCase {
    func testChatInstallHappyPathLoadsModelAndRoutesToChat() async throws {
        let harness = InstallHarness()
        let coordinator = harness.makeCoordinator()
        let request = ModelInstallRequest(
            repo: "mlx-community/Qwen3-0.6B-8bit",
            displayName: "Qwen3",
            source: .huggingFace,
            openChatWhenReady: true,
            target: .chat
        )

        let collectTask = collectEvents(from: coordinator.install(request))
        try await harness.waitUntilEnqueued()
        harness.send(.started(harness.job(receivedBytes: 0, totalBytes: 100)))
        harness.send(.progress(harness.job(receivedBytes: 50, totalBytes: 100)))
        harness.send(.completed(harness.job(receivedBytes: 100, totalBytes: 100)))

        let events = try await collectTask.value

        XCTAssertEqual(events, [
            "queued",
            "downloading",
            "downloading",
            "verifying",
            "installed",
            "loading",
            "ready",
        ])
        XCTAssertEqual(harness.selectedModels.map(\.id), [harness.model.id])
        XCTAssertEqual(harness.loadedModels.map(\.id), [harness.model.id])
        XCTAssertEqual(harness.verifiedRepos, ["mlx-community/Qwen3-0.6B-8bit"])
        XCTAssertEqual(harness.routedToChatCount, 1)
        XCTAssertTrue(harness.recordedFailures.isEmpty)
        XCTAssertTrue(harness.cancelledIDs.isEmpty)
    }

    func testExistingCompatibleModelSkipsDownloadAndRoutesToChat() async throws {
        let harness = InstallHarness()
        harness.existingModel = harness.model
        let coordinator = harness.makeCoordinator()
        let request = ModelInstallRequest(
            repo: "mlx-community/Qwen3-0.6B-8bit",
            displayName: "Qwen3",
            source: .huggingFace,
            openChatWhenReady: true,
            target: .chat
        )

        let events = try await collectEvents(from: coordinator.install(request)).value

        XCTAssertEqual(events, [
            "installed",
            "loading",
            "ready",
        ])
        XCTAssertFalse(harness.enqueued)
        XCTAssertEqual(harness.selectedModels.map(\.id), [harness.model.id])
        XCTAssertEqual(harness.loadedModels.map(\.id), [harness.model.id])
        XCTAssertEqual(harness.verifiedRepos, ["mlx-community/Qwen3-0.6B-8bit"])
        XCTAssertEqual(harness.routedToChatCount, 1)
        XCTAssertTrue(harness.recordedFailures.isEmpty)
        XCTAssertTrue(harness.cancelledIDs.isEmpty)
    }

    func testDownloadFailureRecordsFailureWithoutCancellingTerminalJob() async throws {
        let harness = InstallHarness()
        let coordinator = harness.makeCoordinator()
        let request = ModelInstallRequest(
            repo: "private/gated-model",
            displayName: "Gated Model",
            source: .huggingFace,
            openChatWhenReady: true
        )

        let collectTask = collectEvents(from: coordinator.install(request))
        try await harness.waitUntilEnqueued()
        harness.send(.failed(harness.jobID, "HF repo private/gated-model is gated."))

        let events = try await collectTask.value

        XCTAssertEqual(events, ["queued", "failed"])
        XCTAssertEqual(harness.recordedFailures.count, 1)
        XCTAssertEqual(harness.recordedFailures.first?.request.repo, "private/gated-model")
        XCTAssertTrue(harness.selectedModels.isEmpty)
        XCTAssertTrue(harness.loadedModels.isEmpty)
        XCTAssertEqual(harness.routedToChatCount, 0)
        XCTAssertTrue(harness.cancelledIDs.isEmpty)
    }

    func testLoadFailureRecordsFailureAfterInstalledAndLoadingEvents() async throws {
        let harness = InstallHarness()
        harness.loadError = StudioServiceError.noSelectedModel
        let coordinator = harness.makeCoordinator()
        let request = ModelInstallRequest(
            repo: "mlx-community/Qwen3-0.6B-8bit",
            displayName: "Qwen3",
            source: .recommended,
            openChatWhenReady: true
        )

        let collectTask = collectEvents(from: coordinator.install(request))
        try await harness.waitUntilEnqueued()
        harness.send(.completed(harness.job(receivedBytes: 100, totalBytes: 100)))

        let events = try await collectTask.value

        XCTAssertEqual(events, ["queued", "verifying", "installed", "loading", "failed"])
        XCTAssertEqual(harness.selectedModels.map(\.id), [harness.model.id])
        XCTAssertEqual(harness.loadedModels.map(\.id), [harness.model.id])
        XCTAssertEqual(harness.routedToChatCount, 0)
        XCTAssertEqual(harness.recordedFailures.count, 1)
        XCTAssertTrue(harness.cancelledIDs.isEmpty)
    }

    func testConsumerCancellationCancelsUnderlyingDownload() async throws {
        let harness = InstallHarness()
        let coordinator = harness.makeCoordinator()
        let request = ModelInstallRequest(
            repo: "mlx-community/Qwen3-0.6B-8bit",
            displayName: "Qwen3",
            source: .huggingFace,
            openChatWhenReady: true
        )

        let collectTask = collectEvents(from: coordinator.install(request))
        try await harness.waitUntilEnqueued()

        collectTask.cancel()
        try await harness.waitUntilCancelled()

        XCTAssertEqual(harness.cancelledIDs, [harness.jobID])
        XCTAssertTrue(harness.recordedFailures.isEmpty)
    }

    private func collectEvents(
        from stream: AsyncThrowingStream<ModelInstallEvent, Error>
    ) -> Task<[String], Error> {
        Task {
            var events: [String] = []
            do {
                for try await event in stream {
                    events.append(event.label)
                }
            } catch {
                // The coordinator intentionally finishes failed install
                // streams with an error after yielding .failed so callers
                // can drive both inline UI and thrown-error diagnostics.
            }
            return events
        }
    }
}

@MainActor
private final class InstallHarness {
    let jobID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    let localURL = URL(fileURLWithPath: "/tmp/mlx-studio-tests/qwen3", isDirectory: true)
    lazy var model = ModelSummary(
        id: "local-qwen3",
        ref: ModelRef(
            id: "local-qwen3",
            displayName: "Qwen3",
            repo: "mlx-community/Qwen3-0.6B-8bit",
            localURL: localURL
        ),
        family: "qwen3",
        modality: "text",
        sizeBytes: 512,
        labels: ["MLX", "text"],
        isLoaded: false
    )

    private var continuation: AsyncStream<DownloadManager.Event>.Continuation?
    var existingModel: ModelSummary?
    private(set) var enqueued = false
    private(set) var cancelledIDs: [JobID] = []
    private(set) var selectedModels: [ModelSummary] = []
    private(set) var loadedModels: [ModelSummary] = []
    private(set) var verifiedRepos: [String] = []
    private(set) var routedToChatCount = 0
    private(set) var recordedFailures: [(request: ModelInstallRequest, message: String)] = []
    var loadError: Error?

    func makeCoordinator() -> StudioModelInstallCoordinator {
        StudioModelInstallCoordinator(dependencies: .init(
            subscribeDownloads: {
                AsyncStream { continuation in
                    self.continuation = continuation
                }
            },
            resolveExistingModel: { repo in
                XCTAssertFalse(repo.isEmpty)
                return self.existingModel
            },
            enqueueDownload: { repo, displayName in
                XCTAssertFalse(repo.isEmpty)
                XCTAssertFalse(displayName.isEmpty)
                self.enqueued = true
                return self.jobID
            },
            cancelDownload: { id in
                self.cancelledIDs.append(id)
            },
            resolveInstalledModel: { repo, localPath in
                XCTAssertFalse(repo.isEmpty)
                XCTAssertEqual(localPath, self.localURL)
                return self.model
            },
            verifyInstallTarget: { target, repo, downloadPath, localPath, _ in
                if case .chat = target {
                    // expected
                } else {
                    XCTFail("Expected chat install target")
                }
                if self.enqueued {
                    XCTAssertEqual(downloadPath, self.localURL)
                } else {
                    XCTAssertNil(downloadPath)
                }
                XCTAssertEqual(localPath, self.localURL)
                self.verifiedRepos.append(repo)
            },
            selectModel: { model in
                self.selectedModels.append(model)
            },
            loadChatModel: { model in
                self.loadedModels.append(model)
                if let loadError = self.loadError {
                    throw loadError
                }
            },
            routeToChat: {
                self.routedToChatCount += 1
            },
            recordFailure: { request, message, _ in
                self.recordedFailures.append((request, message))
            }
        ))
    }

    func job(receivedBytes: Int64, totalBytes: Int64) -> DownloadManager.Job {
        DownloadManager.Job(
            id: jobID,
            repo: "mlx-community/Qwen3-0.6B-8bit",
            displayName: "Qwen3",
            totalBytes: totalBytes,
            receivedBytes: receivedBytes,
            status: receivedBytes >= totalBytes ? .completed : .downloading,
            localPath: localURL
        )
    }

    func send(_ event: DownloadManager.Event) {
        continuation?.yield(event)
    }

    func waitUntilEnqueued() async throws {
        try await waitUntil("download enqueue") { enqueued }
    }

    func waitUntilCancelled() async throws {
        try await waitUntil("download cancel") { !cancelledIDs.isEmpty }
    }

    private func waitUntil(_ label: String, condition: () -> Bool) async throws {
        for _ in 0..<100 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for \(label)")
    }
}

private extension ModelInstallEvent {
    var label: String {
        switch self {
        case .queued:
            return "queued"
        case .downloading:
            return "downloading"
        case .verifying:
            return "verifying"
        case .installed:
            return "installed"
        case .loading:
            return "loading"
        case .ready:
            return "ready"
        case .failed:
            return "failed"
        }
    }
}
