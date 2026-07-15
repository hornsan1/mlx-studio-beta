import Foundation
import MLXStudioDomain

/// Resolves strategy-proposed automatic removals with user directives and
/// rejects plans that cannot produce a structurally safe expert mask.
public struct OptimizationPlanValidator: Sendable {
  public init() {}

  public func validate(
    plan: OptimizationPlan,
    topology: ModelExpertTopology
  ) -> OptimizationPlanValidation {
    var errors: [String] = []
    var warnings: [String] = []
    let automaticRemovals = plan.strategyProposedRemovals ?? []

    if topology.architecture.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      errors.append("Topology architecture must not be empty.")
    }
    if topology.layers.isEmpty {
      errors.append("Topology must define at least one expert layer.")
    }

    let layersByIndex = Dictionary(grouping: topology.layers, by: \.layerIndex)
    for (layerIndex, layers) in layersByIndex where layers.count > 1 {
      errors.append("Topology defines layer \(layerIndex) more than once.")
    }
    for layer in topology.layers {
      if layer.layerIndex < 0 {
        errors.append("Topology layer indices must be nonnegative; found \(layer.layerIndex).")
      }
      if layer.expertCount <= 0 {
        errors.append("Layer \(layer.layerIndex) must define at least one expert.")
      }
      if layer.trainedTopK <= 0 || layer.trainedTopK > layer.expertCount {
        errors.append(
          "Layer \(layer.layerIndex) trained top-k \(layer.trainedTopK) must be within 1...\(max(layer.expertCount, 1))."
        )
      }
    }

    let constraints = plan.pruningConstraints
    if constraints.minimumSurvivorsPerLayer <= 0 {
      errors.append("Minimum survivors per layer must be positive.")
    }
    if !constraints.maximumRemovalFraction.isFinite
      || constraints.maximumRemovalFraction < 0
      || constraints.maximumRemovalFraction > 1
    {
      errors.append("Maximum removal fraction must be within 0...1.")
    }

    if let strategy = plan.strategy,
      !strategy.supportedArchitectures.isEmpty,
      !strategy.supportedArchitectures.contains(where: {
        $0.caseInsensitiveCompare(topology.architecture) == .orderedSame
      })
    {
      errors.append(
        "Strategy \(strategy.identifier.rawValue) does not support architecture \(topology.architecture)."
      )
    }

    validateEstimate(plan.estimate, errors: &errors)

    let topologyByIndex = layersByIndex.compactMapValues(\.first)
    for coordinate in automaticRemovals.sorted(by: Self.coordinateOrder) {
      validate(coordinate, role: "Automatic removal", topology: topologyByIndex, errors: &errors)
    }
    for coordinate in constraints.protectedExperts.sorted(by: Self.coordinateOrder) {
      validate(coordinate, role: "Protected expert", topology: topologyByIndex, errors: &errors)
    }

    let directivesByCoordinate = Dictionary(grouping: plan.expertDirectives, by: \.coordinate)
    for (coordinate, directives) in directivesByCoordinate.sorted(by: {
      Self.coordinateOrder($0.key, $1.key)
    }) {
      validate(coordinate, role: "Directive", topology: topologyByIndex, errors: &errors)
      let actions = Set(directives.map(\.action))
      if actions.count > 1 {
        let names = actions.map(\.rawValue).sorted().joined(separator: ", ")
        errors.append("Expert \(Self.name(coordinate)) has conflicting directives: \(names).")
      } else if directives.count > 1 {
        warnings.append(
          "Expert \(Self.name(coordinate)) repeats the same directive; duplicates were collapsed.")
      }
    }

    var removed = automaticRemovals
    for (coordinate, directives) in directivesByCoordinate {
      guard Set(directives.map(\.action)).count == 1,
        let action = directives.first?.action
      else { continue }
      switch action {
      case .automatic:
        if automaticRemovals.contains(coordinate) {
          removed.insert(coordinate)
        } else {
          removed.remove(coordinate)
        }
      case .keep:
        removed.remove(coordinate)
      case .remove:
        removed.insert(coordinate)
        if constraints.protectedExperts.contains(coordinate) {
          errors.append("Expert \(Self.name(coordinate)) is both protected and explicitly removed.")
        }
      }
    }

