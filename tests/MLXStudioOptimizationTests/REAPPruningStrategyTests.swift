import MLXStudioDomain
import XCTest

@testable import MLXStudioOptimization

final class REAPPruningStrategyTests: XCTestCase {
  func testKimiFixtureProducesGoldenScoresAndValidatedCandidate() async throws {
    let result = try await REAPPruningStrategy(capability: .kimiK25)
      .proposeCandidates(for: request(architecture: "kimi_k25"))

    XCTAssertEqual(result.descriptor.identifier.rawValue, "reap")
    XCTAssertEqual(result.descriptor.maturity, .production)
    XCTAssertEqual(rawScores(result), [0: 1, 1: 3, 2: 2, 3: 0])
    XCTAssertEqual(percentiles(result), [0: 1.0 / 3.0, 1: 1, 2: 2.0 / 3.0, 3: 0])
    XCTAssertEqual(
      result.candidatePlans.first?.strategyProposedRemovals,
      [coordinate(0), coordinate(3)]
    )
    XCTAssertEqual(result.candidatePlans.first?.validation.status, .valid)
    XCTAssertEqual(result.warnings.count, 1)
    try assertRoundTrip(result)
  }

  func testCapabilityFixturesRemainArchitectureSpecific() async throws {
    for capability in REAPAdapterCapability.supported {
      let strategy = REAPPruningStrategy(capability: capability)
      let result = try await strategy.proposeCandidates(
        for: request(architecture: capability.architecture)
      )
      XCTAssertEqual(strategy.descriptor.supportedArchitectures, [capability.architecture])
      XCTAssertEqual(result.candidatePlans.first?.validation.status, .valid)
      XCTAssertEqual(result.expertScores?.count, 4)
    }
  }

  func testMiniMaxPreservesItsSummedSaliencySelectionSemantics() async throws {
    let result = try await REAPPruningStrategy(capability: .minimaxM3VL)
      .proposeCandidates(for: request(architecture: "minimax_m3_vl"))

    XCTAssertEqual(REAPAdapterCapability.minimaxM3VL.scoreAggregation, .accumulatedSum)
    XCTAssertEqual(rawScores(result), [0: 2, 1: 6, 2: 4, 3: 0])
  }

  func testDSV4CapabilityIsExplicitlyAnalysisOnly() async throws {
    let result = try await REAPPruningStrategy(capability: .deepseekV4)
      .proposeCandidates(for: request(architecture: "deepseek_v4"))

    XCTAssertNil(REAPAdapterCapability.deepseekV4.selectorSource)
    XCTAssertFalse(REAPAdapterCapability.deepseekV4.canApplyPrunePlan)
    XCTAssertTrue(result.warnings.contains { $0.contains("analysis-only") })
    XCTAssertTrue(result.warnings.contains { $0.contains("no routed calibration tokens") })
  }

  func testArchitectureMismatchFailsBeforeEvidenceInspection() async {
    let base = request(architecture: "minimax_m3_vl")
    let missingEvidence = StrategyAnalysisRequest(
      id: base.id,
      projectID: base.projectID,
      artifactID: base.artifactID,
      calibrationSuiteID: base.calibrationSuiteID,
      objective: base.objective,
      constraints: base.constraints,
      topology: base.topology,
      routerWeightedExpertEvidence: nil
    )
    do {
      _ = try await REAPPruningStrategy(capability: .kimiK25)
        .proposeCandidates(for: missingEvidence)
      XCTFail("Expected capability mismatch")
    } catch {
      XCTAssertEqual(
        error as? REAPStrategyError,
        .unsupportedArchitecture(expected: "kimi_k25", actual: "minimax_m3_vl")
      )
    }
  }

  func testProtectedExpertIsSkipped() async throws {
    let base = request(architecture: "minimax_m3_vl")
    let protected = StrategyAnalysisRequest(
      id: base.id,
      projectID: base.projectID,
      artifactID: base.artifactID,
      calibrationSuiteID: base.calibrationSuiteID,
      objective: base.objective,
      constraints: .init(
        minimumSurvivorsPerLayer: 2,
        maximumRemovalFraction: 0.5,
        protectedExperts: [coordinate(3)]
      ),
      topology: base.topology,
      routerWeightedExpertEvidence: base.routerWeightedExpertEvidence
    )
    let result = try await REAPPruningStrategy(capability: .minimaxM3VL)
      .proposeCandidates(for: protected)
    XCTAssertEqual(
      result.candidatePlans.first?.strategyProposedRemovals,
      [coordinate(0), coordinate(2)]
    )
  }

