// Adapted from hornsan1/jangq-private@5d5487c27fa81d9f51da27264ae855964e334070
// JANGStudio PublishService.swift and ModelCardService.swift. Process ownership
// stays in PythonJANGWorker so publishing shares durable jobs, cancellation,
// bounded logs, and secret/path redaction with every optimization operation.
import Foundation
import MLXStudioDomain

public enum JANGPublishingError: Error, Equatable, LocalizedError, Sendable {
    case invalidRepositoryID(String)
    case missingStructuredOutput
    case malformedStructuredOutput
    case previewRequired
    case previewMismatch

    public var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let message): return message
        case .missingStructuredOutput: return "The JANG worker completed without structured publishing output."
        case .malformedStructuredOutput: return "The JANG worker returned malformed publishing output."
        case .previewRequired: return "Run a publishing preview before uploading."
        case .previewMismatch: return "The repository or privacy setting changed after preview; run Preview again."
        }
    }
}

public enum HuggingFaceRepositoryIDValidator {
    public static func validationError(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Repository ID is empty." }
        guard !trimmed.contains(where: \Character.isWhitespace) else {
            return "Repository ID cannot contain spaces."
        }
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else {
            return "Repository ID must use the format org/model-name."
        }
        let expression = try? NSRegularExpression(
            pattern: "^[A-Za-z0-9][A-Za-z0-9_.-]{0,95}$"
        )
        for (label, part) in zip(["organization", "model"], parts) {
            let segment = String(part)
            let range = NSRange(segment.startIndex..<segment.endIndex, in: segment)
            guard expression?.firstMatch(in: segment, range: range) != nil else {
                return "Invalid \(label) segment '\(segment)'. Use letters, digits, dot, underscore, or hyphen."
            }
            guard !segment.hasSuffix("."), !segment.hasSuffix("-"),
                  !segment.contains(".."), !segment.contains("--") else {
                return "Invalid \(label) segment '\(segment)': no trailing or repeated dot/hyphen."
            }
        }
        return nil
    }

    public static func sanitizedModelName(_ value: String) -> String {
        let decomposed = value.decomposedStringWithCanonicalMapping
        let ascii = String(decomposed.unicodeScalars.filter(\.isASCII).map(Character.init))
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        var result = String(ascii.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        while result.contains("..") { result = result.replacingOccurrences(of: "..", with: ".") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        if result.isEmpty { result = "model" }
        if let first = result.first, !first.isLetter && !first.isNumber { result = "model-" + result }
        result = String(result.prefix(96))
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return result.isEmpty ? "model" : result
    }
}

public struct JANGModelCardResult: Codable, Hashable, Sendable {
    public struct QuantizationConfiguration: Codable, Hashable, Sendable {
        public let family: String
        public let profile: String
        public let actualBits: Double
        public let blockSize: Int?
        public let sizeGB: Double?

        enum CodingKeys: String, CodingKey {
            case family, profile
            case actualBits = "actual_bits"
            case blockSize = "block_size"
            case sizeGB = "size_gb"
        }
    }

    public let license: String
    public let licenseUnknown: Bool?
    public let baseModel: String
    public let quantizationConfiguration: QuantizationConfiguration
    public let cardMarkdown: String

    enum CodingKeys: String, CodingKey {
        case license
        case licenseUnknown = "license_unknown"
        case baseModel = "base_model"
        case quantizationConfiguration = "quantization_config"
        case cardMarkdown = "card_markdown"
    }
}

public struct JANGPublishPreview: Codable, Hashable, Sendable {
    public let dryRun: Bool
    public let repositoryID: String
    public let isPrivate: Bool
    public let fileCount: Int
    public let totalSizeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case dryRun = "dry_run"
        case repositoryID = "repo"
        case isPrivate = "private"
        case fileCount = "files_count"
        case totalSizeBytes = "total_size_bytes"
    }
}

public struct JANGPublishResult: Codable, Hashable, Sendable {
    public let dryRun: Bool
    public let repositoryID: String
    public let url: URL
    public let commitURL: URL?