    for coordinate in removed.intersection(constraints.protectedExperts).sorted(
      by: Self.coordinateOrder)
    {
      let explicitRemove =
        directivesByCoordinate[coordinate]?.contains { $0.action == .remove } == true
      if !explicitRemove {
        removed.remove(coordinate)
        warnings.append(
          "Protected expert \(Self.name(coordinate)) was excluded from automatic removals.")
      }
    }

    var maskLayers: [Int: [Int]] = [:]
    for layer in topology.layers.sorted(by: { $0.layerIndex < $1.layerIndex }) {
      let layerRemoved =
        removed
        .filter { $0.layerIndex == layer.layerIndex }
        .map(\.expertIndex)
        .sorted()
      let survivors = layer.expertCount - layerRemoved.count
      let requiredSurvivors = max(constraints.minimumSurvivorsPerLayer, layer.trainedTopK)
      if survivors < requiredSurvivors {
        errors.append(
          "Layer \(layer.layerIndex) leaves \(survivors) experts; at least \(requiredSurvivors) must survive."
        )
      }
      if constraints.maximumRemovalFraction.isFinite,
        layer.expertCount > 0,
        Double(layerRemoved.count) / Double(layer.expertCount) > constraints.maximumRemovalFraction
      {
        errors.append(
          "Layer \(layer.layerIndex) removes \(layerRemoved.count) of \(layer.expertCount) experts, exceeding the \(Self.percent(constraints.maximumRemovalFraction)) limit."
        )
      }
      if !layerRemoved.isEmpty {
        maskLayers[layer.layerIndex] = layerRemoved
      }
    }

    let uniqueErrors = Array(Set(errors)).sorted()
    let uniqueWarnings = Array(Set(warnings)).sorted()
    guard uniqueErrors.isEmpty else {
      return OptimizationPlanValidation(
        result: .init(status: .invalid, errors: uniqueErrors, warnings: uniqueWarnings),
        structuralMask: nil
      )
    }
    return OptimizationPlanValidation(
      result: .init(status: .valid, warnings: uniqueWarnings),
      structuralMask: StructuralExpertMask(removedExpertsByLayer: maskLayers)
    )
  }

  private func validateEstimate(_ estimate: OptimizationEstimate?, errors: inout [String]) {
    guard let estimate else { return }
    if let confidence = estimate.confidence,
      !confidence.isFinite || confidence < 0 || confidence > 1
    {
      errors.append("Estimate confidence must be within 0...1.")
    }
    if let size = estimate.artifactSizeBytes, size < 0 {
      errors.append("Estimated artifact size cannot be negative.")
    }
    if let memory = estimate.peakMemoryBytes, memory < 0 {
      errors.append("Estimated peak memory cannot be negative.")
    }
    if let throughput = estimate.tokensPerSecond,
      !throughput.isFinite || throughput < 0
    {
      errors.append("Estimated tokens per second must be finite and nonnegative.")
    }
    if let quality = estimate.qualityScore, !quality.isFinite {
      errors.append("Estimated quality score must be finite.")
    }
  }

  private func validate(
    _ coordinate: ExpertCoordinate,
    role: String,
    topology: [Int: ExpertLayerTopology],
    errors: inout [String]
  ) {
    guard let layer = topology[coordinate.layerIndex] else {
      errors.append("\(role) \(Self.name(coordinate)) references an unknown layer.")
      return
    }
    if coordinate.expertIndex < 0 || coordinate.expertIndex >= layer.expertCount {
      errors.append(
        "\(role) \(Self.name(coordinate)) is outside the layer's 0...\(max(layer.expertCount - 1, 0)) expert range."
      )
    }
  }

  private static func coordinateOrder(_ lhs: ExpertCoordinate, _ rhs: ExpertCoordinate) -> Bool {
    (lhs.layerIndex, lhs.expertIndex) < (rhs.layerIndex, rhs.expertIndex)
  }

  private static func name(_ coordinate: ExpertCoordinate) -> String {
    "L\(coordinate.layerIndex):E\(coordinate.expertIndex)"
  }

  private static func percent(_ value: Double) -> String {
    String(format: "%.1f%%", value * 100)
  }
}
