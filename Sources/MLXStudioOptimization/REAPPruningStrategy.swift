import Foundation
import MLXStudioDomain

/// Pinned source authority: `hornsan1/jangq-private` at
/// `5d5487c27fa81d9f51da27264ae855964e334070`.
public enum REAPScoreAggregation: String, Codable, Hashable, Sendable {
  case routedTokenMean
  case accumulatedSum
}

public struct REAPAdapterCapability: Codable, Hashable, Sendable {
  public let architecture: String
  public let profilerSource: String
  public let selectorSource: String?
  public let scoreAggregation: REAPScoreAggregation
  public let limitations: [String]

  private init(
    architecture: String,
    profilerSource: String,
    selectorSource: String?,
    scoreAggregation: REAPScoreAggregation,
    limitations: [String] = []
  ) {
    self.architecture = architecture
    self.profilerSource = profilerSource
    self.selectorSource = selectorSource
    self.scoreAggregation = scoreAggregation
    self.limitations = limitations
  }

  public static let kimiK25 = REAPAdapterCapability(
    architecture: "kimi_k25",
    profilerSource: "jang-tools/jang_tools/kimi_prune/jangreap.py",
    selectorSource: "jang-tools/jang_tools/kimi_prune/jangreap.py",
    scoreAggregation: .routedTokenMean
  )

  public static let minimaxM3VL = REAPAdapterCapability(
    architecture: "minimax_m3_vl",
    profilerSource: "jang-tools/jang_tools/minimax_m3/reap_profile.py",
    selectorSource: "jang-tools/jang_tools/minimax_m3/reap_select.py",
    scoreAggregation: .accumulatedSum
  )

  public static let deepseekV4 = REAPAdapterCapability(
    architecture: "deepseek_v4",
    profilerSource: "jang-tools/jang_tools/dsv4/layer_forward.py",
    selectorSource: nil,
    scoreAggregation: .routedTokenMean,
    limitations: [
      "DSV4 REAP is analysis-only: the pinned converter explicitly retains all 256 experts and does not apply a REAP prune plan."
    ]
  )

  public static let supported: [REAPAdapterCapability] = [
    .kimiK25,
    .minimaxM3VL,
    .deepseekV4,
  ]

  public static func capability(for architecture: String) -> REAPAdapterCapability? {
    supported.first {
      $0.architecture.caseInsensitiveCompare(architecture) == .orderedSame
    }
  }

  public var canApplyPrunePlan: Bool { selectorSource != nil }
}

public enum REAPStrategyError: Error, LocalizedError, Equatable, Sendable {
  case missingTopology
  case unsupportedArchitecture(expected: String, actual: String)
  case missingEvidence
  case invalidTopology(String)
  case duplicateEvidence(ExpertCoordinate)
  case missingExpertEvidence(ExpertCoordinate)
  case unexpectedExpertEvidence(ExpertCoordinate)
  case invalidEvidence(ExpertCoordinate, String)
  case candidateInvalid([String])

  public var errorDescription: String? {
    switch self {
    case .missingTopology:
      return "REAP analysis requires model expert topology."
    case .unsupportedArchitecture(let expected, let actual):
      return "REAP adapter for \(expected) cannot analyze architecture \(actual)."
    case .missingEvidence:
      return "REAP analysis requires gate-weighted activation evidence."
    case .invalidTopology(let reason):
      return "Invalid model expert topology: \(reason)"
    case .duplicateEvidence(let coordinate):
      return "REAP evidence duplicates \(Self.name(coordinate))."
    case .missingExpertEvidence(let coordinate):
      return "REAP evidence is missing \(Self.name(coordinate))."
    case .unexpectedExpertEvidence(let coordinate):
      return "REAP evidence contains unknown \(Self.name(coordinate))."
    case .invalidEvidence(let coordinate, let reason):
      return "REAP evidence for \(Self.name(coordinate)) is invalid: \(reason)"
    case .candidateInvalid(let errors):
      return "REAP candidate failed structural validation: \(errors.joined(separator: "; "))"
    }
  }

  private static func name(_ coordinate: ExpertCoordinate) -> String {
    "L\(coordinate.layerIndex):E\(coordinate.expertIndex)"
  }
}

public struct REAPPruningStrategy: PruningStrategy {
  public let capability: REAPAdapterCapability
  public let descriptor: StrategyDescriptor

  public init(capability: REAPAdapterCapability) {
    self.capability = capability
    self.descriptor = StrategyDescriptor(
      identifier: .init(rawValue: "reap"),
      version: "jangq-5d5487c27fa8",
      maturity: .production,
      supportedArchitectures: [capability.architecture]
    )
  }

