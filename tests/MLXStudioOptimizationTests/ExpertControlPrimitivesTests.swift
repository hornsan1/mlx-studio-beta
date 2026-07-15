import Foundation
import MLXStudioDomain
import XCTest
@testable import MLXStudioOptimization

final class ExpertControlPrimitivesTests: XCTestCase {
  func testReviewedKeepMapMustExactlyMatchResolvedPlanMask() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("keep-map-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("plan.json")
    let topology = ModelExpertTopology(
      architecture: "qwen3_moe",
      layers: [
        .init(layerIndex: 0, expertCount: 4, trainedTopK: 1),
        .init(layerIndex: 1, expertCount: 4, trainedTopK: 1),
      ]
    )
    let mask = StructuralExpertMask(removedExpertsByLayer: [0: [3], 1: [2]])
    try Data(#"{"layers":{"0":{"keep":[0,1,2]},"1":{"keep":[0,1,3]}}}"#.utf8)
      .write(to: url)
    XCTAssertNoThrow(try ReviewedKeepMapValidator.validate(url: url, topology: topology, mask: mask))

    try Data(#"{"layers":{"0":{"keep":[0,1,3]},"1":{"keep":[0,1,3]}}}"#.utf8)
      .write(to: url)
    XCTAssertThrowsError(
      try ReviewedKeepMapValidator.validate(url: url, topology: topology, mask: mask)
    ) { error in
      XCTAssertEqual(
        error as? ReviewedKeepMapError,
        .maskMismatch(layer: 0, expected: [0, 1, 2], actual: [0, 1, 3])
      )
    }

    try Data(#"{"layers":{"0":{"keep":[0,1,2]},"1":{"keep":[0,1,3]},"2":{"keep":[0]}}}"#.utf8)
      .write(to: url)
    XCTAssertThrowsError(
      try ReviewedKeepMapValidator.validate(url: url, topology: topology, mask: mask)
    ) { error in
      XCTAssertEqual(error as? ReviewedKeepMapError, .unexpectedTopologyLayer(2))
    }
  }

  func testLiveEstimateIsExplicitAndRespondsToResolvedRemovalFraction() {
    let topology = ModelExpertTopology(
      architecture: "fixture",
      layers: [
        .init(layerIndex: 0, expertCount: 4, trainedTopK: 1),
        .init(layerIndex: 1, expertCount: 4, trainedTopK: 1),
      ]
    )
    let estimate = OptimizationEstimateCalculator().estimate(
      sourceSizeBytes: 1_000,
      topology: topology,
      mask: .init(removedExpertsByLayer: [0: [2, 3], 1: [3]])
    )
    XCTAssertEqual(estimate.displayLabel, "Estimate")
    XCTAssertEqual(estimate.artifactSizeBytes, 700)
    XCTAssertEqual(estimate.peakMemoryBytes, 700)
    XCTAssertEqual(estimate.confidence, 0.35)
  }
}
