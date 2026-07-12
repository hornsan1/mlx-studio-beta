import Foundation

public enum MFluxImageBackend {
    internal struct RuntimeDescriptor: Sendable, Equatable {
        let executableName: String
        let baseModelName: String
        let guidanceOverride: Double?

        init(
            executableName: String,
            baseModelName: String,
            guidanceOverride: Double? = nil
        ) {
            self.executableName = executableName
            self.baseModelName = baseModelName
            self.guidanceOverride = guidanceOverride
        }
    }

    public struct Result: Sendable, Equatable {
        public let outputURL: URL
        public let log: String
    }

    public enum BackendError: Error, LocalizedError, CustomStringConvertible, Sendable {
        case unsupportedRuntime(String)
        case executableNotFound(String)
        case processFailed(status: Int32, log: String)
        case missingOutput(URL, log: String)

        public var errorDescription: String? {
            switch self {
            case .unsupportedRuntime(let runtime):
                return "mflux image backend does not support runtime '\(runtime)'."
            case .executableNotFound(let binary):
                return "\(binary) was not found. Install mflux or set MLX_STUDIO_MFLUX_BIN."
            case .processFailed(let status, let log):
                return "mflux image generation failed with exit code \(status). \(log)"
            case .missingOutput(let url, let log):
                return "mflux completed but did not write \(url.path). \(log)"
            }
        }

        public var description: String {
            errorDescription ?? "mflux image backend failed."
        }
    }

    public static func shouldUse(for runtimeName: String?) -> Bool {
        let preference = ProcessInfo.processInfo.environment["MLX_STUDIO_IMAGE_BACKEND"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if preference == "swift" { return false }
        if preference == "mflux" { return true }
        guard let runtimeName else { return false }
        return descriptor(for: runtimeName) != nil
    }

    internal static func baseModelName(for runtimeName: String) -> String? {
        descriptor(for: runtimeName)?.baseModelName
    }

    internal static func executableName(for runtimeName: String) -> String? {
        descriptor(for: runtimeName)?.executableName
    }

    internal static func descriptor(for runtimeName: String) -> RuntimeDescriptor? {
        let runtime = runtimeName.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        if runtime.contains("flux") && runtime.contains("schnell") {
            return RuntimeDescriptor(executableName: "mflux-generate", baseModelName: "schnell")
        }
        if runtime.contains("krea-2") || runtime.contains("krea2") {
            return RuntimeDescriptor(
                executableName: "mflux-generate-krea2",
                baseModelName: "krea-2",
                guidanceOverride: 1.0
            )
        }
        if runtime.contains("krea") {
            return RuntimeDescriptor(executableName: "mflux-generate", baseModelName: "krea-dev")
        }
        if runtime.contains("flux") && runtime.contains("dev") {
            return RuntimeDescriptor(executableName: "mflux-generate", baseModelName: "dev")
        }
        if runtime.contains("flux") && runtime.contains("klein") {
            return RuntimeDescriptor(
                executableName: "mflux-generate-flux2",
                baseModelName: "flux2-klein-4b",
                guidanceOverride: 1.0
            )
        }
        if runtime.contains("z-image") || runtime.contains("zimage") {
            return RuntimeDescriptor(
                executableName: "mflux-generate-z-image-turbo",
                baseModelName: "z-image-turbo"
            )
        }
        if runtime.contains("qwen") && runtime.contains("image") {
            return RuntimeDescriptor(executableName: "mflux-generate-qwen", baseModelName: "qwen")
        }
        return nil
    }

    internal static func effectiveGuidance(
        for runtimeName: String,
        requested: Double
    ) -> Double? {
        guard requested >= 0 else { return nil }
        return descriptor(for: runtimeName)?.guidanceOverride ?? requested
    }

    internal static func resolvedExecutable(
        for runtimeName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let executableName = executableName(for: runtimeName) else { return nil }
        return resolvedExecutable(
            named: executableName,
            environment: environment,
            fileManager: fileManager
        )
    }

    internal static func resolvedExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        resolvedExecutable(
            named: "mflux-generate",
            environment: environment,
            fileManager: fileManager
        )
    }

