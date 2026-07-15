import Foundation
import MLXStudioDomain
import XCTest
@testable import MLXStudioOptimization

final class JANGPublishingCoordinatorTests: XCTestCase {
    func testRepositoryValidationAndSanitizationMatchHuggingFaceRules() {
        XCTAssertNil(HuggingFaceRepositoryIDValidator.validationError("org/model-JANG_4K"))
        XCTAssertNotNil(HuggingFaceRepositoryIDValidator.validationError("model-only"))
        XCTAssertNotNil(HuggingFaceRepositoryIDValidator.validationError("org/model--bad"))
        XCTAssertNotNil(HuggingFaceRepositoryIDValidator.validationError("org/model."))
        XCTAssertEqual(
            HuggingFaceRepositoryIDValidator.sanitizedModelName("📁 café model (final)"),
            "cafe-model-final"
        )
        XCTAssertFalse(
            HuggingFaceRepositoryIDValidator.sanitizedModelName(
                String(repeating: "a", count: 95) + "--truncated"
            ).hasSuffix("-")
        )
    }

    func testModelCardPreviewAndConfirmedPublishUseStructuredWorkerJobs() async throws {
        let worker = PublishingWorkerStub()
        let coordinator = JANGPublishingCoordinator(worker: worker)
        let modelURL = URL(fileURLWithPath: "/tmp/model")

        let card = try await coordinator.generateModelCard(modelURL: modelURL)
        XCTAssertEqual(card.baseModel, "org/base")
        XCTAssertEqual(card.quantizationConfiguration?.profile, "JANG_4K")
        XCTAssertEqual(card.license, "other")
        XCTAssertTrue(card.licenseUnknown == true)

        let preview = try await coordinator.preview(
            modelURL: modelURL,
            repositoryID: "org/model",
            isPrivate: true
        )
        XCTAssertEqual(preview.fileCount, 4)
        XCTAssertEqual(preview.totalSizeBytes, 1024)

        let result = try await coordinator.publish(
            modelURL: modelURL,
            repositoryID: "org/model",
            isPrivate: true,
            confirmedPreview: preview
        )
        XCTAssertEqual(result.url.absoluteString, "https://huggingface.co/org/model")
        XCTAssertEqual(worker.requests.map(\.operation), [
            .generateModelCard, .publishHuggingFace, .publishHuggingFace,
        ])
        XCTAssertEqual(worker.requests[1].parameters["dry-run"], "true")
        XCTAssertEqual(worker.requests[2].parameters["dry-run"], "false")
    }

    func testPublishRequiresMatchingPreview() async throws {
        let coordinator = JANGPublishingCoordinator(worker: PublishingWorkerStub())
        let modelURL = URL(fileURLWithPath: "/tmp/model")

        do {
            _ = try await coordinator.publish(
                modelURL: modelURL,
                repositoryID: "org/model",
                isPrivate: false,
                confirmedPreview: nil
            )
            XCTFail("Expected preview gate")
        } catch {
            XCTAssertEqual(error as? JANGPublishingError, .previewRequired)
        }
    }

    func testPlainMLXModelCardDoesNotFabricateJANGClaims() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("plain-mlx-card-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(#"{"_name_or_path":"LiquidAI/LFM2.5-350M","license":"apache-2.0"}"#.utf8)
            .write(to: root.appendingPathComponent("config.json"))
        let artifact = ModelArtifact(
            projectID: ModelProjectID(),
            name: "LFM2.5-350M",
            localURL: root,
            format: .mlx,
            precision: .init(rawValue: "bf16"),
            state: .ready,
            verificationStatus: .passed
        )

        let card = try ArtifactModelCardBuilder.build(modelURL: root, artifact: artifact)

        XCTAssertEqual(card.license, "apache-2.0")
        XCTAssertEqual(card.baseModel, "LiquidAI/LFM2.5-350M")
        XCTAssertNil(card.quantizationConfiguration)
        XCTAssertFalse(card.cardMarkdown.contains("JANG_4K"))
        XCTAssertFalse(card.cardMarkdown.contains("actual_bits"))
        XCTAssertTrue(card.cardMarkdown.contains("Format: `mlx`"))
    }
}

private final class PublishingWorkerStub: OptimizationWorker, @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [OptimizationWorkerRequest] = []

    var requests: [OptimizationWorkerRequest] {
        lock.withLock { storedRequests }
    }

    func events(
        for request: OptimizationWorkerRequest
    ) -> AsyncThrowingStream<OptimizationWorkerEventEnvelope, Error> {
        lock.withLock { storedRequests.append(request) }
        let json: String
        switch request.operation {
        case .generateModelCard:
            json = ##"{"license":"other","license_unknown":true,"base_model":"org/base","quantization_config":{"family":"JANG","profile":"JANG_4K","actual_bits":4.1,"block_size":64,"size_gb":1.2},"card_markdown":"# Model"}"##
        case .publishHuggingFace where request.parameters["dry-run"] == "true":
            json = #"{"dry_run":true,"repo":"org/model","private":true,"files_count":4,"total_size_bytes":1024}"#
        default:
            json = #"{"dry_run":false,"repo":"org/model","url":"https://huggingface.co/org/model","commit_url":"https://huggingface.co/org/model/commit/abc"}"#
        }
        return AsyncThrowingStream { continuation in
            continuation.yield(.init(jobID: request.jobID, event: .structuredOutput(json: json)))
            continuation.yield(.init(jobID: request.jobID, event: .completed(outputURL: nil)))
            continuation.finish()
        }
    }

    func cancel(jobID: JobID) async {}

    func diagnostics() async -> OptimizationWorkerDiagnostics {
        .init(executable: "/tmp/python", supportedOperations: [
            .generateModelCard, .publishHuggingFace,
        ])
    }
}
