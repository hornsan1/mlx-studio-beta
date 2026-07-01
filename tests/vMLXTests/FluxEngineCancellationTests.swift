import Foundation
import XCTest
import vMLXFlux
import vMLXFluxKit

final class FluxEngineCancellationTests: XCTestCase {
    func testGenerateStreamTerminationCancelsModelTask() async throws {
        let probe = CancellationProbe()
        let modelName = "test-cancel-\(UUID().uuidString.lowercased())"
        ModelRegistry.register(ModelEntry(
            name: modelName,
            displayName: "Cancellation Probe",
            kind: .imageGen,
            defaultSteps: 1,
            defaultGuidance: 0,
            loader: { _, _ in CancellationProbeGenerator(probe: probe) }
        ))

        let modelDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmlx-flux-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: modelDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: modelDir) }

        let engine = FluxEngine()
        try await engine.load(name: modelName, modelPath: modelDir)

        let request = ImageGenRequest(
            prompt: "cancel probe",
            width: 256,
            height: 256,
            steps: 1,
            guidance: 0,
            outputDir: modelDir
        )
        let stream = await engine.generate(request)
        let consumer = Task {
            do {
                for try await _ in stream {}
            } catch {}
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        consumer.cancel()

        let didCancel = await probe.waitUntilCancelled()
        XCTAssertTrue(
            didCancel,
            "Cancelling the FluxEngine stream consumer should cancel the model generation task."
        )
    }
}

private actor CancellationProbe {
    private var cancelled = false

    func markCancelled() {
        cancelled = true
    }

    func waitUntilCancelled() async -> Bool {
        for _ in 0..<40 {
            if cancelled { return true }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return cancelled
    }
}

private final class CancellationProbeGenerator: ImageGenerator, @unchecked Sendable {
    let probe: CancellationProbe

    init(probe: CancellationProbe) {
        self.probe = probe
    }

    func generate(_ request: ImageGenRequest) -> AsyncThrowingStream<ImageGenEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [probe] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
                await probe.markCancelled()
                continuation.yield(.cancelled)
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
