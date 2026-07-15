import Foundation
import MLXStudioDomain

/// Paper authority: Goel, Maheshwari, and Chakraborty,
/// "It Takes a MAESTRO To Prune Bad Experts," arXiv:2607.08601v1.
/// The paper does not link a public reference implementation, so this adapter
/// accepts stationary-distribution evidence produced outside the Swift process.
public struct MAESTROAdapterCapability: Codable, Hashable, Sendable {
  public enum SurvivorPolicy: String, Codable, Hashable, Sendable {
    case uniformPerLayer
  }

  public static let displayLabel = "Global routing — Experimental"
  public static let paperURL = "https://arxiv.org/abs/2607.08601v1"
  public static let isEligibleForAutomaticSelection = false

  public let architecture: String
  public let evaluatedModel: String
  public let survivorPolicy: SurvivorPolicy
  public let limitations: [String]

  private init(architecture: String, evaluatedModel: String) {
    self.architecture = architecture
    self.evaluatedModel = evaluatedModel
    self.survivorPolicy = .uniformPerLayer
    self.limitations = [
      "Experimental support is limited to the exact model family evaluated in arXiv:2607.08601v1.",
      "Stationary routing evidence must be produced by an external autoregressive calibration workflow.",
      "The first-order Markov approximation may miss dependencies on longer routing histories.",
      "Selection removes whole experts and does not combine expert pruning with width or depth reduction.",
    ]
  }

  public static let gptOSS = MAESTROAdapterCapability(
    architecture: "gpt_oss",
    evaluatedModel: "openai/gpt-oss-20b"
  )

  public static let qwen3MoE = MAESTROAdapterCapability(
    architecture: "qwen3_moe",
    evaluatedModel: "Qwen/Qwen3-30B-A3B"
  )

  public static let supported: [MAESTROAdapterCapability] = [.gptOSS, .qwen3MoE]

  public static func capability(for architecture: String) -> MAESTROAdapterCapability? {
    supported.first {
      $0.architecture.caseInsensitiveCompare(architecture) == .orderedSame
    }
  }

  public var displayLabel: String { Self.displayLabel }
  public var isEligibleForAutomaticSelection: Bool { Self.isEligibleForAutomaticSelection }
}

public enum MAESTROStrategyError: Error, LocalizedError, Equatable, Sendable {
  case missingTopology
  case unsupportedArchitecture(String)
  case missingEvidence
  case invalidTopology(String)
  case duplicateEvidence(ExpertCoordinate)
  case missingExpertEvidence(ExpertCoordinate)
  case unexpectedExpertEvidence(ExpertCoordinate)
  case invalidEvidence(ExpertCoordinate, String)
  case invalidStationaryDistribution(Double)
  case invalidRetentionEvidence(String)
  case candidateInvalid([String])

  public var errorDescription: String? {
    switch self {
    case .missingTopology:
      return "MAESTRO analysis requires model expert topology."
    case .unsupportedArchitecture(let architecture):
      return "MAESTRO has no experimental capability for architecture \(architecture)."
    case .missingEvidence:
      return "MAESTRO analysis requires stationary routing evidence."
    case .invalidTopology(let reason):
      return "Invalid model expert topology: \(reason)"
    case .duplicateEvidence(let coordinate):
      return "MAESTRO evidence duplicates \(Self.name(coordinate))."
    case .missingExpertEvidence(let coordinate):
      return "MAESTRO evidence is missing \(Self.name(coordinate))."
    case .unexpectedExpertEvidence(let coordinate):
      return "MAESTRO evidence contains unknown \(Self.name(coordinate))."
    case .invalidEvidence(let coordinate, let reason):
      return "MAESTRO evidence for \(Self.name(coordinate)) is invalid: \(reason)"
    case .invalidStationaryDistribution(let total):
      return "MAESTRO stationary probabilities must sum to 1; found \(total)."
    case .invalidRetentionEvidence(let reason):
      return "MAESTRO retention evidence is invalid: \(reason)"
    case .candidateInvalid(let errors):
      return "MAESTRO candidate failed structural validation: \(errors.joined(separator: "; "))"
    }
  }

  private static func name(_ coordinate: ExpertCoordinate) -> String {
    "L\(coordinate.layerIndex):E\(coordinate.expertIndex)"
  }
}

