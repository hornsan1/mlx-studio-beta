import MLXStudioDomain
import XCTest

@testable import MLXStudioOptimization

final class ActivationNormPruningStrategiesTests: XCTestCase {
  func testMANGoldenRankingAndCandidate() async throws {
    let request = makeRequest(architecture: "qwen3_moe")
    let result = try await MANPruningStrategy().proposeCandidates(for: request)

    XCTAssertEqual(result.descriptor.identifier.rawValue, "man")
    XCTAssertEqual(result.descriptor.maturity, .production)
    XCTAssertEqual(rawScores(result), [0: 2, 1: 1.5, 2: 3, 3: 0])
    XCTAssertEqual(percentiles(result), [0: 2.0 / 3.0, 1: 1.0 / 3.0, 2: 1, 3: 0])
    XCTAssertEqual(
      result.candidatePlans.first?.strategyProposedRemovals,
      [coordinate(1), coordinate(3)]
    )
    XCTAssertEqual(result.candidatePlans.first?.validation.status, .valid)
    XCTAssertEqual(result.warnings.count, 1)
    try assertRoundTrip(result)
  }

  func testMSANGoldenRankingDiffersFromMANWithoutCombiningRawScores() async throws {
    let request = makeRequest(architecture: "qwen3_moe")
    let result = try await MSANPruningStrategy().proposeCandidates(for: request)

    XCTAssertEqual(rawScores(result), [0: 4, 1: 5, 2: 9, 3: 0])
    XCTAssertEqual(percentiles(result), [0: 1.0 / 3.0, 1: 2.0 / 3.0, 2: 1, 3: 0])
    XCTAssertEqual(
      result.candidatePlans.first?.strategyProposedRemovals,
      [coordinate(0), coordinate(3)]
    )
    XCTAssertTrue(
      result.expertScores?.allSatisfy {
        $0.strategyIdentifier.rawValue == "msan"
      } == true)
  }

  func testPercentileNormalizationUsesWithinLayerMidranks() {
    let scores = StrategyPercentileNormalizer.normalize([
      coordinate(0, layer: 0): 4,
      coordinate(1, layer: 0): 4,
      coordinate(2, layer: 0): 9,
      coordinate(0, layer: 1): 2,
    ])

    XCTAssertEqual(scores[coordinate(0, layer: 0)], 0.25)
    XCTAssertEqual(scores[coordinate(1, layer: 0)], 0.25)
    XCTAssertEqual(scores[coordinate(2, layer: 0)], 1)
    XCTAssertEqual(scores[coordinate(0, layer: 1)], 1)
  }

  func testPaperArchitectureFixturesProduceValidatedCandidates() async throws {
    for architecture in MANPruningStrategy.supportedArchitectures.sorted() {
      let request = makeRequest(architecture: architecture)
      let man = try await MANPruningStrategy().proposeCandidates(for: request)
      let msan = try await MSANPruningStrategy().proposeCandidates(for: request)
      XCTAssertEqual(man.candidatePlans.first?.validation.status, .valid, architecture)
      XCTAssertEqual(msan.candidatePlans.first?.validation.status, .valid, architecture)
    }
    XCTAssertEqual(
      MANPruningStrategy.supportedArchitectures,
      ["qwen3_moe", "olmoe", "ernie4_5_moe", "deepseek_v2"]
    )
  }

  func testUnsupportedArchitectureFailsBeforeMissingEvidence() async {
    let base = makeRequest(architecture: "qwen3_moe")
    let request = StrategyAnalysisRequest(
      id: base.id,
      projectID: base.projectID,
      artifactID: base.artifactID,
      calibrationSuiteID: base.calibrationSuiteID,
      objective: base.objective,
      constraints: base.constraints,
      topology: .init(architecture: "qwen3_5_moe", layers: base.topology?.layers ?? []),
      expertActivationEvidence: nil
    )

    do {
      _ = try await MANPruningStrategy().proposeCandidates(for: request)
      XCTFail("Expected unsupported architecture")
    } catch {
      XCTAssertEqual(error as? ActivationNormStrategyError, .unsupportedArchitecture("qwen3_5_moe"))
    }
  }

  func testProtectedExpertIsSkippedAndCandidateRemainsValid() async throws {
    var request = makeRequest(architecture: "qwen3_moe")
    request = StrategyAnalysisRequest(
      id: request.id,
      projectID: request.projectID,
      artifactID: request.artifactID,
      calibrationSuiteID: request.calibrationSuiteID,
      objective: request.objective,
      constraints: .init(
        minimumSurvivorsPerLayer: 2,
        maximumRemovalFraction: 0.5,
        protectedExperts: [coordinate(3)]
      ),
      topology: request.topology,
      expertActivationEvidence: request.expertActivationEvidence
    )
    let result = try await MANPruningStrategy().proposeCandidates(for: request)
    XCTAssertEqual(
      result.candidatePlans.first?.strategyProposedRemovals,
      [coordinate(0), coordinate(1)]
    )
    XCTAssertEqual(result.candidatePlans.first?.validation.status, .valid)
  }