  func testMissingAndNonFiniteEvidenceAreRejected() async {
    let base = request(architecture: "kimi_k25")
    var missing = base.routerWeightedExpertEvidence ?? []
    missing.removeLast()
    await assertFailure(
      request: replacingEvidence(in: base, with: missing),
      expected: .missingExpertEvidence(coordinate(3))
    )

    var invalid = base.routerWeightedExpertEvidence ?? []
    invalid[0] = .init(
      coordinate: coordinate(0),
      routedTokenCount: 1,
      gateWeightedActivationNormSum: .infinity
    )
    do {
      _ = try await REAPPruningStrategy(capability: .kimiK25)
        .proposeCandidates(for: replacingEvidence(in: base, with: invalid))
      XCTFail("Expected invalid evidence")
    } catch let error as REAPStrategyError {
      guard case .invalidEvidence(let coordinate, _) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(coordinate, self.coordinate(0))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testCapabilityMetadataPinsExactSpecializedSources() throws {
    XCTAssertEqual(
      REAPAdapterCapability.kimiK25.profilerSource,
      "jang-tools/jang_tools/kimi_prune/jangreap.py"
    )
    XCTAssertEqual(
      REAPAdapterCapability.minimaxM3VL.selectorSource,
      "jang-tools/jang_tools/minimax_m3/reap_select.py"
    )
    XCTAssertEqual(
      REAPAdapterCapability.deepseekV4.profilerSource,
      "jang-tools/jang_tools/dsv4/layer_forward.py"
    )
    XCTAssertEqual(REAPAdapterCapability.kimiK25.scoreAggregation, .routedTokenMean)
    XCTAssertTrue(REAPAdapterCapability.kimiK25.canApplyPrunePlan)
    XCTAssertEqual(
      REAPAdapterCapability.capability(for: "KIMI_K25"),
      .kimiK25
    )
    XCTAssertNil(REAPAdapterCapability.capability(for: "qwen3_5_moe"))
    try assertRoundTrip(REAPAdapterCapability.supported)
  }

  func testSelectionMatchesPythonTieToEvenRounding() async throws {
    let request = StrategyAnalysisRequest(
      projectID: .init(),
      artifactID: .init(),
      calibrationSuiteID: .init(),
      objective: .init(),
      constraints: .init(minimumSurvivorsPerLayer: 1, maximumRemovalFraction: 0.5),
      topology: .init(
        architecture: "kimi_k25",
        layers: [.init(layerIndex: 0, expertCount: 5, trainedTopK: 1)]
      ),
      routerWeightedExpertEvidence: (0..<5).map {
        evidence($0, count: 1, sum: Double($0))
      }
    )
    let result = try await REAPPruningStrategy(capability: .kimiK25)
      .proposeCandidates(for: request)

    XCTAssertEqual(result.candidatePlans.first?.strategyProposedRemovals?.count, 2)
    XCTAssertEqual(
      result.candidatePlans.first?.strategyProposedRemovals,
      [coordinate(0), coordinate(1)]
    )
  }

  private func request(architecture: String) -> StrategyAnalysisRequest {
    StrategyAnalysisRequest(
      projectID: .init(),
      artifactID: .init(),
      calibrationSuiteID: .init(),
      objective: .init(notes: "capability-focused"),
      constraints: .init(minimumSurvivorsPerLayer: 2, maximumRemovalFraction: 0.5),
      topology: .init(
        architecture: architecture,
        layers: [.init(layerIndex: 0, expertCount: 4, trainedTopK: 2)]
      ),
      routerWeightedExpertEvidence: [
        evidence(0, count: 2, sum: 2),
        evidence(1, count: 2, sum: 6),
        evidence(2, count: 2, sum: 4),
        evidence(3, count: 0, sum: 0),
      ]
    )
  }

  private func replacingEvidence(
    in request: StrategyAnalysisRequest,
    with evidence: [RouterWeightedExpertEvidence]
  ) -> StrategyAnalysisRequest {
    StrategyAnalysisRequest(
      id: request.id,
      projectID: request.projectID,
      artifactID: request.artifactID,
      calibrationSuiteID: request.calibrationSuiteID,
      objective: request.objective,
      constraints: request.constraints,
      topology: request.topology,
      routerWeightedExpertEvidence: evidence
    )
  }

  private func assertFailure(
    request: StrategyAnalysisRequest,
    expected: REAPStrategyError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await REAPPruningStrategy(capability: .kimiK25)
        .proposeCandidates(for: request)
      XCTFail("Expected REAP failure", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? REAPStrategyError, expected, file: file, line: line)
    }
  }

  private func evidence(
    _ expert: Int,
    count: Int,
    sum: Double
  ) -> RouterWeightedExpertEvidence {
    .init(
      coordinate: coordinate(expert),
      routedTokenCount: count,
      gateWeightedActivationNormSum: sum
    )
  }

  private func rawScores(_ result: StrategyAnalysisResult) -> [Int: Double] {
    Dictionary(
      uniqueKeysWithValues: (result.expertScores ?? []).map {
        ($0.coordinate.expertIndex, $0.rawScore)
      })
  }

  private func percentiles(_ result: StrategyAnalysisResult) -> [Int: Double] {
    Dictionary(
      uniqueKeysWithValues: (result.expertScores ?? []).map {
        ($0.coordinate.expertIndex, $0.percentile)
      })
  }

  private func coordinate(_ expert: Int) -> ExpertCoordinate {
    .init(layerIndex: 0, expertIndex: expert)
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
