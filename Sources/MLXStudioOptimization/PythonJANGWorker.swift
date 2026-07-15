// Consolidates the process boundaries in hornsan1/jangq-private
// @ 5d5487c27fa81d9f51da27264ae855964e334070:
// PythonRunner.swift and PythonCLIInvoker.swift.
import Darwin
import Foundation
import MLXStudioDomain
import MLXStudioEvaluation
import MLXStudioPersistence

public struct PythonJANGWorkerConfiguration: Sendable {
    public var executableURL: URL
    public var moduleName: String
    public var argumentPrefix: [String]
    public var environment: [String: String]?
    public var secretEnvironment: [String: String]
    public var cancellationGracePeriodSeconds: TimeInterval
    public var retainedLogCharacterLimit: Int

    public init(
        executableURL: URL,
        moduleName: String = "jang_tools",
        argumentPrefix: [String] = [],
        environment: [String: String]? = nil,
        secretEnvironment: [String: String] = [:],
        cancellationGracePeriodSeconds: TimeInterval = 3,
        retainedLogCharacterLimit: Int = 65_536
    ) {
        self.executableURL = executableURL
        self.moduleName = moduleName
        self.argumentPrefix = argumentPrefix
        self.environment = environment
        self.secretEnvironment = secretEnvironment
        self.cancellationGracePeriodSeconds = max(0, cancellationGracePeriodSeconds)
        self.retainedLogCharacterLimit = max(0, retainedLogCharacterLimit)
    }
}

public enum PythonJANGWorkerError: Error, Equatable, LocalizedError, Sendable {
    case launch(String)
    case process(exitCode: Int32, message: String)
    case protocolViolation(String)
    case toolReportedFailure(String)

    public var errorDescription: String? {
        switch self {
        case .launch(let message): return "Unable to launch JANG worker: \(message)"
        case .process(let exitCode, let message):
            return "JANG worker exited \(exitCode): \(message)"
        case .protocolViolation(let message): return "JANG worker protocol error: \(message)"
        case .toolReportedFailure(let message): return "JANG worker reported failure: \(message)"
        }
    }
}

