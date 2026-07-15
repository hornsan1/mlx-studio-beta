import Foundation

public struct ModelProject: Codable, Hashable, Sendable {
    public let id: ModelProjectID
    public var name: String
    public var sourceID: ModelSourceID
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: ModelProjectID = .init(),
        name: String,
        sourceID: ModelSourceID,
        createdAt: Date = .init(),
        updatedAt: Date = .init()
    ) {
        self.id = id
        self.name = name
        self.sourceID = sourceID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ModelSource: Codable, Hashable, Sendable {
    public let id: ModelSourceID
    public var legacyModelID: String?
    public var localURL: URL?
    public var repositoryID: String?
    public var revision: String?
    public var architecture: String?
    public var parameterCount: Int64?
    public var activeParameterCount: Int64?
    public var format: ArtifactFormat
    public var precision: ArtifactPrecision?
    public var capabilities: Set<ArtifactCapability>
    public let createdAt: Date

    public init(
        id: ModelSourceID = .init(),
        legacyModelID: String? = nil,
        localURL: URL? = nil,
        repositoryID: String? = nil,
        revision: String? = nil,
        architecture: String? = nil,
        parameterCount: Int64? = nil,
        activeParameterCount: Int64? = nil,
        format: ArtifactFormat,
        precision: ArtifactPrecision? = nil,
        capabilities: Set<ArtifactCapability> = [],
        createdAt: Date = .init()
    ) {
        self.id = id
        self.legacyModelID = legacyModelID
        self.localURL = localURL
        self.repositoryID = repositoryID
        self.revision = revision
        self.architecture = architecture
        self.parameterCount = parameterCount
        self.activeParameterCount = activeParameterCount
        self.format = format
        self.precision = precision
        self.capabilities = capabilities
        self.createdAt = createdAt
    }
}

public enum ArtifactState: String, Codable, CaseIterable, Hashable, Sendable {
    case discovered
    case importing
    case ready
    case unavailable
    case quarantined
}

public enum VerificationStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case unknown
    case pending
    case passed
    case failed
}

public struct ModelArtifact: Codable, Hashable, Sendable {
    public let id: ModelArtifactID
    public let projectID: ModelProjectID
    public var parentArtifactID: ModelArtifactID?
    public var legacyModelID: String?
    public var name: String
    public var localURL: URL
    public var format: ArtifactFormat
    public var precision: ArtifactPrecision?
    public var state: ArtifactState
    public var manifestID: ArtifactManifestID?
    public var verificationStatus: VerificationStatus
    public var contentHash: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: ModelArtifactID = .init(),
        projectID: ModelProjectID,
        parentArtifactID: ModelArtifactID? = nil,
        legacyModelID: String? = nil,
        name: String,
        localURL: URL,
        format: ArtifactFormat,
        precision: ArtifactPrecision? = nil,
        state: ArtifactState = .discovered,
        manifestID: ArtifactManifestID? = nil,
        verificationStatus: VerificationStatus = .unknown,
        contentHash: String? = nil,
        createdAt: Date = .init(),
        updatedAt: Date = .init()
    ) {
        self.id = id
        self.projectID = projectID
        self.parentArtifactID = parentArtifactID
        self.legacyModelID = legacyModelID
        self.name = name
        self.localURL = localURL
        self.format = format
        self.precision = precision
        self.state = state
        self.manifestID = manifestID
        self.verificationStatus = verificationStatus
        self.contentHash = contentHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ArtifactSourceFile: Codable, Hashable, Sendable {
    public let relativePath: String
    public let sizeBytes: Int64
    public let sha256: String

    public init(relativePath: String, sizeBytes: Int64, sha256: String) {
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.sha256 = sha256
    }
}

public struct ArtifactManifest: Codable, Hashable, Sendable {
    public let id: ArtifactManifestID
    public let artifactID: ModelArtifactID
    public let schemaVersion: Int
    public var sourceRevision: String?
    public var runtimeVersion: String?
    public var optimizerVersion: String?
    public var kernelVersion: String?
    public var optimizationPlanID: OptimizationPlanID?
    public var quantizationRecipeID: QuantizationRecipeID?
    public var calibrationSuiteID: EvaluationSuiteID?
    public var hardwareProfileID: HardwareProfileID?
    public var manifestHash: String
    public var sourceFiles: [ArtifactSourceFile]
    public var metadata: [String: String]
    public let createdAt: Date

    public init(
        id: ArtifactManifestID = .init(),
        artifactID: ModelArtifactID,
        schemaVersion: Int,
        sourceRevision: String? = nil,
        runtimeVersion: String? = nil,
        optimizerVersion: String? = nil,
        kernelVersion: String? = nil,
        optimizationPlanID: OptimizationPlanID? = nil,
        quantizationRecipeID: QuantizationRecipeID? = nil,
        calibrationSuiteID: EvaluationSuiteID? = nil,
        hardwareProfileID: HardwareProfileID? = nil,
        manifestHash: String,
        sourceFiles: [ArtifactSourceFile] = [],
        metadata: [String: String] = [:],
        createdAt: Date = .init()
    ) {
        self.id = id
        self.artifactID = artifactID
        self.schemaVersion = schemaVersion
        self.sourceRevision = sourceRevision
        self.runtimeVersion = runtimeVersion
        self.optimizerVersion = optimizerVersion
        self.kernelVersion = kernelVersion
        self.optimizationPlanID = optimizationPlanID
        self.quantizationRecipeID = quantizationRecipeID
        self.calibrationSuiteID = calibrationSuiteID
        self.hardwareProfileID = hardwareProfileID
        self.manifestHash = manifestHash
        self.sourceFiles = sourceFiles
        self.metadata = metadata
        self.createdAt = createdAt
    }
}

public struct ArtifactLineage: Codable, Hashable, Sendable {
    public let parentArtifactID: ModelArtifactID
    public let childArtifactID: ModelArtifactID
    public let operation: ArtifactOperation
    public let jobID: JobID?
    public let manifestID: ArtifactManifestID?
    public let createdAt: Date

    public init(
        parentArtifactID: ModelArtifactID,
        childArtifactID: ModelArtifactID,
        operation: ArtifactOperation,
        jobID: JobID? = nil,
        manifestID: ArtifactManifestID? = nil,
        createdAt: Date = .init()
    ) {
        self.parentArtifactID = parentArtifactID
        self.childArtifactID = childArtifactID
        self.operation = operation
        self.jobID = jobID
        self.manifestID = manifestID
        self.createdAt = createdAt
    }
}

public struct HardwareProfile: Codable, Hashable, Sendable {
    public let id: HardwareProfileID
    public let chipName: String
    public let unifiedMemoryBytes: Int64
    public let operatingSystemVersion: String
    public let gpuCoreCount: Int?
    public let cpuCoreCount: Int?
    public let availableDiskBytes: Int64?
    public let profileHash: String
    public let capturedAt: Date

    public init(
        id: HardwareProfileID = .init(),
        chipName: String,
        unifiedMemoryBytes: Int64,
        operatingSystemVersion: String,
        gpuCoreCount: Int? = nil,
        cpuCoreCount: Int? = nil,
        availableDiskBytes: Int64? = nil,
        profileHash: String,
        capturedAt: Date = .init()
    ) {
        self.id = id
        self.chipName = chipName
        self.unifiedMemoryBytes = unifiedMemoryBytes
        self.operatingSystemVersion = operatingSystemVersion
        self.gpuCoreCount = gpuCoreCount
        self.cpuCoreCount = cpuCoreCount
        self.availableDiskBytes = availableDiskBytes
        self.profileHash = profileHash
        self.capturedAt = capturedAt
    }
}
