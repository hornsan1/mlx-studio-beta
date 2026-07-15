// SPDX-License-Identifier: Apache-2.0

import Foundation
import MLXStudioPersistence
import XCTest
@testable import vMLXEngine

final class DownloadManagerResumeTests: XCTestCase {
    private var workRoot: URL!
    private var previousSidecarDirectory: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        workRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmlx-download-resume-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
        previousSidecarDirectory = ProcessInfo.processInfo.environment["VMLX_SIDECAR_DIR"]
        setenv(
            "VMLX_SIDECAR_DIR",
            workRoot.appendingPathComponent("sidecar", isDirectory: true).path,
            1
        )

        DownloadManager.huggingFaceHubRootProvider = { [workRoot] in
            workRoot!.appendingPathComponent("hub", isDirectory: true)
        }
        DownloadManager.sessionConfigurationFactory = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [DownloadManagerResumeURLProtocol.self]
            return configuration
        }
        XCTAssertTrue(URLProtocol.registerClass(DownloadManagerResumeURLProtocol.self))
        DownloadManagerResumeURLProtocol.reset()
    }

    override func tearDownWithError() throws {
        DownloadManager.sessionConfigurationFactory = { .ephemeral }
        DownloadManager.huggingFaceHubRootProvider = {
            FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(".cache/huggingface/hub")
        }
        URLProtocol.unregisterClass(DownloadManagerResumeURLProtocol.self)
        if let previousSidecarDirectory {
            setenv("VMLX_SIDECAR_DIR", previousSidecarDirectory, 1)
        } else {
            unsetenv("VMLX_SIDECAR_DIR")
        }
        try? FileManager.default.removeItem(at: workRoot)
        try super.tearDownWithError()
    }

    func testPauseResumeUsesDurablePartAndRangeRequest() async throws {
        let manager = DownloadManager()
        let id = await manager.enqueue(repo: "qa/resume-fixture", displayName: "Resume Fixture")

        let paused = try await pauseAfterReceivingModelBytes(manager: manager, id: id)
        let destination = try XCTUnwrap(paused.localPath)
            .appendingPathComponent("model.safetensors")
        let partial = destination.appendingPathExtension("part")

        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertGreaterThan(fileSize(partial), 0)

        await manager.resume(id)
        let completed = try await waitForTerminalJob(manager: manager, id: id)

        XCTAssertEqual(completed.status.rawValue, DownloadManager.Status.completed.rawValue)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertEqual(try Data(contentsOf: destination), DownloadManagerResumeURLProtocol.weights)
        XCTAssertTrue(
            DownloadManagerResumeURLProtocol.ranges().contains { $0.hasPrefix("bytes=") },
            "resume must issue an HTTP Range request from the durable .part file"
        )
    }

    func testCancelDeletesDurablePart() async throws {
        let manager = DownloadManager()
        let id = await manager.enqueue(repo: "qa/cancel-fixture", displayName: "Cancel Fixture")

        let paused = try await pauseAfterReceivingModelBytes(manager: manager, id: id)
        let destination = try XCTUnwrap(paused.localPath)
            .appendingPathComponent("model.safetensors")
        let partial = destination.appendingPathExtension("part")
        XCTAssertTrue(FileManager.default.fileExists(atPath: partial.path))

        await manager.cancel(id)
        try await Task.sleep(nanoseconds: 100_000_000)

        let cancelledJob = await manager.job(id)
        let cancelled = try XCTUnwrap(cancelledJob)
        XCTAssertEqual(cancelled.status.rawValue, DownloadManager.Status.cancelled.rawValue)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testLegacySidecarImportsIntoSQLiteAndRestartsFromDurableJob() async throws {
        let databaseURL = workRoot.appendingPathComponent("models.sqlite3")
        let artifactRepository = try ModelArtifactRepository(databaseURL: databaseURL)
        let jobRepository = artifactRepository.makeJobRepository()
        let job = DownloadManager.Job(
            id: UUID(),
            repo: "qa/restart-fixture",
            displayName: "Restart Fixture",
            totalBytes: 1_000,
            receivedBytes: 400,
            bytesPerSecond: 20,
            etaSeconds: 30,
            status: .downloading,
            startedAt: Date(timeIntervalSince1970: 1234),
            localPath: workRoot.appendingPathComponent("hub/restart")
        )
        let sidecarURL = workRoot
            .appendingPathComponent("sidecar", isDirectory: true)
            .appendingPathComponent("downloads.json")
        try FileManager.default.createDirectory(
            at: sidecarURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(LegacyDownloadSidecar(version: 1, jobs: [job]))
            .write(to: sidecarURL, options: .atomic)

        let importedManager = DownloadManager(jobRepository: jobRepository)
        let importedValue = await importedManager.job(job.id)
        let imported = try XCTUnwrap(importedValue)
        XCTAssertEqual(imported.status, .paused)
        XCTAssertEqual(imported.receivedBytes, 400)
        XCTAssertEqual(try jobRepository.records(type: "model_download").count, 1)

        try FileManager.default.removeItem(at: sidecarURL)
        let restartedManager = DownloadManager(jobRepository: jobRepository)
        let restartedValue = await restartedManager.job(job.id)
        let restarted = try XCTUnwrap(restartedValue)
        XCTAssertEqual(restarted.status, .paused)
        XCTAssertEqual(restarted.repo, job.repo)
        XCTAssertEqual(restarted.localPath, job.localPath)
    }

    private func pauseAfterReceivingModelBytes(
        manager: DownloadManager,
        id: UUID
    ) async throws -> DownloadManager.Job {
        for _ in 0..<300 {
            if let job = await manager.job(id), job.receivedBytes > 256 * 1024 {
                await manager.pause(id)
                try await Task.sleep(nanoseconds: 50_000_000)
                let paused = await manager.job(id)
                return try XCTUnwrap(paused)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for streamed model bytes")
        throw CancellationError()
    }

    private func waitForTerminalJob(
        manager: DownloadManager,
        id: UUID
    ) async throws -> DownloadManager.Job {
        for _ in 0..<900 {
            if let job = await manager.job(id),
               job.status == .completed || job.status == .failed || job.status == .cancelled
            {
                return job
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTFail("Timed out waiting for download completion")
        throw CancellationError()
    }

    private func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

private struct LegacyDownloadSidecar: Codable {
    let version: Int
    let jobs: [DownloadManager.Job]
}

private final class DownloadManagerResumeURLProtocol: URLProtocol {
    static let weights = Data(repeating: 0x5A, count: 4 * 1024 * 1024)

    private static let stateLock = NSLock()
    private static var recordedRanges: [String] = []

    private let stopLock = NSLock()
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "huggingface.co"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        if url.path.hasPrefix("/api/models/") {
            let siblings: [[String: Any]] = [
                ["rfilename": "config.json", "size": config.count],
                ["rfilename": "tokenizer.json", "size": tokenizer.count],
                ["rfilename": "model.safetensors", "size": Self.weights.count],
            ]
            let data = try! JSONSerialization.data(withJSONObject: ["siblings": siblings])
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        guard let marker = url.path.range(of: "/resolve/main/") else {
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }
        let file = String(url.path[marker.upperBound...])
        let complete: Data
        switch file {
        case "config.json": complete = config
        case "tokenizer.json": complete = tokenizer
        case "model.safetensors": complete = Self.weights
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.fileDoesNotExist))
            return
        }

        let range = request.value(forHTTPHeaderField: "Range")
        let body: Data
        let status: Int
        if let range, range.hasPrefix("bytes="),
           let startText = range.dropFirst("bytes=".count).split(separator: "-").first,
           let start = Int(startText), start < complete.count
        {
            Self.stateLock.lock()
            Self.recordedRanges.append(range)
            Self.stateLock.unlock()
            body = complete.subdata(in: start..<complete.count)
            status = 206
        } else {
            body = complete
            status = 200
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(body.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        deliver(body, offset: 0)
    }

    override func stopLoading() {
        stopLock.lock()
        stopped = true
        stopLock.unlock()
    }

    static func ranges() -> [String] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return recordedRanges
    }

    static func reset() {
        stateLock.lock()
        recordedRanges = []
        stateLock.unlock()
    }

    private func isStopped() -> Bool {
        stopLock.lock()
        defer { stopLock.unlock() }
        return stopped
    }

    private func deliver(_ body: Data, offset: Int) {
        guard !isStopped() else { return }
        guard offset < body.count else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let next = min(body.count, offset + 64 * 1024)
        client?.urlProtocol(self, didLoad: body.subdata(in: offset..<next))
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { [weak self] in
            self?.deliver(body, offset: next)
        }
    }

    private let config = Data("{\"model_type\":\"llama\"}".utf8)
    private let tokenizer = Data("{\"version\":\"1.0\"}".utf8)
}
