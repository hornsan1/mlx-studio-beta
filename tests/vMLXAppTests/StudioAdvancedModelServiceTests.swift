import Foundation
import XCTest
@testable import vMLXApp

@MainActor
final class StudioAdvancedModelServiceTests: XCTestCase {
    func testBenchmarkGateRequiresLoadedTextModel() {
        XCTAssertEqual(
            StudioAdvancedModelBenchmarkGate.unavailableReason(
                displayName: "AITRADER/FLUX1-schnell-mlx-4bit",
                modality: "image",
                isLoaded: false
            ),
            "Benchmark requires a loaded text model"
        )
        XCTAssertEqual(
            StudioAdvancedModelBenchmarkGate.unavailableReason(
                displayName: "Qwen3-0.6B-8bit",
                modality: "text",
                isLoaded: false
            ),
            "Load model before benchmark"
        )
        XCTAssertNil(
            StudioAdvancedModelBenchmarkGate.unavailableReason(
                displayName: "Qwen3-0.6B-8bit",
                modality: "text",
                isLoaded: true
            )
        )
    }

    func testValidationGateRequiresSelectedModelAndTokenizer() {
        XCTAssertEqual(
            StudioAdvancedModelValidationGate.unavailableReason(
                hasSelectedModel: false,
                hasTokenizer: false
            ),
            "Select a local model"
        )
        XCTAssertEqual(
            StudioAdvancedModelValidationGate.unavailableReason(
                hasSelectedModel: true,
                hasTokenizer: false
            ),
            "Tokenizer required before validation"
        )
        XCTAssertNil(
            StudioAdvancedModelValidationGate.unavailableReason(
                hasSelectedModel: true,
                hasTokenizer: true
            )
        )
    }

    func testReportGateRequiresSelectionAndInspection() {
        XCTAssertEqual(
            StudioAdvancedModelReportGate.unavailableReason(
                hasSelectedModel: false,
                hasInspection: false
            ),
            "Select a local model"
        )
        XCTAssertEqual(
            StudioAdvancedModelReportGate.unavailableReason(
                hasSelectedModel: true,
                hasInspection: false
            ),
            "Run Inspect before report export"
        )
        XCTAssertNil(
            StudioAdvancedModelReportGate.unavailableReason(
                hasSelectedModel: true,
                hasInspection: true
            )
        )
    }

    func testInspectFollowsHuggingFaceSnapshotSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-studio-inspect-\(UUID().uuidString)", isDirectory: true)
        let blobs = root.appendingPathComponent("blobs", isDirectory: true)
        let snapshot = root
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent("abc123", isDirectory: true)
        let transformer = snapshot.appendingPathComponent("transformer", isDirectory: true)
        let tokenizer = snapshot.appendingPathComponent("tokenizer", isDirectory: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transformer, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tokenizer, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let weightBlob = blobs.appendingPathComponent("weight-blob")
        let tokenizerBlob = blobs.appendingPathComponent("tokenizer-config-blob")
        try Data(repeating: 7, count: 4096).write(to: weightBlob)
        try Data(#"{"tokenizer_class":"SmokeTokenizer"}"#.utf8).write(to: tokenizerBlob)
        try Data(#"{"model_type":"flux"}"#.utf8)
            .write(to: snapshot.appendingPathComponent("model_index.json"))
        try FileManager.default.createSymbolicLink(
            at: transformer.appendingPathComponent("0.safetensors"),
            withDestinationURL: weightBlob
        )
        try FileManager.default.createSymbolicLink(
            at: tokenizer.appendingPathComponent("tokenizer_config.json"),
            withDestinationURL: tokenizerBlob
        )

        let service = StudioAdvancedModelService(app: AppState(), jobs: StudioJobService())
        let inspection = try await service.inspect(ModelRef(
            id: "flux-smoke",
            displayName: "Smoke FLUX Model",
            repo: nil,
            localURL: snapshot
        ))

        XCTAssertEqual(inspection.family, "flux")
        XCTAssertEqual(inspection.modality, "image")
        XCTAssertTrue(inspection.sizeBytes >= 4096)
        XCTAssertEqual(inspection.safetensorShardCount, 1)
        XCTAssertTrue(inspection.tokenizerPresent)
    }

    func testValidateFailsWhenInspectionFindsNoTokenizer() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-studio-validate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(#"{"model_type":"qwen3"}"#.utf8)
            .write(to: root.appendingPathComponent("config.json"))
        try Data(repeating: 3, count: 4096)
            .write(to: root.appendingPathComponent("model.safetensors"))

        StudioDiagnosticIssueStore.clear()
        defer { StudioDiagnosticIssueStore.clear() }

        let jobs = StudioJobService()
        let service = StudioAdvancedModelService(app: AppState(), jobs: jobs)
        let jobID = try await service.validate(
            ModelRef(
                id: "missing-tokenizer",
                displayName: "Missing Tokenizer Model",
                repo: nil,
                localURL: root
            ),
            suite: .loadAndShortChat
        )

        let job = try await waitForJob(jobID, in: jobs, status: .failed)
        let issues = StudioDiagnosticIssueStore.load(limit: 1)

        XCTAssertEqual(job.message, "Validation failed: tokenizer required before validation.")
        XCTAssertEqual(issues.first?.source, .advancedModels)
        XCTAssertEqual(issues.first?.title, "Advanced model validation failed")
        XCTAssertEqual(issues.first?.message, "Validation failed: tokenizer required before validation.")
    }

    func testPackageReturnsAfterReportJobCompletes() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-studio-package-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(#"{"model_type":"qwen3"}"#.utf8)
            .write(to: root.appendingPathComponent("config.json"))
        try Data(#"{"tokenizer_class":"SmokeTokenizer"}"#.utf8)
            .write(to: root.appendingPathComponent("tokenizer_config.json"))
        try Data(repeating: 9, count: 4096)
            .write(to: root.appendingPathComponent("model.safetensors"))

        let jobs = StudioJobService()
        let service = StudioAdvancedModelService(app: AppState(), jobs: jobs)
        let jobID = try await service.package(
            ModelRef(
                id: "report-ready",
                displayName: "Report Ready Model",
                repo: nil,
                localURL: root
            ),
            options: PackageOptions()
        )
        let allJobs = try await jobs.listJobs()
        let job = try XCTUnwrap(allJobs.first { $0.id == jobID })
        defer {
            if let outputPath = job.outputPath {
                try? FileManager.default.removeItem(at: outputPath)
            }
        }

        XCTAssertEqual(job.status, .completed)
        XCTAssertEqual(job.message, "Report exported")
        XCTAssertNotNil(job.outputPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: job.outputPath?.path ?? ""))
    }

    private func waitForJob(
        _ id: JobID,
        in jobs: StudioJobService,
        status: JobStatus
    ) async throws -> ModelJob {
        for _ in 0..<40 {
            if let job = try await jobs.listJobs().first(where: { $0.id == id }),
               job.status == status {
                return job
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for job \(id) to reach \(status.rawValue)")
        throw CancellationError()
    }
}
