import CryptoKit
import Foundation
import MLXStudioDomain
import MLXStudioPersistence

public enum EvaluationPrimitiveError: Error, Equatable, Sendable {
    case emptySuite
    case emptyJSONL
    case inconsistentSuiteMetadata
    case duplicateCaseIdentifier(EvaluationCaseID)
    case duplicateOrdinal(Int)
    case unsupportedSchemaVersion(Int)
    case missingExpectation
    case missingExpectedValue
    case unsupportedExpectation(EvaluationExpectationKind)
    case invalidRegularExpression(String)
}

public struct EvaluationJSONLRecord: Codable, Hashable, Sendable {
    public let schemaVersion: Int
    public let suiteID: EvaluationSuiteID
    public let suiteName: String
    public let suiteRevision: String
    public let suiteTags: [String]
    public let suiteHash: String
    public let evaluationCase: EvaluationCase

    public init(
        schemaVersion: Int = 1,
        suiteID: EvaluationSuiteID,
        suiteName: String,
        suiteRevision: String,
        suiteTags: Set<String>,
        suiteHash: String,
        evaluationCase: EvaluationCase
    ) {
        self.schemaVersion = schemaVersion
        self.suiteID = suiteID
        self.suiteName = suiteName
        self.suiteRevision = suiteRevision
        self.suiteTags = suiteTags.sorted()
        self.suiteHash = suiteHash
        self.evaluationCase = evaluationCase
    }
}

public enum EvaluationJSONL {
    public static func encode(_ suite: EvaluationSuite) throws -> Data {
        guard !suite.cases.isEmpty else { throw EvaluationPrimitiveError.emptySuite }
        let encoder = canonicalEncoder()
        let records = suite.cases.sorted(by: caseOrder).map {
            EvaluationJSONLRecord(
                suiteID: suite.id,
                suiteName: suite.name,
                suiteRevision: suite.revision,
                suiteTags: suite.tags,
                suiteHash: suite.suiteHash,
                evaluationCase: $0
            )
        }
        var data = Data()
        for record in records {
            data.append(try encoder.encode(record))
            data.append(0x0A)
        }
        return data
    }

    public static func decode(_ data: Data) throws -> EvaluationSuite {
        let lines = data.split(separator: 0x0A).filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw EvaluationPrimitiveError.emptyJSONL }
        let decoder = canonicalDecoder()
        let records = try lines.map { try decoder.decode(EvaluationJSONLRecord.self, from: Data($0)) }
        guard let first = records.first else { throw EvaluationPrimitiveError.emptyJSONL }
        guard first.schemaVersion == 1 else {
            throw EvaluationPrimitiveError.unsupportedSchemaVersion(first.schemaVersion)
        }
        var caseIDs: Set<EvaluationCaseID> = []
        var ordinals: Set<Int> = []
        for record in records {
            guard record.schemaVersion == first.schemaVersion else {
                throw EvaluationPrimitiveError.unsupportedSchemaVersion(record.schemaVersion)
            }
            guard record.suiteID == first.suiteID,
                  record.suiteName == first.suiteName,
                  record.suiteRevision == first.suiteRevision,
                  record.suiteTags == first.suiteTags,
                  record.suiteHash == first.suiteHash
            else { throw EvaluationPrimitiveError.inconsistentSuiteMetadata }
            guard caseIDs.insert(record.evaluationCase.id).inserted else {
                throw EvaluationPrimitiveError.duplicateCaseIdentifier(record.evaluationCase.id)
            }
            guard ordinals.insert(record.evaluationCase.ordinal).inserted else {
                throw EvaluationPrimitiveError.duplicateOrdinal(record.evaluationCase.ordinal)
            }
        }
        return EvaluationSuite(
            id: first.suiteID,
            name: first.suiteName,
            revision: first.suiteRevision,
            tags: Set(first.suiteTags),
            cases: records.map(\.evaluationCase).sorted(by: caseOrder),
            suiteHash: first.suiteHash
        )
    }
}

public enum EvaluationManifestBuilder {
    public static func build(for request: EvaluationRunRequest) throws -> EvaluationRunManifest {
        let encoder = canonicalEncoder()
        let cases = try request.suite.cases.sorted(by: caseOrder).map { evaluationCase in
            EvaluationCaseManifest(
                caseID: evaluationCase.id,
                ordinal: evaluationCase.ordinal,
                messagesHash: sha256(try encoder.encode(evaluationCase.messages)),
                generationConfiguration: evaluationCase.generationConfiguration
            )
        }
        let payload = ManifestHashPayload(
            schemaVersion: 1,
            runID: request.id,
            suiteID: request.suite.id,
            suiteHash: request.suite.suiteHash,
            candidates: request.candidates,
            executionOrder: request.executionOrder,
            hardwareProfileID: request.hardwareProfileID,
            runtimeVersion: request.runtimeVersion,
            kernelVersion: request.kernelVersion,
            cases: cases,
            createdAt: request.createdAt
        )
        return EvaluationRunManifest(
            schemaVersion: payload.schemaVersion,
            runID: payload.runID,
            suiteID: payload.suiteID,
            suiteHash: payload.suiteHash,
            candidates: payload.candidates,
            executionOrder: payload.executionOrder,
            hardwareProfileID: payload.hardwareProfileID,
            runtimeVersion: payload.runtimeVersion,
            kernelVersion: payload.kernelVersion,
            cases: payload.cases,
            createdAt: payload.createdAt,
            manifestHash: sha256(try encoder.encode(payload))
        )
    }
}

public struct BuiltInEvaluationScorer: EvaluationScorer {
    public let identifier = "mlx-studio.builtin-expectation"

    public init() {}

    public func score(_ request: EvaluationScoringRequest) async throws -> EvaluationScore {
        guard let expectation = request.evaluationCase.expectation else {
            throw EvaluationPrimitiveError.missingExpectation
        }
        guard let expected = expectation.value else {
            throw EvaluationPrimitiveError.missingExpectedValue
        }
        let output = request.generationResult.text
        let passed: Bool
        switch expectation.kind {
        case .exact:
            passed = output == expected
        case .contains:
            passed = output.contains(expected)
        case .regularExpression:
            let expression: NSRegularExpression
            do {
                expression = try NSRegularExpression(pattern: expected)
            } catch {
                throw EvaluationPrimitiveError.invalidRegularExpression(expected)
            }
            let range = NSRange(output.startIndex..<output.endIndex, in: output)
            passed = expression.firstMatch(in: output, range: range) != nil
        case .unitTest, .custom:
            throw EvaluationPrimitiveError.unsupportedExpectation(expectation.kind)
        }
        return EvaluationScore(
            kind: EvaluationScoreKind(rawValue: expectation.kind.rawValue),
            value: passed ? 1 : 0,
            details: ["scorer": identifier]
        )
    }
}

private struct ManifestHashPayload: Codable {
    let schemaVersion: Int
    let runID: EvaluationRunID
    let suiteID: EvaluationSuiteID
    let suiteHash: String
    let candidates: [EvaluationCandidate]
    let executionOrder: [ModelArtifactID]
    let hardwareProfileID: HardwareProfileID?
    let runtimeVersion: String?
    let kernelVersion: String?
    let cases: [EvaluationCaseManifest]
    let createdAt: Date
}

private func canonicalEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .millisecondsSince1970
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

private func canonicalDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func caseOrder(_ lhs: EvaluationCase, _ rhs: EvaluationCase) -> Bool {
    lhs.ordinal == rhs.ordinal
        ? lhs.id.rawValue < rhs.id.rawValue
        : lhs.ordinal < rhs.ordinal
}