public struct MAESTROPruningStrategy: PruningStrategy {
  public let descriptor = StrategyDescriptor(
    identifier: .init(rawValue: "maestro"),
    version: "arxiv-2607.08601v1",
    maturity: .experimental,
    supportedArchitectures: Set(MAESTROAdapterCapability.supported.map(\.architecture))
  )

  public init() {}

  public func proposeCandidates(
    for request: StrategyAnalysisRequest
  ) async throws -> StrategyAnalysisResult {
    guard let topology = request.topology else {
      throw MAESTROStrategyError.missingTopology
    }
    guard
      let capability = MAESTROAdapterCapability.capability(
        for: topology.architecture
      )
    else {
      throw MAESTROStrategyError.unsupportedArchitecture(topology.architecture)
    }
    guard let evidence = request.maestroExpertEvidence else {
      throw MAESTROStrategyError.missingEvidence
    }

    let topologyByLayer = try validate(topology: topology)
    let evidenceByCoordinate = try validate(evidence: evidence, topology: topologyByLayer)
    let retention = request.retentionEvidence ?? .init(recoveryUsage: .notPerformed)
    try validate(retention: retention)

    let rawScores = evidenceByCoordinate.mapValues(\.stationaryProbability)
    let percentiles = StrategyPercentileNormalizer.normalize(rawScores)
    let expertScores = evidenceByCoordinate.map { coordinate, item in
      StrategyExpertScore(
        coordinate: coordinate,
        strategyIdentifier: descriptor.identifier,
        rawScore: item.stationaryProbability,
        percentile: percentiles[coordinate] ?? 0,
        routedTokenCount: item.routingVisitCount
      )
    }.sorted(by: Self.scoreCoordinateOrder)

    var plan = OptimizationPlan(
      projectID: request.projectID,
      sourceArtifactID: request.artifactID,
      objective: request.objective,
      strategy: descriptor,
      pruningConstraints: request.constraints,
      strategyProposedRemovals: []
    )
    let validator = OptimizationPlanValidator()
    let preflight = validator.validate(plan: plan, topology: topology)
    guard preflight.isExecutable else {
      throw MAESTROStrategyError.candidateInvalid(preflight.result.errors)
    }

    plan.strategyProposedRemovals = selectRemovals(
      scores: rawScores,
      topology: topologyByLayer,
      constraints: request.constraints
    )
    let validation = validator.validate(plan: plan, topology: topology)
    guard validation.isExecutable else {
      throw MAESTROStrategyError.candidateInvalid(validation.result.errors)
    }
    plan.validation = validation.result

    var warnings = capability.limitations
    warnings.append("Recovery is never run implicitly by the MAESTRO adapter.")
    if retention.oneShotRetention == nil {
      warnings.append("One-shot retention has not been measured for this candidate.")
    }
    if retention.postRecoveryRetention == nil {
      warnings.append(
        "Post-recovery retention is unavailable because external recovery was not performed.")
    }

    return StrategyAnalysisResult(
      analysisID: request.id,
      descriptor: descriptor,
      candidatePlans: [plan],
      expertScores: expertScores,
      retentionEvidence: retention,
      warnings: warnings
    )
  }

  private func validate(
    topology: ModelExpertTopology
  ) throws -> [Int: ExpertLayerTopology] {
    guard !topology.layers.isEmpty else {
      throw MAESTROStrategyError.invalidTopology("no expert layers")
    }
    var result: [Int: ExpertLayerTopology] = [:]
    for layer in topology.layers {
      guard layer.layerIndex >= 0, layer.expertCount > 0,
        layer.trainedTopK > 0, layer.trainedTopK <= layer.expertCount
      else {
        throw MAESTROStrategyError.invalidTopology("invalid layer \(layer.layerIndex)")
      }
      guard result.updateValue(layer, forKey: layer.layerIndex) == nil else {
        throw MAESTROStrategyError.invalidTopology("duplicate layer \(layer.layerIndex)")
      }
    }
    return result
  }