  func testIncompleteDuplicateAndNonFiniteEvidenceAreRejected() async {
    let base = makeRequest(architecture: "qwen3_moe")
    var missing = base.expertActivationEvidence ?? []
    missing.removeLast()
    await assertFailure(
      request: replacingEvidence(in: base, with: missing),
      expected: .missingExpertEvidence(coordinate(3))
    )

    let duplicate = (base.expertActivationEvidence ?? []) + [evidence(0)]
    await assertFailure(
      request: replacingEvidence(in: base, with: duplicate),
      expected: .duplicateEvidence(coordinate(0))
    )

    var nonFinite = base.expertActivationEvidence ?? []
    nonFinite[0] = .init(
      coordinate: coordinate(0),
      routedTokenCount: 1,
      activationNormSum: .infinity,
      squaredActivationNormSum: 1
    )
    do {
      _ = try await MANPruningStrategy().proposeCandidates(
        for: replacingEvidence(in: base, with: nonFinite)
      )
      XCTFail("Expected invalid evidence")
    } catch let error as ActivationNormStrategyError {
      guard case .invalidEvidence(let coordinate, _) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertEqual(coordinate, self.coordinate(0))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testInvalidConstraintsFailValidationWithoutConstructingCandidate() async {
    let base = makeRequest(architecture: "qwen3_moe")
    let request = StrategyAnalysisRequest(
      id: base.id,
      projectID: base.projectID,
      artifactID: base.artifactID,
      calibrationSuiteID: base.calibrationSuiteID,
      objective: base.objective,
      constraints: .init(minimumSurvivorsPerLayer: 0, maximumRemovalFraction: .nan),
      topology: base.topology,
      expertActivationEvidence: base.expertActivationEvidence
    )
    do {
      _ = try await MANPruningStrategy().proposeCandidates(for: request)
      XCTFail("Expected candidate validation failure")
    } catch let error as ActivationNormStrategyError {
      guard case .candidateInvalid(let errors) = error else {
        return XCTFail("Unexpected error: \(error)")
      }
      XCTAssertTrue(errors.contains("Maximum removal fraction must be within 0...1."))
      XCTAssertTrue(errors.contains("Minimum survivors per layer must be positive."))
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  private func makeRequest(architecture: String) -> StrategyAnalysisRequest {
    StrategyAnalysisRequest(
      projectID: .init(),
      artifactID: .init(),
      calibrationSuiteID: .init(),
      objective: .init(notes: "balanced"),
      constraints: .init(minimumSurvivorsPerLayer: 2, maximumRemovalFraction: 0.5),
      evidenceReferences: ["suite": "fixture-general"],
      topology: .init(
        architecture: architecture,
        layers: [.init(layerIndex: 0, expertCount: 4, trainedTopK: 2)]
      ),
      expertActivationEvidence: [evidence(0), evidence(1), evidence(2), evidence(3)]
    )
  }

  private func evidence(_ expert: Int) -> ExpertActivationEvidence {
    let values: [(Int, Double, Double)] = [
      (2, 4, 8),
      (2, 3, 10),
      (2, 6, 18),
      (0, 0, 0),
    ]
    let value = values[expert]
    return .init(
      coordinate: coordinate(expert),
      routedTokenCount: value.0,
      activationNormSum: value.1,
      squaredActivationNormSum: value.2
    )
  }

  private func replacingEvidence(
    in request: StrategyAnalysisRequest,
    with evidence: [ExpertActivationEvidence]
  ) -> StrategyAnalysisRequest {
    StrategyAnalysisRequest(
      id: request.id,
      projectID: request.projectID,
      artifactID: request.artifactID,
      calibrationSuiteID: request.calibrationSuiteID,
      objective: request.objective,
      constraints: request.constraints,
      evidenceReferences: request.evidenceReferences,
      topology: request.topology,
      expertActivationEvidence: evidence
    )
  }

  private func assertFailure(
    request: StrategyAnalysisRequest,
    expected: ActivationNormStrategyError,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    do {
      _ = try await MANPruningStrategy().proposeCandidates(for: request)
      XCTFail("Expected strategy failure", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? ActivationNormStrategyError, expected, file: file, line: line)
    }
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

  private func coordinate(_ expert: Int, layer: Int = 0) -> ExpertCoordinate {
    .init(layerIndex: layer, expertIndex: expert)
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