  public func proposeCandidates(
    for request: StrategyAnalysisRequest
  ) async throws -> StrategyAnalysisResult {
    guard let topology = request.topology else {
      throw REAPStrategyError.missingTopology
    }
    guard topology.architecture.caseInsensitiveCompare(capability.architecture) == .orderedSame
    else {
      throw REAPStrategyError.unsupportedArchitecture(
        expected: capability.architecture,
        actual: topology.architecture
      )
    }
    guard let evidence = request.routerWeightedExpertEvidence else {
      throw REAPStrategyError.missingEvidence
    }

    let topologyByLayer = try validate(topology: topology)
    let evidenceByCoordinate = try validate(evidence: evidence, topology: topologyByLayer)
    let rawScores = evidenceByCoordinate.mapValues { item in
      switch capability.scoreAggregation {
      case .routedTokenMean:
        return item.routedTokenCount == 0
          ? 0
          : item.gateWeightedActivationNormSum / Double(item.routedTokenCount)
      case .accumulatedSum:
        return item.gateWeightedActivationNormSum
      }
    }
    let percentiles = StrategyPercentileNormalizer.normalize(rawScores)
    let expertScores = evidenceByCoordinate.map { coordinate, item in
      StrategyExpertScore(
        coordinate: coordinate,
        strategyIdentifier: descriptor.identifier,
        rawScore: rawScores[coordinate] ?? 0,
        percentile: percentiles[coordinate] ?? 0,
        routedTokenCount: item.routedTokenCount
      )
    }.sorted {
      ($0.coordinate.layerIndex, $0.coordinate.expertIndex)
        < ($1.coordinate.layerIndex, $1.coordinate.expertIndex)
    }

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
      throw REAPStrategyError.candidateInvalid(preflight.result.errors)
    }

    plan.strategyProposedRemovals = selectRemovals(
      scores: rawScores,
      topology: topologyByLayer,
      constraints: request.constraints
    )
    let validation = validator.validate(plan: plan, topology: topology)
    guard validation.isExecutable else {
      throw REAPStrategyError.candidateInvalid(validation.result.errors)
    }
    plan.validation = validation.result

    var warnings = capability.limitations
    warnings.append(
      contentsOf: expertScores.filter { $0.routedTokenCount == 0 }.map {
        "Expert L\($0.coordinate.layerIndex):E\($0.coordinate.expertIndex) received no routed calibration tokens and was scored 0."
      })
    return StrategyAnalysisResult(
      analysisID: request.id,
      descriptor: descriptor,
      candidatePlans: [plan],
      expertScores: expertScores,
      warnings: warnings
    )
  }

  private func validate(
    topology: ModelExpertTopology
  ) throws -> [Int: ExpertLayerTopology] {
    guard !topology.layers.isEmpty else {
      throw REAPStrategyError.invalidTopology("no expert layers")
    }
    var result: [Int: ExpertLayerTopology] = [:]
    for layer in topology.layers {
      guard layer.layerIndex >= 0, layer.expertCount > 0,
        layer.trainedTopK > 0, layer.trainedTopK <= layer.expertCount
      else {
        throw REAPStrategyError.invalidTopology("invalid layer \(layer.layerIndex)")
      }
      guard result.updateValue(layer, forKey: layer.layerIndex) == nil else {
        throw REAPStrategyError.invalidTopology("duplicate layer \(layer.layerIndex)")
      }
    }
    return result
  }

  private func validate(
    evidence: [RouterWeightedExpertEvidence],
    topology: [Int: ExpertLayerTopology]
  ) throws -> [ExpertCoordinate: RouterWeightedExpertEvidence] {
    var result: [ExpertCoordinate: RouterWeightedExpertEvidence] = [:]
    for item in evidence {
      guard let layer = topology[item.coordinate.layerIndex],
        item.coordinate.expertIndex >= 0,
        item.coordinate.expertIndex < layer.expertCount
      else {
        throw REAPStrategyError.unexpectedExpertEvidence(item.coordinate)
      }
      guard result.updateValue(item, forKey: item.coordinate) == nil else {
        throw REAPStrategyError.duplicateEvidence(item.coordinate)
      }
      guard item.routedTokenCount >= 0 else {
        throw REAPStrategyError.invalidEvidence(item.coordinate, "negative routed token count")
      }
      guard item.gateWeightedActivationNormSum.isFinite,
        item.gateWeightedActivationNormSum >= 0
      else {
        throw REAPStrategyError.invalidEvidence(
          item.coordinate,
          "gate-weighted activation sum must be finite and nonnegative"
        )
      }
      if item.routedTokenCount == 0, item.gateWeightedActivationNormSum != 0 {
        throw REAPStrategyError.invalidEvidence(
          item.coordinate,
          "zero routed tokens must have zero accumulated saliency"
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
          throw REAPStrategyError.missingExpertEvidence(coordinate)
        }
      }
    }
    return result
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
        : Int(
          (Double(layer.expertCount) * constraints.maximumRemovalFraction)
            .rounded(.toNearestOrEven)
        )
      let requiredSurvivors = max(constraints.minimumSurvivorsPerLayer, layer.trainedTopK)
      let removeCount = max(0, min(requested, layer.expertCount - requiredSurvivors))
      let ranked =
        scores
        .filter { $0.key.layerIndex == layer.layerIndex }
        .filter { !constraints.protectedExperts.contains($0.key) }
        .sorted {
          $0.value == $1.value
            ? $0.key.expertIndex < $1.key.expertIndex
            : $0.value < $1.value
        }
      result.formUnion(ranked.prefix(removeCount).map(\.key))
    }
    return result
  }
}
