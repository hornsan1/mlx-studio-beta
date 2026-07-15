import Foundation

public struct OptimizationWorkerOperation: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

public extension OptimizationWorkerOperation {
    static let convert = Self(rawValue: "convert")
    static let pruneQwenMoE = Self(rawValue: "prune-qwen-moe")
    static let inspect = Self(rawValue: "inspect")
    static let validate = Self(rawValue: "validate")
    static let profile = Self(rawValue: "profile")
}

public enum OptimizationWorkspaceAction: String, Codable, CaseIterable, Hashable, Sendable {
    case analyzeOnly
    case quantizeOnly
    case pruneOnly
}

public struct OptimizationWorkspaceRequest: Codable, Hashable, Sendable {
    public let plan: OptimizationPlan
    public let action: OptimizationWorkspaceAction
    public let topology: ModelExpertTopology?
    public let sourceURL: URL
    public let outputURL: URL?
    public let reviewedKeepMapURL: URL?
    public let outputName: String?
    public let buildJobID: JobID
    public let verificationJobID: JobID

    public init(
        plan: OptimizationPlan,
        action: OptimizationWorkspaceAction,
        topology: ModelExpertTopology? = nil,
        sourceURL: URL,
        outputURL: URL? = nil,
        reviewedKeepMapURL: URL? = nil,
        outputName: String? = nil,
        buildJobID: JobID = .init(),
        verificationJobID: JobID = .init()
    ) {
        self.plan = plan
        self.action = action
        self.topology = topology
        self.sourceURL = sourceURL
        self.outputURL = outputURL
        self.reviewedKeepMapURL = reviewedKeepMapURL
        self.outputName = outputName
        self.buildJobID = buildJobID
        self.verificationJobID = verificationJobID
    }
}

public enum OptimizationWorkspaceWorkerRole: String, Codable, Hashable, Sendable {
    case build
    case verification
}

public enum OptimizationWorkspaceEvent: Codable, Hashable, Sendable {
    case planReady(plan: OptimizationPlan, validation: PlanValidationResult)
    case analysisCompleted(planID: OptimizationPlanID)
    case worker(role: OptimizationWorkspaceWorkerRole, event: OptimizationWorkerEventEnvelope)
    case completed(planID: OptimizationPlanID, artifact: ModelArtifact?, verified: Bool)
}

public struct OptimizationWorkerJobSnapshot: Codable, Hashable, Sendable {
    public let request: OptimizationWorkerRequest
    public let latestEvent: OptimizationWorkerEventEnvelope?

    public init(
        request: OptimizationWorkerRequest,
        latestEvent: OptimizationWorkerEventEnvelope? = nil
    ) {
        self.request = request
        self.latestEvent = latestEvent
    }
}

public enum PartialOutputPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case keep
    case delete
    case quarantine
}

public struct OptimizationWorkerRequest: Codable, Hashable, Sendable {
    public let jobID: JobID
    public let projectID: ModelProjectID?
    public let artifactID: ModelArtifactID?
    public let operation: OptimizationWorkerOperation
    public let sourceURL: URL
    public let outputURL: URL?
    public var parameters: [String: String]
    public var partialOutputPolicy: PartialOutputPolicy

    public init(
        jobID: JobID = .init(),
        projectID: ModelProjectID? = nil,
        artifactID: ModelArtifactID? = nil,
        operation: OptimizationWorkerOperation,
        sourceURL: URL,
        outputURL: URL? = nil,
        parameters: [String: String] = [:],
        partialOutputPolicy: PartialOutputPolicy = .quarantine
    ) {
        self.jobID = jobID
        self.projectID = projectID
        self.artifactID = artifactID
        self.operation = operation
        self.sourceURL = sourceURL
        self.outputURL = outputURL
        self.parameters = parameters
        self.partialOutputPolicy = partialOutputPolicy
    }
}

public enum WorkerMessageLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case info
    case warning
    case error
    case log
}

public enum PartialOutputDisposition: Codable, Hashable, Sendable {
    case notPresent
    case kept(URL)
    case deleted
    case quarantined(URL)
}

public enum OptimizationWorkerEvent: Codable, Hashable, Sendable {
    case phase(index: Int, total: Int, name: String)
    case progress(completed: Int, total: Int, label: String?)
    case message(level: WorkerMessageLevel, text: String)
    case toolReportedCompletion(ok: Bool, output: String?, error: String?)
    case completed(outputURL: URL?)
    case cancelled(escalatedToSIGKILL: Bool, partialOutput: PartialOutputDisposition)
    case failed(message: String, exitCode: Int32?, partialOutput: PartialOutputDisposition)
}

public struct OptimizationWorkerEventEnvelope: Codable, Hashable, Sendable {
    public static let currentProtocolVersion = 1

    public let protocolVersion: Int
    public let jobID: JobID
    public let timestamp: Date
    public let event: OptimizationWorkerEvent

    public init(
        protocolVersion: Int = Self.currentProtocolVersion,
        jobID: JobID,
        timestamp: Date = .init(),
        event: OptimizationWorkerEvent
    ) {
        self.protocolVersion = protocolVersion
        self.jobID = jobID
        self.timestamp = timestamp
        self.event = event
    }
}

public struct OptimizationWorkerDiagnostics: Codable, Hashable, Sendable {
    public let protocolVersion: Int
    public let executable: String
    public let pythonVersion: String?
    public let toolVersion: String?
    public let supportedOperations: [OptimizationWorkerOperation]
    public let issues: [String]

    public init(
        protocolVersion: Int = OptimizationWorkerEventEnvelope.currentProtocolVersion,
        executable: String,
        pythonVersion: String? = nil,
        toolVersion: String? = nil,
        supportedOperations: [OptimizationWorkerOperation],
        issues: [String] = []
    ) {
        self.protocolVersion = protocolVersion
        self.executable = executable
        self.pythonVersion = pythonVersion
        self.toolVersion = toolVersion
        self.supportedOperations = supportedOperations
        self.issues = issues
    }
}

public protocol OptimizationWorker: Sendable {
    func events(
        for request: OptimizationWorkerRequest
    ) -> AsyncThrowingStream<OptimizationWorkerEventEnvelope, Error>

    func cancel(jobID: JobID) async
    func diagnostics() async -> OptimizationWorkerDiagnostics
}
