import Foundation
import MLXStudioDomain

/// Literature/spec provenance:
/// - Liu et al., arXiv:2606.15716v1, section 4.4.
/// - Reference implementation `ZongfangLiu/unified-expert-pruning` at
///   `0482ca78349ad2804c70a78526b055bfd9259dc4`.
///
/// MAN is S(1, 0, 1): mean L2 activation norm over routed tokens.
/// MSAN is S(1, 0, 2): mean squared L2 activation norm over routed tokens.
/// Both are gate-free and their raw values are never combined.

public enum ActivationNormStrategyError: Error, LocalizedError, Equatable, Sendable {
  case missingTopology
  case missingEvidence
  case unsupportedArchitecture(String)
  case invalidTopology(String)
  case duplicateEvidence(ExpertCoordinate)
  case missingExpertEvidence(ExpertCoordinate)
  case unexpectedExpertEvidence(ExpertCoordinate)
  case invalidEvidence(ExpertCoordinate, String)
  case candidateInvalid([String])

  public var errorDescription: String? {
    switch self {
    case .missingTopology:
      return "MAN/MSAN analysis requires model expert topology."
    case .missingEvidence:
      return "MAN/MSAN analysis requires routed-token activation evidence."
    case .unsupportedArchitecture(let architecture):
      return "MAN/MSAN is not validated for architecture \(architecture)."
    case .invalidTopology(let reason):
      return "Invalid model expert topology: \(reason)"
    case .duplicateEvidence(let coordinate):
      return "Activation evidence contains duplicate expert \(Self.name(coordinate))."
    case .missingExpertEvidence(let coordinate):
      return "Activation evidence is missing expert \(Self.name(coordinate))."
    case .unexpectedExpertEvidence(let coordinate):
      return "Activation evidence contains unknown expert \(Self.name(coordinate))."
    case .invalidEvidence(let coordinate, let reason):
      return "Activation evidence for \(Self.name(coordinate)) is invalid: \(reason)"
    case .candidateInvalid(let errors):
      return "Strategy candidate failed structural validation: \(errors.joined(separator: "; "))"
    }
  }

  private static func name(_ coordinate: ExpertCoordinate) -> String {
    "L\(coordinate.layerIndex):E\(coordinate.expertIndex)"
  }
}

public struct MANPruningStrategy: PruningStrategy {
  public static let supportedArchitectures: Set<String> = ActivationNormStrategySupport
    .architectures

  public let descriptor = StrategyDescriptor(
    identifier: .init(rawValue: "man"),
    version: "arxiv-2606.15716-v1",
    maturity: .production,
    supportedArchitectures: supportedArchitectures
  )

  public init() {}

  public func proposeCandidates(
    for request: StrategyAnalysisRequest
  ) async throws -> StrategyAnalysisResult {
    try ActivationNormStrategyEngine(kind: .man, descriptor: descriptor).propose(for: request)
  }
}

public struct MSANPruningStrategy: PruningStrategy {
  public static let supportedArchitectures: Set<String> = ActivationNormStrategySupport
    .architectures

  public let descriptor = StrategyDescriptor(
    identifier: .init(rawValue: "msan"),
    version: "arxiv-2606.15716-v1",
    maturity: .production,
    supportedArchitectures: supportedArchitectures
  )

  public init() {}

  public func proposeCandidates(
    for request: StrategyAnalysisRequest
  ) async throws -> StrategyAnalysisResult {
    try ActivationNormStrategyEngine(kind: .msan, descriptor: descriptor).propose(for: request)
  }
}

private enum ActivationNormStrategySupport {
  /// The exact model_type identifiers represented in the paper's four-model
  /// validation matrix. Aliases and later families require their own gate.
  static let architectures: Set<String> = [
    "qwen3_moe",
    "olmoe",
    "ernie4_5_moe",
    "deepseek_v2",
  ]
}

private struct ActivationNormStrategyEngine {
  enum Kind {
    case man
    case msan
  }

  let kind: Kind
  let descriptor: StrategyDescriptor

