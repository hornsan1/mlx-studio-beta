import Foundation
import vMLXEngine

@MainActor
struct StudioModelInstallCoordinator {
    struct Dependencies {
        var subscribeDownloads: () async -> AsyncStream<DownloadManager.Event>
        var resolveExistingModel: (_ repo: String) async throws -> ModelSummary?
        var enqueueDownload: (_ repo: String, _ displayName: String) async -> JobID
        var cancelDownload: (_ id: JobID) async -> Void
        var resolveInstalledModel: (_ repo: String, _ localPath: URL?) async throws -> ModelSummary
        var verifyInstallTarget: (
            _ target: ModelInstallTarget,
            _ repo: String,
            _ downloadPath: URL?,
            _ localPath: URL?,
            _ manifestFiles: [HuggingFaceDownloadSafety.RemoteFile]
        ) throws -> Void
        var selectModel: (_ model: ModelSummary) -> Void
        var loadChatModel: (_ model: ModelSummary) async throws -> Void
        var routeToChat: () -> Void
        var recordFailure: (_ request: ModelInstallRequest, _ message: String, _ error: Error) -> Void
    }

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func install(_ request: ModelInstallRequest) -> AsyncThrowingStream<ModelInstallEvent, Error> {
        AsyncThrowingStream { continuation in
            let cancellation = ModelInstallCancellationBox()
            let dependencies = self.dependencies
            let task = Task { @MainActor in
                do {
                    if let existing = try? await dependencies.resolveExistingModel(request.repo),
                       canUseExistingModel(
                        existing,
                        request: request,
                        dependencies: dependencies
                       ) {
                        try await finishInstall(
                            with: existing,
                            request: request,
                            dependencies: dependencies,
                            continuation: continuation
                        )
                        continuation.finish()
                        return
                    }

                    let downloadEvents = await dependencies.subscribeDownloads()
                    let jobID = await dependencies.enqueueDownload(request.repo, request.displayName)
                    cancellation.set(jobID)
                    continuation.yield(.queued(jobID))

                    for await event in downloadEvents {
                        try Task.checkCancellation()
                        switch event {
                        case .started(let job) where job.id == jobID,
                             .progress(let job) where job.id == jobID:
                            continuation.yield(.downloading(ModelInstallProgress(job: job)))

                        case .completed(let job) where job.id == jobID:
                            try await handleCompletedJob(
                                job,
                                request: request,
                                dependencies: dependencies,
                                continuation: continuation
                            )
                            cancellation.clear()
                            continuation.finish()
                            return

                        case .failed(let id, let message) where id == jobID:
                            throw StudioServiceError.downloadFailed(message)

                        case .cancelled(let id) where id == jobID:
                            throw StudioServiceError.downloadFailed("Download cancelled.")

                        default:
                            break
                        }
                    }
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    cancellation.clear()
                    let message = error.localizedDescription
                    dependencies.recordFailure(request, message, error)
                    continuation.yield(.failed(message))
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
                if let jobID = cancellation.jobID() {
                    Task {
                        await dependencies.cancelDownload(jobID)
                    }
                }
            }
        }
    }

    private func handleCompletedJob(
        _ job: DownloadManager.Job,
        request: ModelInstallRequest,
        dependencies: Dependencies,
        continuation: AsyncThrowingStream<ModelInstallEvent, Error>.Continuation
    ) async throws {
        continuation.yield(.verifying(ModelInstallProgress(job: job)))
        let model = try await dependencies.resolveInstalledModel(request.repo, job.localPath)
        try dependencies.verifyInstallTarget(
            request.target,
            request.repo,
            job.localPath,
            model.ref.localURL,
            job.manifestFiles
        )
        try await finishInstall(
            with: model,
            request: request,
            dependencies: dependencies,
            continuation: continuation
        )
    }

    private func canUseExistingModel(
        _ model: ModelSummary,
        request: ModelInstallRequest,
        dependencies: Dependencies
    ) -> Bool {
        do {
            try dependencies.verifyInstallTarget(
                request.target,
                request.repo,
                nil,
                model.ref.localURL,
                []
            )
            return true
        } catch {
            return false
        }
    }

    private func finishInstall(
        with model: ModelSummary,
        request: ModelInstallRequest,
        dependencies: Dependencies,
        continuation: AsyncThrowingStream<ModelInstallEvent, Error>.Continuation
    ) async throws {
        dependencies.selectModel(model)
        continuation.yield(.installed(model))
        switch request.target {
        case .chat where request.openChatWhenReady:
            continuation.yield(.loading(model))
            try await dependencies.loadChatModel(model)
            dependencies.routeToChat()
            continuation.yield(.ready(model))
        case .image:
            continuation.yield(.ready(model))
        case .chat:
            break
        }
    }
}

private final class ModelInstallCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedJobID: JobID?

    func set(_ jobID: JobID) {
        lock.lock()
        storedJobID = jobID
        lock.unlock()
    }

    func jobID() -> JobID? {
        lock.lock()
        defer { lock.unlock() }
        return storedJobID
    }

    func clear() {
        lock.lock()
        storedJobID = nil
        lock.unlock()
    }
}