public actor PythonJANGWorker: OptimizationWorker {
    public static let supportedOperations: [OptimizationWorkerOperation] = [
        .convert, .pruneQwenMoE, .inspect, .profile, .validate,
    ]

    private typealias Continuation = AsyncThrowingStream<
        OptimizationWorkerEventEnvelope,
        Error
    >.Continuation

    private let configuration: PythonJANGWorkerConfiguration
    private let jobRepository: DurableJobRepository?
    private let redactor: WorkerRedactor
    private var handles: [JobID: WorkerProcessHandle] = [:]
    private var pendingCancellations: Set<JobID> = []
    private var records: [JobID: DurableJobRecord] = [:]
    private var logs: [JobID: BoundedWorkerLog] = [:]

    public init(
        configuration: PythonJANGWorkerConfiguration,
        jobRepository: DurableJobRepository? = nil,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.configuration = configuration
        self.jobRepository = jobRepository
        self.redactor = WorkerRedactor(
            homePath: homeDirectory.path,
            secrets: Array(configuration.secretEnvironment.values)
        )
    }

    public nonisolated func events(
        for request: OptimizationWorkerRequest
    ) -> AsyncThrowingStream<OptimizationWorkerEventEnvelope, Error> {
        let handle = WorkerProcessHandle(
            gracePeriodSeconds: configuration.cancellationGracePeriodSeconds
        )
        return AsyncThrowingStream { continuation in
            continuation.onTermination = { termination in
                if case .cancelled = termination {
                    handle.cancel()
                }
            }
            Task {
                await self.execute(request, handle: handle, continuation: continuation)
            }
        }
    }

    public func cancel(jobID: JobID) async {
        if let handle = handles[jobID] {
            handle.cancel()
        } else {
            pendingCancellations.insert(jobID)
        }
    }

    public func recentLogs(for jobID: JobID) -> String {
        logs[jobID]?.value ?? ""
    }

    public func redactedCommand(for request: OptimizationWorkerRequest) throws -> String {
        let arguments = try PythonJANGCommandBuilder.arguments(
            for: request,
            moduleName: configuration.moduleName
        )
        return redactor.command(
            executable: configuration.executableURL,
            arguments: configuration.argumentPrefix + arguments
        )
    }

    public func diagnostics() async -> OptimizationWorkerDiagnostics {
        var issues: [String] = []
        guard FileManager.default.isExecutableFile(atPath: configuration.executableURL.path) else {
            return OptimizationWorkerDiagnostics(
                executable: redactor.redact(configuration.executableURL.path),
                supportedOperations: Self.supportedOperations,
                issues: ["Configured Python executable is missing or not executable."]
            )
        }

        let python = await Self.capture(
            executable: configuration.executableURL,
            arguments: configuration.argumentPrefix + ["--version"],
            environment: childEnvironment()
        )
        let tool = await Self.capture(
            executable: configuration.executableURL,
            arguments: configuration.argumentPrefix + [
                "-m", configuration.moduleName, "--version",
            ],
            environment: childEnvironment()
        )
        if python.status != 0 { issues.append("Python version probe failed.") }
        if tool.status != 0 { issues.append("jang_tools version probe failed.") }
        return OptimizationWorkerDiagnostics(
            executable: redactor.redact(configuration.executableURL.path),
            pythonVersion: python.status == 0 ? redactor.redact(python.output) : nil,
            toolVersion: tool.status == 0 ? redactor.redact(tool.output) : nil,
            supportedOperations: Self.supportedOperations,
            issues: issues
        )
    }

    private func execute(
        _ request: OptimizationWorkerRequest,
        handle: WorkerProcessHandle,
        continuation: Continuation
    ) async {
        handles[request.jobID] = handle
        if pendingCancellations.remove(request.jobID) != nil {
            handle.cancel()
        }
        logs[request.jobID] = BoundedWorkerLog(
            capacity: configuration.retainedLogCharacterLimit
        )
        await beginJob(request)

        let arguments: [String]
        do {
            arguments = try PythonJANGCommandBuilder.arguments(
                for: request,
                moduleName: configuration.moduleName
            )
        } catch {
            await fail(
                request,
                error: .launch(redactor.redact(String(describing: error))),
                exitCode: nil,
                applyPartialOutputPolicy: false,
                continuation: continuation
            )
            handles[request.jobID] = nil
            return
        }

        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.argumentPrefix + arguments
        process.environment = childEnvironment()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        handle.attach(process)

        let stdoutTask = Task.detached { [redactor] in
            do {
                for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                    let text = redactor.redact(String(line))
                    await self.emit(
                        .message(level: .log, text: text),
                        for: request,
                        continuation: continuation
                    )
                }
            } catch {}
        }
        let stderrTask = Task.detached { [redactor] in
            let parser = JANGJSONLProgressParser()
            var failures: [String] = []
            var toolFailure: String?
            do {
                for try await line in stderrPipe.fileHandleForReading.bytes.lines {
                    switch parser.parse(line: String(line)) {
                    case .event(let event):
                        let sanitized = Self.redacted(event: event, using: redactor)
                        if case .toolReportedCompletion(let ok, _, let error) = sanitized,
                           !ok {
                            toolFailure = error ?? "Tool reported ok=false."
                        }
                        await self.emit(sanitized, for: request, continuation: continuation)
                    case .plainText(let text):
                        guard !text.isEmpty else { continue }
                        await self.emit(
                            .message(level: .log, text: redactor.redact(text)),
                            for: request,
                            continuation: continuation
                        )
                    case .protocolFailure(let message):
                        let clean = redactor.redact(message)
                        failures.append(clean)
                        await self.emit(
                            .message(level: .error, text: clean),
                            for: request,
                            continuation: continuation
                        )
                    }
                }
            } catch {
                failures.append("Unable to read worker progress stream.")
            }
            return (failures, toolFailure)
        }

        do {
            if handle.wasCancelled {
                throw CancellationError()
            }
            try process.run()
            handle.processDidLaunch()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            await Task.detached { process.waitUntilExit() }.value
        } catch is CancellationError {
            handle.cancel()
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
        } catch {
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
            _ = await stdoutTask.result
            _ = await stderrTask.result
            await fail(
                request,
                error: .launch(redactor.redact(error.localizedDescription)),
                exitCode: nil,
                applyPartialOutputPolicy: false,
                continuation: continuation
            )
            handles[request.jobID] = nil
            return
        }

        _ = await stdoutTask.result
        let stderrResult = await stderrTask.value

        if handle.wasCancelled {
            let disposition = handlePartialOutput(for: request)
            await emit(
                .cancelled(
                    escalatedToSIGKILL: handle.didEscalate,
                    partialOutput: disposition
                ),
                for: request,
                continuation: continuation
            )
            continuation.finish()
        } else if let protocolFailure = stderrResult.0.first {
            await fail(
                request,
                error: .protocolViolation(protocolFailure),
                exitCode: process.terminationStatus,
                continuation: continuation
            )
        } else if let toolFailure = stderrResult.1 {
            await fail(
                request,
                error: .toolReportedFailure(toolFailure),
                exitCode: process.terminationStatus,
                continuation: continuation
            )
        } else if process.terminationStatus != 0 {
            let message = logs[request.jobID]?.value.split(separator: "\n").last
                .map(String.init) ?? "No stderr message was emitted."
            await fail(
                request,
                error: .process(exitCode: process.terminationStatus, message: message),
                exitCode: process.terminationStatus,
                continuation: continuation
            )
        } else {
            await emit(
                .completed(outputURL: request.outputURL),
                for: request,
                continuation: continuation
            )
            continuation.finish()
        }
        handles[request.jobID] = nil
    }

    private func beginJob(_ request: OptimizationWorkerRequest) async {
        let now = Date()
        let record = DurableJobRecord(
            id: request.jobID,
            type: "python-jang-\(request.operation.rawValue)",
            projectID: request.projectID,
            artifactID: request.artifactID,
            state: .running,
            progress: 0,
            currentStage: "launching",
            payloadJSON: Self.jsonString(OptimizationWorkerJobSnapshot(request: request)),
            createdAt: now,
            startedAt: now,
            updatedAt: now
        )
        records[request.jobID] = record
        try? jobRepository?.upsert(record)
    }

    private func emit(
        _ event: OptimizationWorkerEvent,
        for request: OptimizationWorkerRequest,
        continuation: Continuation
    ) async {
        let envelope = OptimizationWorkerEventEnvelope(jobID: request.jobID, event: event)
        continuation.yield(envelope)
        if case .message(_, let text) = event {
            logs[request.jobID]?.append(text)
        }
        guard var record = records[request.jobID] else { return }
        switch event {
        case .phase(let index, let total, let name):
            record.currentStage = name
            if total > 0 { record.progress = Double(max(0, index - 1)) / Double(total) }
        case .progress(let completed, let total, let label):
            if total > 0 { record.progress = Double(completed) / Double(total) }
            if let label { record.currentStage = label }
        case .completed:
            record.state = .completed
            record.progress = 1
            record.currentStage = "completed"
            record.endedAt = envelope.timestamp
        case .cancelled:
            record.state = .cancelled
            record.currentStage = "cancelled"
            record.endedAt = envelope.timestamp
        case .failed(let message, _, _):
            record.state = .failed
            record.currentStage = "failed"
            record.errorJSON = Self.jsonString(["message": message])
            record.endedAt = envelope.timestamp
        default:
            break
        }
        record.payloadJSON = Self.jsonString(
            OptimizationWorkerJobSnapshot(request: request, latestEvent: envelope)
        )
        record.updatedAt = envelope.timestamp
        records[request.jobID] = record
        try? jobRepository?.upsert(record)
    }

    private func fail(
        _ request: OptimizationWorkerRequest,
        error: PythonJANGWorkerError,
        exitCode: Int32?,
        applyPartialOutputPolicy: Bool = true,
        continuation: Continuation
    ) async {
        let disposition = applyPartialOutputPolicy
            ? handlePartialOutput(for: request)
            : .notPresent
        let message = redactor.redact(error.localizedDescription)
        await emit(
            .failed(message: message, exitCode: exitCode, partialOutput: disposition),
            for: request,
            continuation: continuation
        )
        continuation.finish(throwing: error)
    }

    private func handlePartialOutput(
        for request: OptimizationWorkerRequest
    ) -> PartialOutputDisposition {
        guard let outputURL = request.outputURL,
              FileManager.default.fileExists(atPath: outputURL.path) else {
            return .notPresent
        }
        switch request.partialOutputPolicy {
        case .keep:
            return .kept(outputURL)
        case .delete:
            do {
                try FileManager.default.removeItem(at: outputURL)
                return .deleted
            } catch {
                return .kept(outputURL)
            }
        case .quarantine:
            let parent = outputURL.deletingLastPathComponent()
            let base = ".\(outputURL.lastPathComponent).partial-\(request.jobID.rawValue)"
            var destination = parent.appendingPathComponent(base)
            var suffix = 1
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = parent.appendingPathComponent("\(base)-\(suffix)")
                suffix += 1
            }
            do {
                try FileManager.default.moveItem(at: outputURL, to: destination)
                return .quarantined(destination)
            } catch {
                return .kept(outputURL)
            }
        }
    }

    private func childEnvironment() -> [String: String] {
        var environment = configuration.environment
            ?? ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONNOUSERSITE"] = "1"
        for (key, value) in configuration.secretEnvironment {
            environment[key] = value
        }
        return environment
    }

    private nonisolated static func redacted(
        event: OptimizationWorkerEvent,
        using redactor: WorkerRedactor
    ) -> OptimizationWorkerEvent {
        switch event {
        case .message(let level, let text):
            return .message(level: level, text: redactor.redact(text))
        case .toolReportedCompletion(let ok, let output, let error):
            return .toolReportedCompletion(
                ok: ok,
                output: output.map(redactor.redact),
                error: error.map(redactor.redact)
            )
        default:
            return event
        }
    }

    private nonisolated static func jsonString<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func capture(
        executable: URL,
        arguments: [String],
        environment: [String: String]
    ) async -> (status: Int32, output: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            let stdoutTask = Task.detached {
                stdout.fileHandleForReading.readDataToEndOfFile()
            }
            let stderrTask = Task.detached {
                stderr.fileHandleForReading.readDataToEndOfFile()
            }
            do {
                try process.run()
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                process.waitUntilExit()
                let data = await stdoutTask.value + stderrTask.value
                return (
                    process.terminationStatus,
                    String(decoding: data, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } catch {
                return (-1, error.localizedDescription)
            }
        }.value
    }
}

private final class WorkerProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private let gracePeriodNanoseconds: UInt64
    private var process: Process?
    private var cancelled = false
    private var escalated = false

    init(gracePeriodSeconds: TimeInterval) {
        gracePeriodNanoseconds = UInt64(max(0, gracePeriodSeconds) * 1_000_000_000)
    }

    var wasCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    var didEscalate: Bool {
        lock.lock(); defer { lock.unlock() }
        return escalated
    }

    func attach(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
    }

    func processDidLaunch() {
        lock.lock()
        let shouldCancel = cancelled
        let process = self.process
        lock.unlock()
        if shouldCancel, let process, process.isRunning { terminate(process) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let process = self.process
        lock.unlock()
        if let process, process.isRunning { terminate(process) }
    }

    private func terminate(_ process: Process) {
        process.terminate()
        let grace = gracePeriodNanoseconds
        Task.detached { [weak self] in
            if grace > 0 { try? await Task.sleep(nanoseconds: grace) }
            guard process.isRunning else { return }
            self?.markEscalated()
            kill(process.processIdentifier, SIGKILL)
        }
    }

    private func markEscalated() {
        lock.lock(); defer { lock.unlock() }
        escalated = true
    }
}
