import Foundation

/// Marker protocol for strongly typed MLX Studio identifiers.
public protocol MLXStudioIDTag: Sendable {}

/// A UUID-backed identifier that encodes as a lowercase UUID string.
public struct MLXStudioID<Tag: MLXStudioIDTag>: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init() {
        self.rawValue = UUID().uuidString.lowercased()
    }

    public init(_ uuid: UUID) {
        self.rawValue = uuid.uuidString.lowercased()
    }

    public init?(rawValue: String) {
        guard let uuid = UUID(uuidString: rawValue) else { return nil }
        self.init(uuid)
    }
}

extension MLXStudioID: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let identifier = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected a UUID string"
            )
        }
        self = identifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension MLXStudioID: CustomStringConvertible {
    public var description: String { rawValue }
}

public enum ModelProjectIDTag: MLXStudioIDTag {}
public enum ModelSourceIDTag: MLXStudioIDTag {}
public enum ModelArtifactIDTag: MLXStudioIDTag {}
public enum ArtifactManifestIDTag: MLXStudioIDTag {}
public enum HardwareProfileIDTag: MLXStudioIDTag {}
public enum JobIDTag: MLXStudioIDTag {}
public enum GenerationIDTag: MLXStudioIDTag {}
public enum EvaluationSuiteIDTag: MLXStudioIDTag {}
public enum EvaluationCaseIDTag: MLXStudioIDTag {}
public enum EvaluationRunIDTag: MLXStudioIDTag {}
public enum HumanJudgmentIDTag: MLXStudioIDTag {}
public enum OptimizationPlanIDTag: MLXStudioIDTag {}
public enum QuantizationRecipeIDTag: MLXStudioIDTag {}
public enum StrategyAnalysisIDTag: MLXStudioIDTag {}

public typealias ModelProjectID = MLXStudioID<ModelProjectIDTag>
public typealias ModelSourceID = MLXStudioID<ModelSourceIDTag>
public typealias ModelArtifactID = MLXStudioID<ModelArtifactIDTag>
public typealias ArtifactManifestID = MLXStudioID<ArtifactManifestIDTag>
public typealias HardwareProfileID = MLXStudioID<HardwareProfileIDTag>
public typealias JobID = MLXStudioID<JobIDTag>
public typealias GenerationID = MLXStudioID<GenerationIDTag>
public typealias EvaluationSuiteID = MLXStudioID<EvaluationSuiteIDTag>
public typealias EvaluationCaseID = MLXStudioID<EvaluationCaseIDTag>
public typealias EvaluationRunID = MLXStudioID<EvaluationRunIDTag>
public typealias HumanJudgmentID = MLXStudioID<HumanJudgmentIDTag>
public typealias OptimizationPlanID = MLXStudioID<OptimizationPlanIDTag>
public typealias QuantizationRecipeID = MLXStudioID<QuantizationRecipeIDTag>
public typealias StrategyAnalysisID = MLXStudioID<StrategyAnalysisIDTag>