  private func validate(
    evidence: [MAESTROExpertEvidence],
    topology: [Int: ExpertLayerTopology]
  ) throws -> [ExpertCoordinate: MAESTROExpertEvidence] {
    var result: [ExpertCoordinate: MAESTROExpertEvidence] = [:]
    for item in evidence {
      guard let layer = topology[item.coordinate.layerIndex],
        item.coordinate.expertIndex >= 0,
        item.coordinate.expertIndex < layer.expertCount
      else {
        throw MAESTROStrategyError.unexpectedExpertEvidence(item.coordinate)
      }
      guard result.updateValue(item, forKey: item.coordinate) == nil else {
        throw MAESTROStrategyError.duplicateEvidence(item.coordinate)
      }
      guard item.stationaryProbability.isFinite,
        item.stationaryProbability >= 0,
        item.stationaryProbability <= 1
      else {
        throw MAESTROStrategyError.invalidEvidence(
          item.coordinate,
          "stationary probability must be finite and within 0...1"
        )
      }
      guard item.routingVisitCount >= 0 else {
        throw MAESTROStrategyError.invalidEvidence(
          item.coordinate,
          "routing visit count must be nonnegative"
        )
      }
    }
    for layer in topology.values {
      for expertIndex in 0..<layer.expertCount {
        let coordinate = ExpertCoordinate(
          layerIndex: layer.layerIndex,
          expertIndex: expertIndex
        )
        guard result[coordinate] != nil else {
          throw MAESTROStrategyError.missingExpertEvidence(coordinate)
        }
      }
    }
    let total = result.values.reduce(0) { $0 + $1.stationaryProbability }
    guard abs(total - 1) <= 1e-6 else {
      throw MAESTROStrategyError.invalidStationaryDistribution(total)
    }
    return result
  }

  private func validate(retention: StrategyRetentionEvidence) throws {
    for (label, value) in [
      ("one-shot retention", retention.oneShotRetention),
      ("post-recovery retention", retention.postRecoveryRetention),
    ] {
      if let value, !value.isFinite || value < 0 {
        throw MAESTROStrategyError.invalidRetentionEvidence(
          "\(label) must be finite and nonnegative"
        )
      }
    }
    switch retention.recoveryUsage {
    case .notPerformed:
      if retention.postRecoveryRetention != nil {
        throw MAESTROStrategyError.invalidRetentionEvidence(
          "post-recovery retention requires externally performed recovery"
        )
      }
    case .performedExternally:
      if retention.oneShotRetention == nil || retention.postRecoveryRetention == nil {
        throw MAESTROStrategyError.invalidRetentionEvidence(
          "external recovery requires both one-shot and post-recovery retention"
        )
      }
    }
  }

  private func selectRemovals(
    scores: [ExpertCoordinate: Double],
    topology: [Int: ExpertLayerTopology],
    constraints: PruningConstraints
  ) -> Set<ExpertCoordinate> {
    var result: Set<ExpertCoordinate> = []
    for layer in topology.values {
      let requested =
        constraints.maximumRemovalFraction == 1
        ? layer.expertCount
        : Int(floor(Double(layer.expertCount) * constraints.maximumRemovalFraction))
      let requiredSurvivors = max(constraints.minimumSurvivorsPerLayer, layer.trainedTopK)
      let removeCount = max(0, min(requested, layer.expertCount - requiredSurvivors))
      let ranked =
        scores
        .filter { $0.key.layerIndex == layer.layerIndex }
        .filter { !constraints.protectedExperts.contains($0.key) }
        .sorted(by: Self.rawScoreOrder)
      result.formUnion(ranked.prefix(removeCount).map(\.key))
    }
    return result
  }

  private static func rawScoreOrder(
    _ lhs: Dictionary<ExpertCoordinate, Double>.Element,
    _ rhs: Dictionary<ExpertCoordinate, Double>.Element
  ) -> Bool {
    if lhs.value != rhs.value { return lhs.value < rhs.value }
    return coordinateOrder(lhs.key, rhs.key)
  }

  private static func scoreCoordinateOrder(
    _ lhs: StrategyExpertScore,
    _ rhs: StrategyExpertScore
  ) -> Bool {
    coordinateOrder(lhs.coordinate, rhs.coordinate)
  }

  private static func coordinateOrder(
    _ lhs: ExpertCoordinate,
    _ rhs: ExpertCoordinate
  ) -> Bool {
    (lhs.layerIndex, lhs.expertIndex) < (rhs.layerIndex, rhs.expertIndex)
  }
}
