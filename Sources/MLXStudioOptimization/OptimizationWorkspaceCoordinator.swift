import CryptoKit
import Foundation
import MLXStudioDomain
import MLXStudioPersistence

public enum OptimizationWorkspaceError: Error, LocalizedError, Equatable, Sendable {
  case missingTopology
  case missingQuantizationRecipe
  case unexpectedQuantizationRecipe
  case pruningNotConfigured
  case quantizeOnlyContainsPruning
  case unsupportedPruningArchitecture(String)
  case missingReviewedKeepMap
  case missingOutputURL
  case unsafeOutputURL
  case invalidPlan([String])
  case incompleteWorkerRun(String)
  case runtimeVerificationUnavailable
  case verificationFailed(String)
  case recoveryUnavailable
  case recoveryPayloadInvalid

  public var errorDescription: String? {
    switch self {
    case .missingTopology:
      return "This optimization plan requires model expert topology."
    case .missingQuantizationRecipe:
      return "Quantize-only requires a JANG or JANGTQ recipe."
    case .unexpectedQuantizationRecipe:
      return "Prune-only cannot include a quantization recipe."
    case .pruningNotConfigured:
      return "Prune-only requires at least one validated expert removal."
    case .quantizeOnlyContainsPruning:
      return "Quantize-only cannot contain expert removals."
    case .unsupportedPruningArchitecture(let architecture):
      return "Reviewed prune-only build is unavailable for architecture \(architecture)."
    case .missingReviewedKeepMap:
      return "Prune-only requires a reviewed same-suite Expert Lab keep map."
    case .missingOutputURL:
      return "Build actions require a separate output directory."
    case .unsafeOutputURL:
      return "The output directory must be separate from and outside the source model tree."
    case .invalidPlan(let errors):
      return "Optimization plan is invalid: \(errors.joined(separator: "; "))"
    case .incompleteWorkerRun(let role):
      return "The \(role) worker ended without a completion event."
    case .runtimeVerificationUnavailable:
      return "Runtime verification is unavailable, so the artifact was not published."
    case .verificationFailed(let reason):
      return "Artifact verification failed: \(reason)"
    case .recoveryUnavailable:
      return "Only interrupted, cancelled, or failed worker jobs can be recovered."
    case .recoveryPayloadInvalid:
      return "The durable worker job does not contain a recoverable request."
    }
  }
}

public struct OptimizationRuntimeVerification: Codable, Hashable, Sendable {
  public let checks: [String: String]
  public let smokeGenerationID: String?

  public init(checks: [String: String], smokeGenerationID: String? = nil) {
    self.checks = checks
    self.smokeGenerationID = smokeGenerationID
  }
}

public typealias OptimizationRuntimeVerifier = @Sendable (URL) async throws
  -> OptimizationRuntimeVerification

