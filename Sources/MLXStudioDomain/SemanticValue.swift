import Foundation

public protocol SemanticValueTag: Sendable {}

/// An extensible, strongly typed string value for plugin-defined identifiers.
public struct SemanticValue<Tag: SemanticValueTag>: RawRepresentable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

extension SemanticValue: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension SemanticValue: CustomStringConvertible {
    public var description: String { rawValue }
}

public enum ArtifactFormatTag: SemanticValueTag {}
public enum ArtifactPrecisionTag: SemanticValueTag {}
public enum ArtifactCapabilityTag: SemanticValueTag {}
public enum ArtifactOperationTag: SemanticValueTag {}
public enum GenerationFinishReasonTag: SemanticValueTag {}
public enum EvaluationScoreKindTag: SemanticValueTag {}
public enum StrategyIdentifierTag: SemanticValueTag {}

public typealias ArtifactFormat = SemanticValue<ArtifactFormatTag>
public typealias ArtifactPrecision = SemanticValue<ArtifactPrecisionTag>
public typealias ArtifactCapability = SemanticValue<ArtifactCapabilityTag>
public typealias ArtifactOperation = SemanticValue<ArtifactOperationTag>
public typealias GenerationFinishReason = SemanticValue<GenerationFinishReasonTag>
public typealias EvaluationScoreKind = SemanticValue<EvaluationScoreKindTag>
public typealias StrategyIdentifier = SemanticValue<StrategyIdentifierTag>

public extension SemanticValue where Tag == ArtifactFormatTag {
    static let mlx = Self(rawValue: "mlx")
    static let jang = Self(rawValue: "jang")
    static let jangTQ = Self(rawValue: "jangtq")
}

public extension SemanticValue where Tag == ArtifactCapabilityTag {
    static let textGeneration = Self(rawValue: "text-generation")
    static let vision = Self(rawValue: "vision")
    static let embeddings = Self(rawValue: "embeddings")
    static let imageGeneration = Self(rawValue: "image-generation")
    static let audio = Self(rawValue: "audio")
    static let video = Self(rawValue: "video")
}

public extension SemanticValue where Tag == GenerationFinishReasonTag {
    static let completed = Self(rawValue: "completed")
    static let cancelled = Self(rawValue: "cancelled")
    static let length = Self(rawValue: "length")
    static let failed = Self(rawValue: "failed")
}
