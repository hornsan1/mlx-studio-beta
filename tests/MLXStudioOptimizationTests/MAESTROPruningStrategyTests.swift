import MLXStudioDomain
import XCTest

@testable import MLXStudioOptimization

final class MAESTROPruningStrategyTests: XCTestCase {
  func testGoldenStationaryMassFixtureProducesUniformValidatedCandidate() async throws {
    let result = try await MAESTROPruningStrategy().proposeCandidates(
      for: request(architecture: "gpt_oss")
    )

    XCTAssertEqual(result.descriptor.identifier.rawValue, "maestro")
    XCTAssertEqual(result.descriptor.version, "arxiv-2607.08601v1")
    XCTAssertEqual(result.descriptor.maturity, .experimental)
    XCTAssertEqual(
      result.candidatePlans.first?.strategyProposedRemovals,
      [
        coordinate(layer: 0, expert: 0), coordinate(layer: 0, expert: 2),
        coordinate(layer: 1, expert: 1), coordinate(layer: 1, expert: 3),
      ]
    )
    XCTAssertEqual(result.candidatePlans.first?.validation.status, .valid)
    XCTAssertEqual(result.retentionEvidence?.recoveryUsage, .notPerformed)
    XCTAssertTrue(result.warnings.contains { $0.contains("never run implicitly") })
    try assertRoundTrip(result)
  }

  func testCapabilityPublishesExactExperimentalLabelAndPaperMatrix() throws {
    XCTAssertEqual(MAESTROAdapterCapability.displayLabel, "Global routing — Experimental")
    XCTAssertFalse(MAESTROAdapterCapability.isEligibleForAutomaticSelection)
    XCTAssertEqual(MAESTROAdapterCapability.paperURL, "https://arxiv.org/abs/2607.08601v1")
    XCTAssertEqual(
      Set(MAESTROAdapterCapability.supported.map(\.architecture)),
      ["gpt_oss", "qwen3_moe"]
    )
    XCTAssertEqual(MAESTROAdapterCapability.gptOSS.survivorPolicy, .uniformPerLayer)
    XCTAssertEqual(
      MAESTROAdapterCapability.capability(for: "QWEN3_MOE"),
      .qwen3MoE
    )
    XCTAssertNil(MAESTROAdapterCapability.capability(for: "qwen3_5_moe"))
    try assertRoundTrip(MAESTROAdapterCapability.supported)
  }

  func testUnsupportedArchitectureFailsBeforeEvidenceInspection() async {
    let unsupported = replacing(
      request(architecture: "qwen3_moe"),
      topology: .init(
        architecture: "qwen3_5_moe",
        layers: [.init(layerIndex: 0, expertCount: 4, trainedTopK: 2)]
      )
    )

    await assertFailure(
      request: unsupported,
      expected: .unsupportedArchitecture("qwen3_5_moe")
    )
  }

  func testPaperSupportedArchitecturesShareTheSameEvidenceContract() async throws {
    for capability in MAESTROAdapterCapability.supported {
      let result = try await MAESTROPruningStrategy().proposeCandidates(
        for: request(architecture: capability.architecture)
      )
      XCTAssertEqual(result.expertScores?.count, 8)
      XCTAssertEqual(result.candidatePlans.first?.validation.status, .valid)
    }
  }

  func testRecoveryEvidenceKeepsOneShotAndPostRecoveryMeasurementsSeparate() async throws {
    let evidence = StrategyRetentionEvidence(
      recoveryUsage: .performedExternally,
      oneShotRetention: 0.7854,
      postRecoveryRetention: 0.9890
    )
    let result = try await MAESTROPruningStrategy().proposeCandidates(
      for: replacing(request(architecture: "gpt_oss"), retention: evidence)
    )

    XCTAssertEqual(result.retentionEvidence, evidence)
    XCTAssertFalse(result.warnings.contains { $0.contains("has not been measured") })
    XCTAssertFalse(result.warnings.contains { $0.contains("unavailable") })
  }

  func testRecoveryCannotBeHiddenOrReportedWithoutBothMeasurements() async {
    await assertFailure(
      request: replacing(
        request(architecture: "gpt_oss"),
        retention: .init(
          recoveryUsage: .notPerformed,
          oneShotRetention: 0.8,
          postRecoveryRetention: 0.9
        )
      ),
      expected: .invalidRetentionEvidence(
        "post-recovery retention requires externally performed recovery"
      )
    )
    await assertFailure(
      request: replacing(
        request(architecture: "gpt_oss"),
        retention: .init(
          recoveryUsage: .performedExternally,
          oneShotRetention: 0.8
        )
      ),
      expected: .invalidRetentionEvidence(
        "external recovery requires both one-shot and post-recovery retention"
      )
    )
  }