    enum CodingKeys: String, CodingKey {
        case dryRun = "dry_run"
        case repositoryID = "repo"
        case url
        case commitURL = "commit_url"
    }
}

public protocol JANGPublishingEventSink: Sendable {
    func receive(_ envelope: OptimizationWorkerEventEnvelope) async
}

public actor JANGPublishingCoordinator {
    private let worker: any OptimizationWorker

    public init(worker: any OptimizationWorker) {
        self.worker = worker
    }

    public func generateModelCard(
        modelURL: URL,
        projectID: ModelProjectID? = nil,
        artifactID: ModelArtifactID? = nil,
        jobID: JobID = .init(),
        eventSink: (any JANGPublishingEventSink)? = nil
    ) async throws -> JANGModelCardResult {
        let json = try await structuredOutput(for: OptimizationWorkerRequest(
            jobID: jobID,
            projectID: projectID,
            artifactID: artifactID,
            operation: .generateModelCard,
            sourceURL: modelURL,
            partialOutputPolicy: .keep
        ), eventSink: eventSink)
        return try decode(JANGModelCardResult.self, json: json)
    }

    public func preview(
        modelURL: URL,
        repositoryID: String,
        isPrivate: Bool,
        projectID: ModelProjectID? = nil,
        artifactID: ModelArtifactID? = nil,
        jobID: JobID = .init(),
        eventSink: (any JANGPublishingEventSink)? = nil
    ) async throws -> JANGPublishPreview {
        try validate(repositoryID)
        let json = try await structuredOutput(for: publishRequest(
            modelURL: modelURL,
            repositoryID: repositoryID,
            isPrivate: isPrivate,
            dryRun: true,
            projectID: projectID,
            artifactID: artifactID,
            jobID: jobID
        ), eventSink: eventSink)
        return try decode(JANGPublishPreview.self, json: json)
    }

    public func publish(
        modelURL: URL,
        repositoryID: String,
        isPrivate: Bool,
        confirmedPreview: JANGPublishPreview?,
        projectID: ModelProjectID? = nil,
        artifactID: ModelArtifactID? = nil,
        jobID: JobID = .init(),
        eventSink: (any JANGPublishingEventSink)? = nil
    ) async throws -> JANGPublishResult {
        try validate(repositoryID)
        guard let confirmedPreview else { throw JANGPublishingError.previewRequired }
        guard confirmedPreview.dryRun,
              confirmedPreview.repositoryID == repositoryID,
              confirmedPreview.isPrivate == isPrivate else {
            throw JANGPublishingError.previewMismatch
        }
        let json = try await structuredOutput(for: publishRequest(
            modelURL: modelURL,
            repositoryID: repositoryID,
            isPrivate: isPrivate,
            dryRun: false,
            projectID: projectID,
            artifactID: artifactID,
            jobID: jobID
        ), eventSink: eventSink)
        return try decode(JANGPublishResult.self, json: json)
    }

    public func cancel(jobID: JobID) async {
        await worker.cancel(jobID: jobID)
    }

    public nonisolated static func writeModelCard(_ card: JANGModelCardResult, to modelURL: URL) throws {
        try Data(card.cardMarkdown.utf8).write(
            to: modelURL.appendingPathComponent("README.md"),
            options: .atomic
        )
    }

    private func publishRequest(
        modelURL: URL,
        repositoryID: String,
        isPrivate: Bool,
        dryRun: Bool,
        projectID: ModelProjectID?,
        artifactID: ModelArtifactID?,
        jobID: JobID
    ) -> OptimizationWorkerRequest {
        OptimizationWorkerRequest(
            jobID: jobID,
            projectID: projectID,
            artifactID: artifactID,
            operation: .publishHuggingFace,
            sourceURL: modelURL,
            parameters: [
                "repo": repositoryID,
                "private": isPrivate ? "true" : "false",
                "dry-run": dryRun ? "true" : "false",
            ],
            partialOutputPolicy: .keep
        )
    }

    private func structuredOutput(
        for request: OptimizationWorkerRequest,
        eventSink: (any JANGPublishingEventSink)?
    ) async throws -> String {
        var output: String?
        for try await envelope in worker.events(for: request) {
            await eventSink?.receive(envelope)
            if case .structuredOutput(let json) = envelope.event { output = json }
        }
        guard let output else { throw JANGPublishingError.missingStructuredOutput }
        return output
    }

    private func validate(_ repositoryID: String) throws {
        if let message = HuggingFaceRepositoryIDValidator.validationError(repositoryID) {
            throw JANGPublishingError.invalidRepositoryID(message)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
        guard let data = json.data(using: .utf8),
              let value = try? JSONDecoder().decode(type, from: data) else {
            throw JANGPublishingError.malformedStructuredOutput
        }
        return value
    }
}
