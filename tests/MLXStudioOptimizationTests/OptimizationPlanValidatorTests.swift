import Foundation
import MLXStudioDomain
import XCTest

@testable import MLXStudioOptimization

final class OptimizationPlanValidatorTests: XCTestCase {
  private let validator = OptimizationPlanValidator()
  private let topology = ModelExpertTopology(
    architecture: "qwen3_moe",
    layers: [
      .init(layerIndex: 0, expertCount: 8, trainedTopK: 2),
      .init(layerIndex: 1, expertCount: 4, trainedTopK: 2),
    ]
  )

  func testResolvesAutomaticKeepAndRemoveIntoStructuralMask() throws {
    let plan = makePlan(
      constraints: .init(
        minimumSurvivorsPerLayer: 2,
        maximumRemovalFraction: 0.5,
        protectedExperts: [.init(layerIndex: 0, expertIndex: 7)]
      ),
      strategyProposedRemovals: [
        .init(layerIndex: 0, expertIndex: 1),
        .init(layerIndex: 0, expertIndex: 4),
        .init(layerIndex: 0, expertIndex: 7),
        .init(layerIndex: 1, expertIndex: 3),
      ],
      directives: [
        .init(coordinate: .init(layerIndex: 0, expertIndex: 1), action: .keep),
        .init(coordinate: .init(layerIndex: 0, expertIndex: 2), action: .remove),
        .init(coordinate: .init(layerIndex: 1, expertIndex: 3), action: .automatic),
      ]
    )

    let validation = validator.validate(plan: plan, topology: topology)

    XCTAssertTrue(validation.isExecutable)
    XCTAssertEqual(validation.result.status, .valid)
    XCTAssertEqual(validation.structuralMask?.removedExpertsByLayer, [0: [2, 4], 1: [3]])
    XCTAssertEqual(validation.structuralMask?.removalCount, 3)
    XCTAssertEqual(validation.result.warnings.count, 1)
    XCTAssertTrue(validation.result.warnings[0].contains("Protected expert L0:E7"))
    try assertRoundTrip(validation)
  }

  func testExplicitRemoveOfProtectedExpertIsInvalid() {
    let coordinate = ExpertCoordinate(layerIndex: 0, expertIndex: 3)
    let plan = makePlan(
      constraints: .init(
        minimumSurvivorsPerLayer: 2,
        maximumRemovalFraction: 0.5,
        protectedExperts: [coordinate]
      ),
      directives: [.init(coordinate: coordinate, action: .remove)]
    )

    let validation = validator.validate(plan: plan, topology: topology)

    XCTAssertEqual(validation.result.status, .invalid)
    XCTAssertNil(validation.structuralMask)
    XCTAssertTrue(
      validation.result.errors.contains { $0.contains("both protected and explicitly removed") })
  }

  func testRejectsConflictsRangesAndUnsupportedArchitecture() {
    let coordinate = ExpertCoordinate(layerIndex: 3, expertIndex: 99)
    var plan = makePlan(
      constraints: .init(minimumSurvivorsPerLayer: 0, maximumRemovalFraction: 1.1),
      directives: [
        .init(coordinate: coordinate, action: .keep),
        .init(coordinate: coordinate, action: .remove),
      ]
    )
    plan.strategy = .init(
      identifier: .init(rawValue: "fixture"),
      version: "1",
      maturity: .production,
      supportedArchitectures: ["mixtral"]
    )

    let validation = validator.validate(plan: plan, topology: topology)

    XCTAssertFalse(validation.isExecutable)
    XCTAssertTrue(validation.result.errors.contains { $0.contains("unknown layer") })
    XCTAssertTrue(validation.result.errors.contains { $0.contains("conflicting directives") })
    XCTAssertTrue(
      validation.result.errors.contains { $0.contains("does not support architecture") })
    XCTAssertTrue(
      validation.result.errors.contains("Minimum survivors per layer must be positive."))
    XCTAssertTrue(
      validation.result.errors.contains("Maximum removal fraction must be within 0...1."))
  }

