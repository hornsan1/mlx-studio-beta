import Foundation
import MLXStudioDomain

public enum ReviewedKeepMapError: Error, LocalizedError, Equatable, Sendable {
  case unreadable(String)
  case missingLayers
  case invalidLayer(String)
  case unexpectedTopologyLayer(Int)
  case missingTopologyLayer(Int)
  case outOfRange(layer: Int, expert: Int)
  case maskMismatch(layer: Int, expected: [Int], actual: [Int])

  public var errorDescription: String? {
    switch self {
    case .unreadable(let message): return "Reviewed keep map is unreadable: \(message)"
    case .missingLayers: return "Reviewed keep map must contain a non-empty layers object."
    case .invalidLayer(let layer): return "Reviewed keep map contains invalid layer \(layer)."
    case .unexpectedTopologyLayer(let layer):
      return "Reviewed keep map contains layer \(layer), which is not present in the source topology."
    case .missingTopologyLayer(let layer): return "Reviewed keep map is missing expert layer \(layer)."
    case .outOfRange(let layer, let expert):
      return "Reviewed keep map expert L\(layer):E\(expert) is outside the source topology."
    case .maskMismatch(let layer, let expected, let actual):
      return "Reviewed keep map layer \(layer) does not match the plan (expected \(expected), found \(actual))."
    }
  }
}

/// Confirms that the reviewed Python keep map and the Swift plan resolve to
/// exactly the same per-layer expert mask before destructive work starts.
public enum ReviewedKeepMapValidator {
  public static func validate(
    url: URL,
    topology: ModelExpertTopology,
    mask: StructuralExpertMask
  ) throws {
    let data: Data
    do { data = try Data(contentsOf: url) } catch {
      throw ReviewedKeepMapError.unreadable(error.localizedDescription)
    }
    let object: Any
    do { object = try JSONSerialization.jsonObject(with: data) } catch {
      throw ReviewedKeepMapError.unreadable(error.localizedDescription)
    }
    guard let root = object as? [String: Any],
          let layers = root["layers"] as? [String: Any], !layers.isEmpty else {
      throw ReviewedKeepMapError.missingLayers
    }
    var keepByLayer: [Int: [Int]] = [:]
    for (rawLayer, value) in layers {
      guard let layer = Int(rawLayer),
            let layerObject = value as? [String: Any],
            let keep = layerObject["keep"] as? [Int], !keep.isEmpty,
            Set(keep).count == keep.count else {
        throw ReviewedKeepMapError.invalidLayer(rawLayer)
      }
      keepByLayer[layer] = keep.sorted()
    }
    let topologyLayers = Set(topology.layers.map(\.layerIndex))
    if let unexpected = keepByLayer.keys.sorted().first(where: { !topologyLayers.contains($0) }) {
      throw ReviewedKeepMapError.unexpectedTopologyLayer(unexpected)
    }
    for layer in topology.layers {
      guard let actual = keepByLayer[layer.layerIndex] else {
        throw ReviewedKeepMapError.missingTopologyLayer(layer.layerIndex)
      }
      if let invalid = actual.first(where: { $0 < 0 || $0 >= layer.expertCount }) {
        throw ReviewedKeepMapError.outOfRange(layer: layer.layerIndex, expert: invalid)
      }
      let removed = mask.removedExperts(inLayer: layer.layerIndex)
      let expected = (0..<layer.expertCount).filter { !removed.contains($0) }
      guard actual == expected else {
        throw ReviewedKeepMapError.maskMismatch(
          layer: layer.layerIndex,
          expected: expected,
          actual: actual
        )
      }
    }
  }
}

public struct OptimizationEstimateCalculator: Sendable {
  public init() {}

  /// Produces a deliberately low-confidence planning estimate. The 80% expert
  /// weight assumption is shown by the UI and never stored as a measurement.
  public func estimate(
    sourceSizeBytes: Int64,
    topology: ModelExpertTopology,
    mask: StructuralExpertMask,
    assumedExpertWeightFraction: Double = 0.8
  ) -> OptimizationEstimate {
    let totalExperts = topology.layers.reduce(0) { $0 + max($1.expertCount, 0) }
    let removedExperts = topology.layers.reduce(0) {
      $0 + mask.removedExperts(inLayer: $1.layerIndex).count
    }
    let removalFraction = totalExperts > 0
      ? Double(removedExperts) / Double(totalExperts) : 0
    let expertFraction = min(max(assumedExpertWeightFraction, 0), 1)
    let retainedFraction = max(0, 1 - removalFraction * expertFraction)
    let estimatedBytes = Int64((Double(max(sourceSizeBytes, 0)) * retainedFraction).rounded())
    return OptimizationEstimate(
      artifactSizeBytes: estimatedBytes,
      peakMemoryBytes: estimatedBytes,
      confidence: totalExperts > 0 && sourceSizeBytes > 0 ? 0.35 : 0
    )
  }
}
