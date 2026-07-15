import Foundation

/// Aggregated calibration evidence for one expert. The sums cover only tokens
/// routed to this expert and intentionally exclude router/gate weights.
public struct ExpertActivationEvidence: Codable, Hashable, Sendable {
    public let coordinate: ExpertCoordinate
    public let routedTokenCount: Int
    public let activationNormSum: Double
    public let squaredActivationNormSum: Double

    public init(
        coordinate: ExpertCoordinate,
        routedTokenCount: Int,
        activationNormSum: Double,
        squaredActivationNormSum: Double
    ) {
        self.coordinate = coordinate
        self.routedTokenCount = routedTokenCount
        self.activationNormSum = activationNormSum
        self.squaredActivationNormSum = squaredActivationNormSum
    }
}

/// One strategy's score. Raw values remain strategy-specific; percentile is
/// only a within-layer display/ranking normalization and must not be averaged
/// with another strategy's raw score.
public struct StrategyExpertScore: Codable, Hashable, Sendable {
    public let coordinate: ExpertCoordinate
    public let strategyIdentifier: StrategyIdentifier
    public let rawScore: Double
    public let percentile: Double
    public let routedTokenCount: Int

    public init(
        coordinate: ExpertCoordinate,
        strategyIdentifier: StrategyIdentifier,
        rawScore: Double,
        percentile: Double,
        routedTokenCount: Int
    ) {
        self.coordinate = coordinate
        self.strategyIdentifier = strategyIdentifier
        self.rawScore = rawScore
        self.percentile = percentile
        self.routedTokenCount = routedTokenCount
    }
}

/// Aggregated REAP evidence: the selected router weight multiplied by the
/// expert output L2 norm, summed only across tokens routed to the expert.
public struct RouterWeightedExpertEvidence: Codable, Hashable, Sendable {
    public let coordinate: ExpertCoordinate
    public let routedTokenCount: Int
    public let gateWeightedActivationNormSum: Double

    public init(
        coordinate: ExpertCoordinate,
        routedTokenCount: Int,
        gateWeightedActivationNormSum: Double
    ) {
        self.coordinate = coordinate
        self.routedTokenCount = routedTokenCount
        self.gateWeightedActivationNormSum = gateWeightedActivationNormSum
    }
}

/// A MAESTRO stationary-distribution score computed from autoregressive,
/// cross-layer routing transitions. The adapter consumes this evidence; it
/// does not claim to reproduce the paper's PyTorch calibration runtime.
public struct MAESTROExpertEvidence: Codable, Hashable, Sendable {
    public let coordinate: ExpertCoordinate
    public let stationaryProbability: Double
    public let routingVisitCount: Int

    public init(
        coordinate: ExpertCoordinate,
        stationaryProbability: Double,
        routingVisitCount: Int
    ) {
        self.coordinate = coordinate
        self.stationaryProbability = stationaryProbability
        self.routingVisitCount = routingVisitCount
    }
}

public enum StrategyRecoveryUsage: String, Codable, CaseIterable, Hashable, Sendable {
    /// No recovery was run. This is also the adapter default, so recovery can
    /// never occur as an implicit side effect of strategy analysis.
    case notPerformed
    /// Recovery was run by a separately visible workflow and supplied as
    /// evaluation evidence; the pruning strategy did not launch it.
    case performedExternally
}

/// Evaluation retention associated with a strategy candidate. Values are
/// ratios to the baseline and may exceed 1 when a measured score improves.
public struct StrategyRetentionEvidence: Codable, Hashable, Sendable {
    public let recoveryUsage: StrategyRecoveryUsage
    public let oneShotRetention: Double?
    public let postRecoveryRetention: Double?

    public init(
        recoveryUsage: StrategyRecoveryUsage = .notPerformed,
        oneShotRetention: Double? = nil,
        postRecoveryRetention: Double? = nil
    ) {
        self.recoveryUsage = recoveryUsage
        self.oneShotRetention = oneShotRetention
        self.postRecoveryRetention = postRecoveryRetention
    }
}