  func testStationaryDistributionAndCoverageAreValidated() async {
    let base = request(architecture: "gpt_oss")
    var missing = base.maestroExpertEvidence ?? []
    missing.removeLast()
    await assertFailure(
      request: replacing(base, evidence: missing),
      expected: .missingExpertEvidence(coordinate(layer: 1, expert: 3))
    )

    var invalidTotal = base.maestroExpertEvidence ?? []
    invalidTotal[0] = .init(
      coordinate: invalidTotal[0].coordinate,
      stationaryProbability: 0.20,
      routingVisitCount: 10
    )
    do {
      _ = try await MAESTROPruningStrategy().proposeCandidates(
        for: replacing(base, evidence: invalidTotal)
      )
      XCTFail("Expected invalid stationary distribution")
    } catch let error as MAESTROStrategyError {
      guard case .invalidStationaryDistribution(let total) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(total, 1.15, accuracy: 1e-12)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testProtectedExpertAndTrainedTopKRemainStructuralGates() async throws {
    let base = request(architecture: "qwen3_moe")
    let constrained = replacing(
      base,
      constraints: .init(
        minimumSurvivorsPerLayer: 1,
        maximumRemovalFraction: 0.75,
        protectedExperts: [coordinate(layer: 0, expert: 0)]
      )
    )
    let result = try await MAESTROPruningStrategy().proposeCandidates(for: constrained)

    XCTAssertEqual(
      result.candidatePlans.first?.strategyProposedRemovals,
      [
        coordinate(layer: 0, expert: 2), coordinate(layer: 0, expert: 3),
        coordinate(layer: 1, expert: 1), coordinate(layer: 1, expert: 3),
      ]
    )
  }

  private func request(architecture: String) -> StrategyAnalysisRequest {
    StrategyAnalysisRequest(
      projectID: .init(),
      artifactID: .init(),
      calibrationSuiteID: .init(),
      objective: .init(notes: "MAESTRO adapter fixture"),
      constraints: .init(minimumSurvivorsPerLayer: 2, maximumRemovalFraction: 0.5),
      topology: .init(
        architecture: architecture,
        layers: [
          .init(layerIndex: 0, expertCount: 4, trainedTopK: 2),
          .init(layerIndex: 1, expertCount: 4, trainedTopK: 2),
        ]
      ),
      maestroExpertEvidence: [
        evidence(layer: 0, expert: 0, probability: 0.05),
        evidence(layer: 0, expert: 1, probability: 0.20),
        evidence(layer: 0, expert: 2, probability: 0.10),
        evidence(layer: 0, expert: 3, probability: 0.15),
        evidence(layer: 1, expert: 0, probability: 0.18),
        evidence(layer: 1, expert: 1, probability: 0.07),
        evidence(layer: 1, expert: 2, probability: 0.16),
        evidence(layer: 1, expert: 3, probability: 0.09),
      ]
    )
  }

  private func replacing(
    _ request: StrategyAnalysisRequest,
    topology: ModelExpertTopology? = nil,
    constraints: PruningConstraints? = nil,
    evidence: [MAESTROExpertEvidence]? = nil,
    retention: StrategyRetentionEvidence? = nil
  ) -> StrategyAnalysisRequest {
    StrategyAnalysisRequest(
      id: request.id,
      projectID: request.projectID,
      artifactID: request.artifactID,
      calibrationSuiteID: request.calibrationSuiteID,
      objective: request.objective,
      constraints: constraints ?? request.constraints,
      evidenceReferences: request.evidenceReferences,
      topology: topology ?? request.topology,
      maestroExpertEvidence: evidence ?? request.maestroExpertEvidence,
      retentionEvidence: retention ?? request.retentionEvidence
    )
  }

  private func evidence(
    layer: Int,
    expert: Int,
    probability: Double
  ) -> MAESTROExpertEvidence {
    .init(
      coordinate: coordinate(layer: layer, expert: expert),
      stationaryProbability: probability,
      routingVisitCount: 10
    )
  }

  private func coordinate(layer: Int, expert: Int) -> ExpertCoordinate {
    .init(layerIndex: layer, expertIndex: expert)
  }

  private func assertFailure(
    request: StrategyAnalysisRequest,
    expected: MAESTROStrategyError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await MAESTROPruningStrategy().proposeCandidates(for: request)
      XCTFail("Expected MAESTRO failure", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? MAESTROStrategyError, expected, file: file, line: line)
    }
  }

  private func assertRoundTrip<Value: Codable & Equatable>(
    _ value: Value,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let data = try JSONEncoder().encode(value)
    XCTAssertEqual(try JSONDecoder().decode(Value.self, from: data), value, file: file, line: line)
  }
}