  func propose(for request: StrategyAnalysisRequest) throws -> StrategyAnalysisResult {
    guard let topology = request.topology else {
      throw ActivationNormStrategyError.missingTopology
    }
    guard
      descriptor.supportedArchitectures.contains(where: {
        $0.caseInsensitiveCompare(topology.architecture) == .orderedSame
      })
    else {
      throw ActivationNormStrategyError.unsupportedArchitecture(topology.architecture)
    }
    guard let evidence = request.expertActivationEvidence else {
      throw ActivationNormStrategyError.missingEvidence
    }

    let topologyByLayer = try validatedTopology(topology)
    let evidenceByCoordinate = try validatedEvidence(evidence, topology: topologyByLayer)
    let scored = score(evidenceByCoordinate)
    let percentiles = StrategyPercentileNormalizer.normalize(
      scored.mapValues(\.rawScore)
    )
    let expertScores = scored.map { coordinate, value in
      StrategyExpertScore(
        coordinate: coordinate,
        strategyIdentifier: descriptor.identifier,
        rawScore: value.rawScore,
        percentile: percentiles[coordinate] ?? 0,
        routedTokenCount: value.routedTokenCount
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
      throw ActivationNormStrategyError.candidateInvalid(preflight.result.errors)
    }

    let removals = proposedRemovals(
      scores: scored.mapValues(\.rawScore),
      topology: topologyByLayer,
      constraints: request.constraints
    )
    plan.strategyProposedRemovals = removals
    let validation = validator.validate(plan: plan, topology: topology)
    guard validation.isExecutable else {
      throw ActivationNormStrategyError.candidateInvalid(validation.result.errors)
    }
    plan.validation = validation.result

    let zeroRouteWarnings =
      expertScores
      .filter { $0.routedTokenCount == 0 }
      .map {
        "Expert L\($0.coordinate.layerIndex):E\($0.coordinate.expertIndex) received no routed calibration tokens and was scored 0."
      }
    return StrategyAnalysisResult(
      analysisID: request.id,
      descriptor: descriptor,
      candidatePlans: [plan],
      expertScores: expertScores,
      warnings: zeroRouteWarnings
    )
  }

  private func validatedTopology(
    _ topology: ModelExpertTopology
  ) throws -> [Int: ExpertLayerTopology] {
    guard !topology.layers.isEmpty else {
      throw ActivationNormStrategyError.invalidTopology("no expert layers")
    }
    var result: [Int: ExpertLayerTopology] = [:]
    for layer in topology.layers {
      guard layer.layerIndex >= 0 else {
        throw ActivationNormStrategyError.invalidTopology("negative layer index")
      }
      guard layer.expertCount > 0 else {
        throw ActivationNormStrategyError.invalidTopology(
          "layer \(layer.layerIndex) has no experts")
      }
      guard layer.trainedTopK > 0, layer.trainedTopK <= layer.expertCount else {
        throw ActivationNormStrategyError.invalidTopology(
          "layer \(layer.layerIndex) has invalid trained top-k")
      }
      guard result.updateValue(layer, forKey: layer.layerIndex) == nil else {
        throw ActivationNormStrategyError.invalidTopology(
          "layer \(layer.layerIndex) is duplicated")
      }
    }
    return result
  }

  private func validatedEvidence(
    _ evidence: [ExpertActivationEvidence],
    topology: [Int: ExpertLayerTopology]
  ) throws -> [ExpertCoordinate: ExpertActivationEvidence] {
    var result: [ExpertCoordinate: ExpertActivationEvidence] = [:]
    for item in evidence {
      guard let layer = topology[item.coordinate.layerIndex],
        item.coordinate.expertIndex >= 0,
        item.coordinate.expertIndex < layer.expertCount
      else {
        throw ActivationNormStrategyError.unexpectedExpertEvidence(item.coordinate)
      }
      guard result.updateValue(item, forKey: item.coordinate) == nil else {
        throw ActivationNormStrategyError.duplicateEvidence(item.coordinate)
      }
      guard item.routedTokenCount >= 0 else {
        throw ActivationNormStrategyError.invalidEvidence(
          item.coordinate, "routed token count is negative")
      }
      guard item.activationNormSum.isFinite, item.activationNormSum >= 0 else {
        throw ActivationNormStrategyError.invalidEvidence(
          item.coordinate, "activation norm sum must be finite and nonnegative")
      }
      guard item.squaredActivationNormSum.isFinite,
        item.squaredActivationNormSum >= 0
      else {
        throw ActivationNormStrategyError.invalidEvidence(
          item.coordinate, "squared activation norm sum must be finite and nonnegative")
      }
      if item.routedTokenCount == 0,
        item.activationNormSum != 0 || item.squaredActivationNormSum != 0
      {
        throw ActivationNormStrategyError.invalidEvidence(
          item.coordinate, "zero routed tokens must have zero accumulated norms")
      }
    }

    for layer in topology.values {
      for expertIndex in 0..<layer.expertCount {
        let coordinate = ExpertCoordinate(
          layerIndex: layer.layerIndex,
          expertIndex: expertIndex
        )
        guard result[coordinate] != nil else {
          throw ActivationNormStrategyError.missingExpertEvidence(coordinate)
        }
      }
    }
    return result
  }

  private func score(
    _ evidence: [ExpertCoordinate: ExpertActivationEvidence]
  ) -> [ExpertCoordinate: (rawScore: Double, routedTokenCount: Int)] {
    evidence.mapValues { item in
      guard item.routedTokenCount > 0 else { return (0, 0) }
      let sum = kind == .man ? item.activationNormSum : item.squaredActivationNormSum
      return (sum / Double(item.routedTokenCount), item.routedTokenCount)
    }
  }

  private func proposedRemovals(
    scores: [ExpertCoordinate: Double],
    topology: [Int: ExpertLayerTopology],
    constraints: PruningConstraints
  ) -> Set<ExpertCoordinate> {
    var result: Set<ExpertCoordinate> = []
    for layer in topology.values {
      let fractionCount =
        constraints.maximumRemovalFraction == 1
        ? layer.expertCount
        : Int(floor(Double(layer.expertCount) * constraints.maximumRemovalFraction))
      let requiredSurvivors = max(
        constraints.minimumSurvivorsPerLayer,
        layer.trainedTopK
      )
      let structuralCount = max(0, layer.expertCount - requiredSurvivors)
      let removeCount = max(0, min(fractionCount, structuralCount))
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

enum StrategyPercentileNormalizer {
  static func normalize(
    _ rawScores: [ExpertCoordinate: Double]
  ) -> [ExpertCoordinate: Double] {
    let byLayer = Dictionary(grouping: rawScores, by: { $0.key.layerIndex })
    var result: [ExpertCoordinate: Double] = [:]
    for entries in byLayer.values {
      let sorted = entries.sorted {
        if $0.value != $1.value { return $0.value < $1.value }
        return $0.key.expertIndex < $1.key.expertIndex
      }
      if sorted.count == 1, let coordinate = sorted.first?.key {
        result[coordinate] = 1
        continue
      }
      var start = 0
      while start < sorted.count {
        var end = start
        while end + 1 < sorted.count, sorted[end + 1].value == sorted[start].value {
          end += 1
        }
        let midpoint = (Double(start) + Double(end)) / 2
        let percentile = midpoint / Double(sorted.count - 1)
        for index in start...end {
          result[sorted[index].key] = percentile
        }
        start = end + 1
      }
    }
    return result
  }
}