    internal static func resolvedExecutable(
        named executableName: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let explicit = [
            environment["MLX_STUDIO_MFLUX_BIN"],
            environment["MFLUX_BIN"],
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        for path in explicit where fileManager.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let pathDirs = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        let home = fileManager.homeDirectoryForCurrentUser
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let bundleResourceDirs = [
            Bundle.main.resourceURL?.appendingPathComponent("mflux-venv/bin").path,
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/mflux-venv/bin").path,
        ].compactMap { $0 }
        let candidates = bundleResourceDirs + pathDirs + [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            support.appendingPathComponent("MLX Studio/mflux-venv/bin").path,
            support.appendingPathComponent("vMLX/mflux-venv/bin").path,
            home.appendingPathComponent(".mlxstudio/mflux-venv/bin").path,
            "/tmp/mlx-studio-mflux-venv/bin",
        ]
        for dir in candidates {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(executableName)
            if fileManager.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    @discardableResult
    public static func generate(
        prompt: String,
        runtimeName: String,
        modelPath: URL,
        settings: ImageGenSettings,
        outputDir: URL
    ) async throws -> Result {
        guard let descriptor = descriptor(for: runtimeName) else {
            throw BackendError.unsupportedRuntime(runtimeName)
        }
        guard let executable = resolvedExecutable(named: descriptor.executableName) else {
            throw BackendError.executableNotFound(descriptor.executableName)
        }

        try FileManager.default.createDirectory(
            at: outputDir,
            withIntermediateDirectories: true
        )
        let outputURL = outputDir.appendingPathComponent(
            "mflux-\(runtimeName)-\(UUID().uuidString.prefix(8)).png"
        )
        let logURL = outputDir.appendingPathComponent(
            "mflux-\(runtimeName)-\(UUID().uuidString.prefix(8)).log"
        )

        var args = [
            "--model", modelPath.path,
            "--base-model", descriptor.baseModelName,
            "--prompt", prompt,
            "--output", outputURL.path,
            "--width", "\(settings.width)",
            "--height", "\(settings.height)",
            "--steps", "\(max(1, settings.steps))",
        ]
        if let guidance = effectiveGuidance(
            for: runtimeName,
            requested: settings.guidance
        ) {
            args += ["--guidance", "\(guidance)"]
        }
        if settings.seed >= 0 {
            args += ["--seed", "\(settings.seed)"]
        }
        let env = ProcessInfo.processInfo.environment
        if env["MLX_STUDIO_MFLUX_LOW_RAM"] == "1" {
            args.append("--low-ram")
        }
        if let cacheLimit = env["MLX_STUDIO_MFLUX_CACHE_LIMIT_GB"],
           !cacheLimit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            args += ["--mlx-cache-limit-gb", cacheLimit]
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = args
        process.currentDirectoryURL = outputDir

        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logURL)
        defer { try? logHandle.close() }
        let header = """
        MLX Studio mflux launch
        runtime: \(runtimeName)
        executable: \(executable.path)
        model: \(modelPath.path)
        output: \(outputURL.path)
        argv: \(args.joined(separator: " "))

        """
        if let data = header.data(using: .utf8) {
            try? logHandle.write(contentsOf: data)
        }
        process.standardOutput = logHandle
        process.standardError = logHandle

        try process.run()
        process.waitUntilExit()
        try? logHandle.synchronize()

        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        guard process.terminationStatus == 0 else {
            throw BackendError.processFailed(
                status: process.terminationStatus,
                log: log
            )
        }
        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw BackendError.missingOutput(outputURL, log: log)
        }
        return Result(outputURL: outputURL, log: log)
    }
}
