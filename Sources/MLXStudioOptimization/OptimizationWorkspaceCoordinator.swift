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
    case .recoveryUnavailable:
      return "Only interrupted, cancelled, or failed worker jobs can be recovered."
    case .recoveryPayloadInvalid:
      return "The durable worker job does not contain a recoverable request."
    }
  }
}

public actor OptimizationWorkspaceCoordinator {
  private let worker: any OptimizationWorker
  private let artifactRepository: ModelArtifactRepository
  private let planRepository: OptimizationPlanRepository
  private let jobRepository: DurableJobRepository
  private let validator: OptimizationPlanValidator

  public init(
    worker: any OptimizationWorker,
    artifactRepository: ModelArtifactRepository,
    planRepository: OptimizationPlanRepository,
    jobRepository: DurableJobRepository,
    validator: OptimizationPlanValidator = .init()
  ) {
    self.worker = worker
    self.artifactRepository = artifactRepository
    self.planRepository = planRepository
    self.jobRepository = jobRepository
    self.validator = validator
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
      let buildCompleted = try await forward(
        worker.events(for: buildRequest),
        role: .build,
        continuation: continuation
      )
      guard buildCompleted else {
        throw OptimizationWorkspaceError.incompleteWorkerRun("build")
      }

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
      let verificationCompleted = try await forward(
        worker.events(for: verificationRequest),
        role: .verification,
        continuation: continuation
      )
      guard verificationCompleted else {
        throw OptimizationWorkspaceError.incompleteWorkerRun("verification")
      }
      let artifact = try registerOutputArtifact(
        for: request,
        plan: plan,
        outputURL: outputURL
      )
      continuation.yield(.completed(planID: plan.id, artifact: artifact, verified: true))
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
  }

  private func forward(
    _ events: AsyncThrowingStream<OptimizationWorkerEventEnvelope, Error>,
    role: OptimizationWorkspaceWorkerRole,
    continuation: AsyncThrowingStream<OptimizationWorkspaceEvent, Error>.Continuation
  ) async throws -> Bool {
    var completed = false
    for try await event in events {
      continuation.yield(.worker(role: role, event: event))
      if case .completed = event.event { completed = true }
    }
    return completed
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
    outputURL: URL
  ) throws -> ModelArtifact {
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
      manifestHash: "workspace-v1:\(plan.id.rawValue):\(request.buildJobID.rawValue)",
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
    try artifactRepository.registerDerivedArtifact(
      artifact,
      manifest: manifest,
      lineage: lineage
    )
    return artifact
  }
}