  func testRejectsRemovalFractionAndTopKViolations() {
    let plan = makePlan(
      constraints: .init(minimumSurvivorsPerLayer: 1, maximumRemovalFraction: 0.25),
      strategyProposedRemovals: [
        .init(layerIndex: 1, expertIndex: 0),
        .init(layerIndex: 1, expertIndex: 1),
        .init(layerIndex: 1, expertIndex: 2),
      ]
    )
    let validation = validator.validate(plan: plan, topology: topology)

    XCTAssertNil(validation.structuralMask)
    XCTAssertTrue(validation.result.errors.contains { $0.contains("at least 2 must survive") })
    XCTAssertTrue(validation.result.errors.contains { $0.contains("exceeding the 25.0% limit") })
  }

  func testAutomaticDirectiveKeepsCoordinateWhenStrategyDoesNotRemoveIt() {
    let plan = makePlan(
      constraints: .init(minimumSurvivorsPerLayer: 2, maximumRemovalFraction: 0.5),
      directives: [
        .init(coordinate: .init(layerIndex: 0, expertIndex: 5), action: .automatic)
      ]
    )
    let validation = validator.validate(plan: plan, topology: topology)

    XCTAssertEqual(validation.structuralMask?.removedExpertsByLayer, [:])
  }

  func testEstimateIsExplicitlyLabeledAndValidated() throws {
    let estimate = OptimizationEstimate(
      artifactSizeBytes: 1_000,
      peakMemoryBytes: 2_000,
      qualityScore: 0.9,
      tokensPerSecond: 25,
      confidence: 0.75
    )
    XCTAssertEqual(estimate.displayLabel, "Estimate")

    var plan = makePlan(
      constraints: .init(minimumSurvivorsPerLayer: 2, maximumRemovalFraction: 0.5)
    )
    plan.estimate = estimate
    let validation = validator.validate(plan: plan, topology: topology)
    XCTAssertTrue(validation.isExecutable)

    try assertRoundTrip(topology)
    try assertRoundTrip(plan)
    let encoded = String(decoding: try JSONEncoder().encode(estimate), as: UTF8.self)
    XCTAssertFalse(encoded.contains("displayLabel"))
  }

  func testInvalidEstimateCannotBecomeExecutable() {
    var plan = makePlan(
      constraints: .init(minimumSurvivorsPerLayer: 2, maximumRemovalFraction: 0.5)
    )
    plan.estimate = .init(artifactSizeBytes: -1, tokensPerSecond: -.infinity, confidence: 2)
    let validation = validator.validate(plan: plan, topology: topology)

    XCTAssertNil(validation.structuralMask)
    XCTAssertTrue(validation.result.errors.contains("Estimate confidence must be within 0...1."))
    XCTAssertTrue(validation.result.errors.contains("Estimated artifact size cannot be negative."))
    XCTAssertTrue(
      validation.result.errors.contains(
        "Estimated tokens per second must be finite and nonnegative."))
  }

  func testRejectsMissingTopologyAndNormalizesSerializedMasks() throws {
    let plan = makePlan(
      constraints: .init(minimumSurvivorsPerLayer: 1, maximumRemovalFraction: 0.5)
    )
    let validation = validator.validate(
      plan: plan,
      topology: .init(architecture: "  ", layers: [])
    )
    XCTAssertFalse(validation.isExecutable)
    XCTAssertTrue(validation.result.errors.contains("Topology architecture must not be empty."))
    XCTAssertTrue(
      validation.result.errors.contains("Topology must define at least one expert layer."))

    let mask = StructuralExpertMask(removedExpertsByLayer: [2: [4, 1, 4], 3: []])
    XCTAssertEqual(mask.removedExpertsByLayer, [2: [1, 4]])
    try assertRoundTrip(mask)
  }

  private func makePlan(
    constraints: PruningConstraints,
    strategyProposedRemovals: Set<ExpertCoordinate>? = nil,
    directives: [ExpertDirective] = []
  ) -> OptimizationPlan {
    OptimizationPlan(
      projectID: .init(),
      sourceArtifactID: .init(),
      objective: .init(),
      pruningConstraints: constraints,
      strategyProposedRemovals: strategyProposedRemovals,
      expertDirectives: directives
    )
  }

  private func assertRoundTrip<Value: Codable & Equatable>(
    _ value: Value,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    let decoded = try JSONDecoder().decode(Value.self, from: data)
    XCTAssertEqual(decoded, value, file: file, line: line)
  }
}