public actor OptimizationWorkspaceCoordinator {
  private let worker: any OptimizationWorker
  private let artifactRepository: ModelArtifactRepository
  private let planRepository: OptimizationPlanRepository
  private let jobRepository: DurableJobRepository
  private let validator: OptimizationPlanValidator
  private let runtimeVerifier: OptimizationRuntimeVerifier?

  public init(
    worker: any OptimizationWorker,
    artifactRepository: ModelArtifactRepository,
    planRepository: OptimizationPlanRepository,
    jobRepository: DurableJobRepository,
    validator: OptimizationPlanValidator = .init(),
    runtimeVerifier: OptimizationRuntimeVerifier? = nil
  ) {
    self.worker = worker
    self.artifactRepository = artifactRepository
    self.planRepository = planRepository
    self.jobRepository = jobRepository
    self.validator = validator
    self.runtimeVerifier = runtimeVerifier
  }

  public nonisolated func events(
    for request: OptimizationWorkspaceRequest
  ) -> AsyncThrowingStream<OptimizationWorkspaceEvent, Error> {
    AsyncThrowingStream { continuation in
      let task = Task {
        await self.execute(request, continuation: continuation)
      }
      continuation.onTermination = { termination in
        if case .cancelled = termination {
          task.cancel()
          Task { await self.cancel(request) }
        }
      }
    }
  }

  public func cancel(_ request: OptimizationWorkspaceRequest) async {
    await worker.cancel(jobID: request.buildJobID)
    await worker.cancel(jobID: request.verificationJobID)
  }

  public func diagnostics() async -> OptimizationWorkerDiagnostics {
    await worker.diagnostics()
  }

  public func review(_ request: OptimizationWorkspaceRequest) throws -> PlanValidationResult {
    try validate(request)
  }

  public func recover(
    jobID: JobID
  ) throws -> AsyncThrowingStream<OptimizationWorkerEventEnvelope, Error> {
    guard let record = try jobRepository.record(id: jobID),
      record.state != .completed
    else {
      throw OptimizationWorkspaceError.recoveryUnavailable
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = record.payloadJSON.data(using: .utf8),
      let snapshot = try? decoder.decode(OptimizationWorkerJobSnapshot.self, from: data)
    else {
      throw OptimizationWorkspaceError.recoveryPayloadInvalid
    }
    return worker.events(for: snapshot.request)
  }

  private func execute(
    _ request: OptimizationWorkspaceRequest,
    continuation: AsyncThrowingStream<OptimizationWorkspaceEvent, Error>.Continuation
  ) async {
    do {
      var plan = request.plan
      let validation = try validate(request)
      plan.validation = validation
      plan.updatedAt = Date()
      try planRepository.upsert(plan)
      continuation.yield(.planReady(plan: plan, validation: validation))

      guard request.action != .analyzeOnly else {
        continuation.yield(.analysisCompleted(planID: plan.id))
        continuation.yield(.completed(planID: plan.id, artifact: nil, verified: false))
        continuation.finish()
        return
      }

      let buildRequest = try makeBuildRequest(request, plan: plan)
      try persistPendingJob(buildRequest, type: "optimization.build")
      let buildStartedAt = Date()
      let buildEvidence = try await forward(
        worker.events(for: buildRequest),
        role: .build,
        continuation: continuation
      )
      guard buildEvidence.completed else {
        throw OptimizationWorkspaceError.incompleteWorkerRun("build")
      }
      try persistCompletedJob(buildRequest.jobID)

      guard let outputURL = request.outputURL else {
        throw OptimizationWorkspaceError.missingOutputURL
      }
      let verificationRequest = OptimizationWorkerRequest(
        jobID: request.verificationJobID,
        projectID: plan.projectID,
        artifactID: plan.sourceArtifactID,
        operation: .validate,
        sourceURL: outputURL,
        partialOutputPolicy: .keep
      )
      try persistPendingJob(verificationRequest, type: "optimization.verification")
      let verificationEvidence = try await forward(
        worker.events(for: verificationRequest),
        role: .verification,
        continuation: continuation
      )
      guard verificationEvidence.completed else {
        throw OptimizationWorkspaceError.incompleteWorkerRun("verification")
      }
      try rejectZeroValidationMetrics(in: verificationEvidence.messages)
      let structuralChecks = try Self.structuralChecks(
        outputURL: outputURL,
        action: request.action
      )
      guard let runtimeVerifier else {
        throw OptimizationWorkspaceError.runtimeVerificationUnavailable
      }
      let runtimeVerification = try await runtimeVerifier(outputURL)
      guard !runtimeVerification.checks.isEmpty else {
        throw OptimizationWorkspaceError.verificationFailed(
          "the runtime verifier returned no evidence"
        )
      }
      try persistCompletedJob(verificationRequest.jobID)
      let artifact = try await registerOutputArtifact(
        for: request,
        plan: plan,
        outputURL: outputURL,
        buildRequest: buildRequest,
        buildStartedAt: buildStartedAt,
        checks: structuralChecks.merging(runtimeVerification.checks) { _, runtime in runtime },
        smokeGenerationID: runtimeVerification.smokeGenerationID
      )
      continuation.yield(.completed(planID: plan.id, artifact: artifact, verified: true))
      continuation.finish()
    } catch {
      let terminalState: DurableJobState = error is CancellationError ? .cancelled : .failed
      try? persistTerminalJob(request.buildJobID, state: terminalState, error: error)
      try? persistTerminalJob(request.verificationJobID, state: terminalState, error: error)
      continuation.finish(throwing: error)
    }
  }

  private func forward(
    _ events: AsyncThrowingStream<OptimizationWorkerEventEnvelope, Error>,
    role: OptimizationWorkspaceWorkerRole,
    continuation: AsyncThrowingStream<OptimizationWorkspaceEvent, Error>.Continuation
  ) async throws -> WorkerRunEvidence {
    var completed = false
    var messages: [String] = []
    for try await event in events {
      continuation.yield(.worker(role: role, event: event))
      if case .completed = event.event { completed = true }
      if case .message(_, let text) = event.event { messages.append(text) }
    }
    return .init(completed: completed, messages: messages)
  }

  private struct WorkerRunEvidence: Sendable {
    let completed: Bool
    let messages: [String]
  }

  private func validate(
    _ request: OptimizationWorkspaceRequest
  ) throws -> PlanValidationResult {
    let pruningConfigured = Self.hasPruning(request.plan)
    switch request.action {
    case .analyzeOnly:
      if pruningConfigured {
        guard let topology = request.topology else {
          throw OptimizationWorkspaceError.missingTopology
        }
        let validation = validator.validate(plan: request.plan, topology: topology).result
        guard validation.status == .valid else {
          throw OptimizationWorkspaceError.invalidPlan(validation.errors)
        }
        return validation
      }
      return .init(status: .valid)

    case .quantizeOnly:
      guard request.plan.quantizationRecipe != nil else {
        throw OptimizationWorkspaceError.missingQuantizationRecipe
      }
      guard !pruningConfigured else {
        throw OptimizationWorkspaceError.quantizeOnlyContainsPruning
      }
      try validateOutput(request)
      return .init(status: .valid)

    case .pruneOnly:
      guard request.plan.quantizationRecipe == nil else {
        throw OptimizationWorkspaceError.unexpectedQuantizationRecipe
      }
      guard pruningConfigured else {
        throw OptimizationWorkspaceError.pruningNotConfigured
      }
      guard let topology = request.topology else {
        throw OptimizationWorkspaceError.missingTopology
      }
      guard topology.architecture.caseInsensitiveCompare("qwen3_moe") == .orderedSame else {
        throw OptimizationWorkspaceError.unsupportedPruningArchitecture(
          topology.architecture
        )
      }
      guard request.reviewedKeepMapURL != nil else {
        throw OptimizationWorkspaceError.missingReviewedKeepMap
      }
      try validateOutput(request)
      let validation = validator.validate(plan: request.plan, topology: topology).result
      guard validation.status == .valid else {
        throw OptimizationWorkspaceError.invalidPlan(validation.errors)
      }
      if let keepMap = request.reviewedKeepMapURL,
         let mask = validator.validate(plan: request.plan, topology: topology).structuralMask {
        try ReviewedKeepMapValidator.validate(url: keepMap, topology: topology, mask: mask)
      }
      return validation
    }
  }

  private func validateOutput(_ request: OptimizationWorkspaceRequest) throws {
    guard let output = request.outputURL else {
      throw OptimizationWorkspaceError.missingOutputURL
    }
    let sourcePath = request.sourceURL.standardizedFileURL
      .resolvingSymlinksInPath().path
    let outputPath = output.standardizedFileURL
      .resolvingSymlinksInPath().path
    let sourcePrefix = sourcePath.hasSuffix("/") ? sourcePath : sourcePath + "/"
    let outputPrefix = outputPath.hasSuffix("/") ? outputPath : outputPath + "/"
    guard sourcePath != outputPath,
      !outputPath.hasPrefix(sourcePrefix),
      !sourcePath.hasPrefix(outputPrefix)
    else {
      throw OptimizationWorkspaceError.unsafeOutputURL
    }
  }

  private func makeBuildRequest(
    _ request: OptimizationWorkspaceRequest,
    plan: OptimizationPlan
  ) throws -> OptimizationWorkerRequest {
    switch request.action {
    case .analyzeOnly:
      preconditionFailure("Analyze-only does not create a worker request")
    case .quantizeOnly:
      guard let recipe = plan.quantizationRecipe else {
        throw OptimizationWorkspaceError.missingQuantizationRecipe
      }
      var parameters = recipe.tensorRoleRules.filter {
        ["method", "hadamard", "block-size", "force-dtype"].contains($0.key)
      }
      parameters["profile"] = recipe.profile
      parameters["method"] = parameters["method"] ?? "mse"
      return OptimizationWorkerRequest(
        jobID: request.buildJobID,
        projectID: plan.projectID,
        artifactID: plan.sourceArtifactID,
        operation: .convert,
        sourceURL: request.sourceURL,
        outputURL: request.outputURL,
        parameters: parameters,
        partialOutputPolicy: .quarantine
      )
    case .pruneOnly:
      guard let keepMap = request.reviewedKeepMapURL else {
        throw OptimizationWorkspaceError.missingReviewedKeepMap
      }
      return OptimizationWorkerRequest(
        jobID: request.buildJobID,
        projectID: plan.projectID,
        artifactID: plan.sourceArtifactID,
        operation: .pruneQwenMoE,
        sourceURL: request.sourceURL,
        outputURL: request.outputURL,
        parameters: [
          "keep-map": keepMap.path,
          "require-reviewed-comparison": "true",
        ],
        partialOutputPolicy: .quarantine
      )
    }
  }

  private static func hasPruning(_ plan: OptimizationPlan) -> Bool {
    plan.strategyProposedRemovals?.isEmpty == false
      || plan.expertDirectives.contains { $0.action == .remove }
  }

  private func registerOutputArtifact(
    for request: OptimizationWorkspaceRequest,
    plan: OptimizationPlan,
    outputURL: URL,
    buildRequest: OptimizationWorkerRequest,
    buildStartedAt: Date,
    checks: [String: String],
    smokeGenerationID: String?
  ) async throws -> ModelArtifact {
    let artifactID = ModelArtifactID()
    let manifestID = ArtifactManifestID()
    let format: ArtifactFormat
    let precision: ArtifactPrecision?
    switch request.action {
    case .analyzeOnly:
      preconditionFailure("Analyze-only does not publish an artifact")
    case .pruneOnly:
      format = .mlx
      precision = .init(rawValue: "bf16")
    case .quantizeOnly:
      if plan.quantizationRecipe?.technology == .jangTQ {
        format = .jangTQ
      } else {
        format = .jang
      }
      precision = plan.quantizationRecipe.map {
        ArtifactPrecision(rawValue: $0.profile)
      }
    }
    let now = Date()
    let sourceFiles = try Self.sourceFiles(at: outputURL)
    let manifestPayload = try Self.json(Dictionary(uniqueKeysWithValues: sourceFiles.map {
      ($0.relativePath, $0.sha256)
    }))
    let manifestHash = SHA256.hash(data: Data(manifestPayload.utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    let artifact = ModelArtifact(
      id: artifactID,
      projectID: plan.projectID,
      parentArtifactID: plan.sourceArtifactID,
      name: request.outputName ?? outputURL.lastPathComponent,
      localURL: outputURL,
      format: format,
      precision: precision,
      state: .ready,
      manifestID: manifestID,
      verificationStatus: .passed,
      contentHash: manifestHash,
      createdAt: now,
      updatedAt: now
    )
    let manifest = ArtifactManifest(
      id: manifestID,
      artifactID: artifactID,
      schemaVersion: 1,
      optimizerVersion: "mlx-studio-workspace-v1",
      optimizationPlanID: plan.id,
      quantizationRecipeID: plan.quantizationRecipe?.id,
      calibrationSuiteID: plan.quantizationRecipe?.calibrationSuiteID,
      manifestHash: manifestHash,
      sourceFiles: sourceFiles,
      metadata: [
        "action": request.action.rawValue,
        "build_job_id": request.buildJobID.rawValue,
        "verification_job_id": request.verificationJobID.rawValue,
        "verification_status": VerificationStatus.passed.rawValue,
        "content_hash_status": "not-computed",
      ],
      createdAt: now
    )
    let persistedBuildJob = try jobRepository.record(id: request.buildJobID) != nil
    let lineage = ArtifactLineage(
      parentArtifactID: plan.sourceArtifactID,
      childArtifactID: artifactID,
      operation: .init(rawValue: request.action.rawValue),
      jobID: persistedBuildJob ? request.buildJobID : nil,
      manifestID: manifestID,
      createdAt: now
    )
    let diagnostics = await worker.diagnostics()
    let buildRun = ArtifactBuildRun(
      planID: plan.id,
      jobID: request.buildJobID,
      outputArtifactID: artifactID,
      workerIdentifier: diagnostics.executable,
      toolVersionsJSON: try Self.json([
        "python": diagnostics.pythonVersion ?? "unknown",
        "tool": diagnostics.toolVersion ?? "unknown",
      ]),
      commandManifestJSON: try Self.encoded(buildRequest),
      partialOutputPolicy: buildRequest.partialOutputPolicy,
      status: "completed",
      startedAt: buildStartedAt,
      endedAt: now
    )
    let report = ArtifactVerificationReport(
      artifactID: artifactID,
      jobID: request.verificationJobID,
      status: .passed,
      checksJSON: try Self.json(checks),
      runtimeSmokeGenerationID: smokeGenerationID,
      createdAt: now
    )
    try artifactRepository.registerDerivedArtifact(
      artifact,
      manifest: manifest,
      lineage: lineage,
      buildRun: buildRun,
      verificationReport: report
    )
    return artifact
  }

  private func persistPendingJob(
    _ request: OptimizationWorkerRequest,
    type: String
  ) throws {
    let now = Date()
    let snapshot = OptimizationWorkerJobSnapshot(request: request)
    try jobRepository.upsert(.init(
      id: request.jobID,
      type: type,
      projectID: request.projectID,
      artifactID: request.artifactID,
      state: .pending,
      payloadJSON: try Self.encoded(snapshot),
      createdAt: now,
      updatedAt: now
    ))
  }

  private func persistCompletedJob(_ id: JobID) throws {
    guard var record = try jobRepository.record(id: id) else { return }
    let now = Date()
    record.state = .completed
    record.progress = 1
    record.endedAt = now
    record.updatedAt = now
    try jobRepository.upsert(record)
  }

  private func persistTerminalJob(
    _ id: JobID,
    state: DurableJobState,
    error: Error
  ) throws {
    guard var record = try jobRepository.record(id: id), record.state != .completed else { return }
    let now = Date()
    record.state = state
    record.errorJSON = try Self.json(["message": error.localizedDescription])
    record.endedAt = now
    record.updatedAt = now
    try jobRepository.upsert(record)
  }

  private func rejectZeroValidationMetrics(in messages: [String]) throws {
    for message in messages {
      for line in message.split(whereSeparator: \.isNewline) {
        let pieces = line.split(separator: ":", maxSplits: 1)
        guard pieces.count == 2 else { continue }
        let key = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["bits", "blocks", "size"].contains(key) else { continue }
        let numeric = pieces[1].split(separator: " ").first.flatMap {
          Double($0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if numeric == 0 {
          throw OptimizationWorkspaceError.verificationFailed(
            "the validator reported \(key)=0"
          )
        }
      }
    }
  }

  private static func structuralChecks(
    outputURL: URL,
    action: OptimizationWorkspaceAction
  ) throws -> [String: String] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: outputURL.appendingPathComponent("config.json").path) else {
      throw OptimizationWorkspaceError.verificationFailed("config.json is missing")
    }
    guard fm.fileExists(atPath: outputURL.appendingPathComponent("tokenizer.json").path)
      || fm.fileExists(atPath: outputURL.appendingPathComponent("tokenizer_config.json").path)
    else {
      throw OptimizationWorkspaceError.verificationFailed("tokenizer metadata is missing")
    }

    switch action {
    case .analyzeOnly:
      return [:]
    case .pruneOnly:
      let weights = try fm.contentsOfDirectory(
        at: outputURL,
        includingPropertiesForKeys: [.fileSizeKey]
      ).filter { $0.lastPathComponent.hasSuffix(".safetensors") }
      guard !weights.isEmpty else {
        throw OptimizationWorkspaceError.verificationFailed("no safetensors weights were produced")
      }
      return ["structure": "passed", "weight_shards": String(weights.count)]
    case .quantizeOnly:
      let jang = try jsonObject(at: outputURL.appendingPathComponent("jang_config.json"))
      let index = try jsonObject(at: outputURL.appendingPathComponent("model.safetensors.index.json"))
      guard let quantization = jang["quantization"] as? [String: Any],
        let actualBits = number(quantization["actual_bits"]), actualBits > 0,
        let blockSize = number(quantization["block_size"]), blockSize > 0,
        let runtime = jang["runtime"] as? [String: Any],
        let runtimeBytes = number(runtime["total_weight_bytes"]), runtimeBytes > 0,
        let metadata = index["metadata"] as? [String: Any],
        let indexedBytes = number(metadata["total_size"]), indexedBytes > 0,
        let weightMap = index["weight_map"] as? [String: String], !weightMap.isEmpty
      else {
        throw OptimizationWorkspaceError.verificationFailed(
          "JANG metadata contains zero or missing quantization evidence"
        )
      }
      let shards = Set(weightMap.values)
      for shard in shards {
        let url = outputURL.appendingPathComponent(shard)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 else {
          throw OptimizationWorkspaceError.verificationFailed(
            "weight shard \(shard) is missing or empty"
          )
        }
      }
      return [
        "structure": "passed",
        "actual_bits": String(actualBits),
        "block_size": String(Int(blockSize)),
        "runtime_weight_bytes": String(Int64(runtimeBytes)),
        "indexed_weight_bytes": String(Int64(indexedBytes)),
        "indexed_tensors": String(weightMap.count),
        "weight_shards": String(shards.count),
      ]
    }
  }

  private static func jsonObject(at url: URL) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
      as? [String: Any]
    else {
      throw OptimizationWorkspaceError.verificationFailed(
        "\(url.lastPathComponent) is not a JSON object"
      )
    }
    return object
  }

  private static func number(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
  }

  private static func encoded<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  private static func json(_ value: [String: String]) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
  }

  private static func sourceFiles(at root: URL) throws -> [ArtifactSourceFile] {
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles]
    ) else { return [] }
    var files: [ArtifactSourceFile] = []
    for case let url as URL in enumerator {
      let values = try url.resourceValues(forKeys: Set(keys))
      guard values.isRegularFile == true else { continue }
      let relative = String(url.path.dropFirst(root.path.count + 1))
      files.append(.init(
        relativePath: relative,
        sizeBytes: Int64(values.fileSize ?? 0),
        sha256: try sha256(url)
      ))
    }
    return files.sorted { $0.relativePath < $1.relativePath }
  }

  private static func sha256(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
      hasher.update(data: data)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
}
