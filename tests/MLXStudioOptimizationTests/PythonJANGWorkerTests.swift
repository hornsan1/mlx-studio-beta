import Foundation
import XCTest
import MLXStudioDomain
import MLXStudioPersistence
@testable import MLXStudioOptimization

final class PythonJANGWorkerTests: XCTestCase {
    func testDomainWorkerContractsRoundTrip() throws {
        let jobID = JobID()
        let envelope = OptimizationWorkerEventEnvelope(
            jobID: jobID,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            event: .cancelled(
                escalatedToSIGKILL: true,
                partialOutput: .quarantined(URL(fileURLWithPath: "/tmp/partial"))
            )
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(try decoder.decode(OptimizationWorkerEventEnvelope.self, from: data), envelope)
        XCTAssertEqual(envelope.protocolVersion, 1)
        assertSendable(envelope)
    }

    func testGoldenJSONLParsesVersionedProgressEvents() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "golden-worker-events", withExtension: "jsonl")
        )
        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let parser = JANGJSONLProgressParser()
        let parsed = lines.map(parser.parse)

        XCTAssertEqual(parsed, [
            .event(.phase(index: 1, total: 5, name: "detect")),
            .event(.progress(completed: 2, total: 10, label: "weights")),
            .event(.message(level: .info, text: "conversion active")),
            .event(.message(level: .warning, text: "using fallback")),
            .event(.toolReportedCompletion(ok: true, output: "/tmp/output", error: nil)),
        ])
        XCTAssertEqual(
            parser.parse(line: #"{"v":99,"type":"phase","n":1,"total":1,"name":"bad"}"#),
            .protocolFailure("Unsupported JSONL protocol version 99; expected 1.")
        )
        XCTAssertEqual(
            parser.parse(line: #"{"v":1,"type":"tick","#),
            .protocolFailure("Malformed JSONL progress event.")
        )
    }

    func testCommandIsDeterministicStructuredAndRedacted() async throws {
        let secret = "test-secret-command"
        let worker = PythonJANGWorker(
            configuration: PythonJANGWorkerConfiguration(
                executableURL: URL(fileURLWithPath: "/Users/hermes/venv/bin/python"),
                secretEnvironment: ["HF_HUB_TOKEN": secret]
            ),
            homeDirectory: URL(fileURLWithPath: "/Users/hermes")
        )
        let request = OptimizationWorkerRequest(
            operation: .convert,
            sourceURL: URL(fileURLWithPath: "/Users/hermes/models/source"),
            outputURL: URL(fileURLWithPath: "/Users/hermes/models/output"),
            parameters: [
                "method": "symmetric",
                "force-dtype": "bf16",
                "profile": "JANG_3L",
                "block-size": "64",
                "hadamard": "true",
            ]
        )

        let arguments = try PythonJANGCommandBuilder.arguments(for: request)
        XCTAssertEqual(arguments, [
            "-m", "jang_tools", "--progress=json", "--quiet-text",
            "convert", "/Users/hermes/models/source",
            "-o", "/Users/hermes/models/output",
            "-p", "JANG_3L", "-m", "symmetric",
            "--hadamard", "-b", "64", "--force-dtype", "bf16",
        ])
        let first = try await worker.redactedCommand(for: request)
        let second = try await worker.redactedCommand(for: request)
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.contains("/Users/hermes"))
        XCTAssertFalse(first.contains(secret))
        XCTAssertTrue(first.contains("<HOME>"))
        XCTAssertThrowsError(try PythonJANGCommandBuilder.arguments(for: OptimizationWorkerRequest(
            operation: .inspect,
            sourceURL: URL(fileURLWithPath: "/tmp/model"),
            parameters: ["unknown": "ignored"]
        ))) { error in
            XCTAssertEqual(error as? PythonJANGCommandBuilderError, .unsupportedParameter("unknown"))
        }
    }

    func testVersionDiagnosticsAreStructuredAndDoNotExposeSecrets() async throws {
        let secret = "test-secret-diagnostics"
        let script = try makeScript("""
        if [[ "$*" == *"-m jang_tools --version"* ]]; then
          echo "jang-tools 2.5.31 token=\(secret)"
        else
          echo "Python 3.11.15"
        fi
        """)
        let worker = PythonJANGWorker(
            configuration: PythonJANGWorkerConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                argumentPrefix: [script.path],
                secretEnvironment: ["HF_HUB_TOKEN": secret]
            )
        )

        let diagnostics = await worker.diagnostics()

        XCTAssertEqual(diagnostics.protocolVersion, 1)
        XCTAssertEqual(diagnostics.pythonVersion, "Python 3.11.15")
        XCTAssertEqual(diagnostics.toolVersion, "jang-tools 2.5.31 token=<REDACTED>")
        XCTAssertEqual(
            diagnostics.supportedOperations,
            [
                .convert, .pruneQwenMoE, .inspect, .profile, .validate,
                .generateModelCard, .publishHuggingFace,
            ]
        )
        XCTAssertTrue(diagnostics.issues.isEmpty)
        XCTAssertFalse(try JSONEncoder().encode(diagnostics).contains(Data(secret.utf8)))
    }

    func testRealPinnedJANGEnvironmentDiagnosticsWhenConfigured() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let python = environment["MLX_STUDIO_JANG_PYTHON"],
              let pythonPath = environment["MLX_STUDIO_JANG_PYTHONPATH"] else {
            throw XCTSkip("Set MLX_STUDIO_JANG_PYTHON and MLX_STUDIO_JANG_PYTHONPATH for the real worker diagnostic gate.")
        }
        var childEnvironment = environment
        childEnvironment["PYTHONPATH"] = pythonPath
        let worker = PythonJANGWorker(
            configuration: PythonJANGWorkerConfiguration(
                executableURL: URL(fileURLWithPath: python),
                environment: childEnvironment
            )
        )

        let diagnostics = await worker.diagnostics()

        XCTAssertTrue(diagnostics.issues.isEmpty)
        XCTAssertTrue(diagnostics.pythonVersion?.hasPrefix("Python 3.11.") == true)
        XCTAssertEqual(diagnostics.toolVersion, "jang-tools 2.5.31")
    }

    func testSuccessfulRunStreamsGoldenEventsAndPersistsDurableJob() async throws {
        let script = try makeScript("""
        echo '{"v":1,"type":"phase","n":1,"total":2,"name":"convert"}' >&2
        echo '{"v":1,"type":"tick","done":2,"total":2,"label":"write"}' >&2
        echo '{"v":1,"type":"done","ok":true,"output":"/tmp/out"}' >&2
        """)
        let databaseURL = temporaryURL("worker-success.sqlite3")
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let repository = try DurableJobRepository(databaseURL: databaseURL)
        let worker = testWorker(script: script, repository: repository)
        let request = OptimizationWorkerRequest(
            operation: .inspect,
            sourceURL: URL(fileURLWithPath: "/tmp/model")
        )

        let events = try await collect(worker.events(for: request))

        XCTAssertTrue(events.contains { envelope in
            if case .phase(index: 1, total: 2, name: "convert") = envelope.event { return true }
            return false
        })
        XCTAssertTrue(events.contains { if case .completed = $0.event { return true }; return false })
        let saved = try XCTUnwrap(repository.records().first)
        XCTAssertEqual(saved.id, request.jobID)
        XCTAssertEqual(saved.state, .completed)
        XCTAssertEqual(saved.progress, 1)
        XCTAssertEqual(saved.currentStage, "completed")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(
            OptimizationWorkerJobSnapshot.self,
            from: Data(saved.payloadJSON.utf8)
        )
        XCTAssertEqual(snapshot.request, request)
        XCTAssertNotNil(snapshot.latestEvent)
    }

    func testWorkerForcesPythonBytecodeOutsideSignedResources() async throws {
        let script = try makeScript("""
        [[ "$PYTHONDONTWRITEBYTECODE" == "1" ]] || {
          echo "bytecode writes were not disabled" >&2
          exit 31
        }
        [[ "$PYTHONPYCACHEPREFIX" == *"/MLX Studio/PythonBytecode" ]] || {
          echo "bytecode cache was not redirected: $PYTHONPYCACHEPREFIX" >&2
          exit 32
        }
        echo '{"v":1,"type":"done","ok":true,"output":"/tmp/out"}' >&2
        """)
        let worker = PythonJANGWorker(configuration: .init(
            executableURL: URL(fileURLWithPath: "/bin/bash"),
            argumentPrefix: [script.path],
            environment: [
                "PYTHONDONTWRITEBYTECODE": "0",
                "PYTHONPYCACHEPREFIX": "/Applications/MLX Studio.app/Contents/Resources",
            ]
        ))
        let request = OptimizationWorkerRequest(
            operation: .inspect,
            sourceURL: URL(fileURLWithPath: "/tmp/model")
        )

        let events = try await collect(worker.events(for: request))

        XCTAssertTrue(events.contains {
            if case .completed = $0.event { return true }
            return false
        })
    }

    func testPublishingCommandsAreStructuredAndNeverPutTokenOnArgv() throws {
        let preview = OptimizationWorkerRequest(
            operation: .publishHuggingFace,
            sourceURL: URL(fileURLWithPath: "/tmp/model"),
            parameters: [
                "repo": "org/model-JANG_4K",
                "private": "true",
                "dry-run": "true",
            ]
        )
        XCTAssertEqual(try PythonJANGCommandBuilder.arguments(for: preview), [
            "-m", "jang_tools", "--progress=json", "--quiet-text",
            "publish", "--model", "/tmp/model",
            "--repo", "org/model-JANG_4K", "--json", "--progress=json",
            "--private", "--dry-run",
        ])
        XCTAssertFalse(try PythonJANGCommandBuilder.arguments(for: preview).contains { $0.hasPrefix("hf_") })

        let modelCard = OptimizationWorkerRequest(
            operation: .generateModelCard,
            sourceURL: URL(fileURLWithPath: "/tmp/model")
        )
        XCTAssertEqual(try PythonJANGCommandBuilder.arguments(for: modelCard), [
            "-m", "jang_tools", "--progress=json", "--quiet-text",
            "modelcard", "--model", "/tmp/model", "--json",
        ])
    }

    func testPublishingStdoutBecomesStructuredOutputAndDurableJob() async throws {
        let script = try makeScript(#"echo '{"dry_run":true,"repo":"org/model","private":false,"files_count":3,"total_size_bytes":42}'"#)
        let databaseURL = temporaryURL("worker-publish.sqlite3")
        defer { try? FileManager.default.removeItem(at: databaseURL.deletingLastPathComponent()) }
        let repository = try DurableJobRepository(databaseURL: databaseURL)
        let worker = testWorker(script: script, repository: repository)
        let request = OptimizationWorkerRequest(
            operation: .publishHuggingFace,
            sourceURL: URL(fileURLWithPath: "/tmp/model"),
            parameters: ["repo": "org/model", "dry-run": "true"]
        )

        let events = try await collect(worker.events(for: request))

        XCTAssertTrue(events.contains {
            if case .structuredOutput(let json) = $0.event {
                return json.contains(#""files_count":3"#)
            }
            return false
        })
        let saved = try XCTUnwrap(repository.records().first)
        XCTAssertEqual(saved.type, "python-jang-publish-huggingface")
        XCTAssertEqual(saved.state, .completed)
    }

    func testFailureQuarantinesPartialOutputAndPersistsFailure() async throws {
        let root = temporaryURL("worker-partial")
        let output = root.appendingPathComponent("output", isDirectory: true)
        let script = try makeScript("""
        mkdir -p '\(output.path)'
        echo partial > '\(output.appendingPathComponent("weights.bin").path)'
        echo '{"v":1,"type":"done","ok":false,"error":"conversion failed"}' >&2
        exit 2
        """)
        let repository = try DurableJobRepository(
            databaseURL: root.appendingPathComponent("models.sqlite3")
        )
        let worker = testWorker(script: script, repository: repository)
        let request = OptimizationWorkerRequest(
            operation: .convert,
            sourceURL: root.appendingPathComponent("source"),
            outputURL: output,
            parameters: ["profile": "JANG_3L", "method": "symmetric"],
            partialOutputPolicy: .quarantine
        )
        var terminal: OptimizationWorkerEvent?

        do {
            for try await envelope in worker.events(for: request) {
                if case .failed = envelope.event { terminal = envelope.event }
            }
            XCTFail("Expected worker failure")
        } catch let error as PythonJANGWorkerError {
            XCTAssertEqual(error, .toolReportedFailure("conversion failed"))
        }

        guard case .failed(_, let exitCode, let disposition) = terminal else {
            return XCTFail("Missing failed terminal event")
        }
        XCTAssertEqual(exitCode, 2)
        guard case .quarantined(let quarantineURL) = disposition else {
            return XCTFail("Partial output was not quarantined")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: quarantineURL.appendingPathComponent("weights.bin").path
        ))
        XCTAssertEqual(try repository.records().first?.state, .failed)
    }

    func testCancellationEscalatesAndPersistsCancelledState() async throws {
        let root = temporaryURL("worker-cancel")
        let script = try makeScript("""
        trap '' TERM
        echo '{"v":1,"type":"phase","n":1,"total":1,"name":"waiting"}' >&2
        while true; do sleep 0.05; done
        """)
        let repository = try DurableJobRepository(
            databaseURL: root.appendingPathComponent("models.sqlite3")
        )
        let worker = testWorker(
            script: script,
            repository: repository,
            gracePeriod: 0.15
        )
        let request = OptimizationWorkerRequest(
            operation: .validate,
            sourceURL: root.appendingPathComponent("source")
        )
        let task = Task { try await collect(worker.events(for: request)) }
        try await Task.sleep(nanoseconds: 200_000_000)

        await worker.cancel(jobID: request.jobID)
        let events = try await task.value

        XCTAssertTrue(events.contains { envelope in
            if case .cancelled(let escalated, .notPresent) = envelope.event {
                return escalated
            }
            return false
        })
        XCTAssertEqual(try repository.records().first?.state, .cancelled)
    }

    func testImmediateCancellationPreventsProcessLaunch() async throws {
        let marker = temporaryURL("launched.txt")
        let script = try makeScript("echo launched > '\(marker.path)'")
        let root = marker.deletingLastPathComponent()
        let repository = try DurableJobRepository(
            databaseURL: root.appendingPathComponent("models.sqlite3")
        )
        let worker = testWorker(script: script, repository: repository)
        let request = OptimizationWorkerRequest(
            operation: .inspect,
            sourceURL: root.appendingPathComponent("source")
        )
        let stream = worker.events(for: request)

        await worker.cancel(jobID: request.jobID)
        let events = try await collect(stream)

        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(events.contains { if case .cancelled = $0.event { return true }; return false })
        XCTAssertEqual(try repository.records().first?.state, .cancelled)
    }

    func testPrelaunchValidationFailureDoesNotTouchExistingOutput() async throws {
        let root = temporaryURL("worker-prelaunch")
        let output = root.appendingPathComponent("existing", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let sentinel = output.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: sentinel)
        let script = try makeScript("exit 99")
        let repository = try DurableJobRepository(
            databaseURL: root.appendingPathComponent("models.sqlite3")
        )
        let worker = testWorker(script: script, repository: repository)
        let request = OptimizationWorkerRequest(
            operation: .convert,
            sourceURL: root.appendingPathComponent("source"),
            outputURL: output,
            parameters: [:],
            partialOutputPolicy: .delete
        )
        var terminal: OptimizationWorkerEvent?

        do {
            for try await envelope in worker.events(for: request) {
                terminal = envelope.event
            }
            XCTFail("Expected validation failure")
        } catch {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        guard case .failed(_, nil, .notPresent) = terminal else {
            return XCTFail("Prelaunch failure must not apply partial-output policy")
        }
    }

    func testRetainedLogsAreBoundedAndRedacted() async throws {
        let secret = "test-secret-log"
        let script = try makeScript("""
        echo 'Bearer \(secret) /Users/hermes/private/path 123456789012345678901234567890' >&2
        """)
        let worker = PythonJANGWorker(
            configuration: PythonJANGWorkerConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                argumentPrefix: [script.path],
                secretEnvironment: ["HF_HUB_TOKEN": secret],
                retainedLogCharacterLimit: 48
            ),
            homeDirectory: URL(fileURLWithPath: "/Users/hermes")
        )
        let request = OptimizationWorkerRequest(
            operation: .inspect,
            sourceURL: URL(fileURLWithPath: "/tmp/model")
        )
        _ = try await collect(worker.events(for: request))

        let logs = await worker.recentLogs(for: request.jobID)
        XCTAssertLessThanOrEqual(logs.count, 48)
        XCTAssertFalse(logs.contains(secret))
        XCTAssertFalse(logs.contains("/Users/hermes"))
    }

    private func testWorker(
        script: URL,
        repository: DurableJobRepository,
        gracePeriod: TimeInterval = 1
    ) -> PythonJANGWorker {
        PythonJANGWorker(
            configuration: PythonJANGWorkerConfiguration(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                argumentPrefix: [script.path],
                cancellationGracePeriodSeconds: gracePeriod
            ),
            jobRepository: repository
        )
    }

    private func collect(
        _ stream: AsyncThrowingStream<OptimizationWorkerEventEnvelope, Error>
    ) async throws -> [OptimizationWorkerEventEnvelope] {
        var events: [OptimizationWorkerEventEnvelope] = []
        for try await event in stream { events.append(event) }
        return events
    }

    private func makeScript(_ body: String) throws -> URL {
        let url = temporaryURL("script.sh")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "#!/bin/bash\nset -eu\n\(body)\n".write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return url
    }

    private func temporaryURL(_ leaf: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-studio-worker-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(leaf)
    }

    private func assertSendable<T: Sendable>(_ value: T) {
        _ = value
    }
}
