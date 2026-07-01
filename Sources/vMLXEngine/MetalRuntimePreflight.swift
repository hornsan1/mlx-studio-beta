import Foundation

#if canImport(Metal)
import Metal
#endif

public enum MetalRuntimePreflight {
    public struct Report: Sendable, Equatable {
        public let isAvailable: Bool
        public let deviceName: String?
        public let message: String

        public var userFacingMessage: String {
            if isAvailable { return message }
            if message.contains("MTLCompilerService") {
                return "macOS cannot reach MTLCompilerService from this launch context, so local Metal image generation is blocked before model load. Relaunch MLX Studio from a normal user session and try again."
            }
            return message
        }

        public static func available(deviceName: String?, message: String) -> Report {
            Report(isAvailable: true, deviceName: deviceName, message: message)
        }

        public static func unavailable(deviceName: String?, message: String) -> Report {
            Report(isAvailable: false, deviceName: deviceName, message: message)
        }
    }

    public static let skipEnvironmentKey = "VMLX_IMAGE_SKIP_METAL_PREFLIGHT"
    public static let externalJITEnvironmentKey = "VMLX_METAL_EXTERNAL_JIT"
    public static let legacyExternalJITEnvironmentKey = "VMLINUX_METAL_EXTERNAL_JIT"

    public static func check(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Report {
        if isTruthy(environment[skipEnvironmentKey]) {
            return .available(
                deviceName: nil,
                message: "Metal image preflight skipped by \(skipEnvironmentKey)."
            )
        }

        #if canImport(Metal)
        guard let device = MTLCreateSystemDefaultDevice() else {
            return .unavailable(
                deviceName: nil,
                message: "No default Metal device is available on this Mac."
            )
        }

        let source = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void vmlx_image_preflight(
            constant float *input [[buffer(0)]],
            device float *output [[buffer(1)]],
            uint id [[thread_position_in_grid]]
        ) {
            output[id] = input[id] + 1.0f;
        }
        """

        do {
            let library = try device.makeLibrary(source: source, options: nil)
            guard let function = library.makeFunction(name: "vmlx_image_preflight") else {
                return .unavailable(
                    deviceName: device.name,
                    message: "Metal preflight compiled, but the test kernel was missing."
                )
            }
            _ = try device.makeComputePipelineState(function: function)
            return .available(
                deviceName: device.name,
                message: "Metal image preflight passed on \(device.name)."
            )
        } catch {
            if isTruthy(environment[externalJITEnvironmentKey])
                || isTruthy(environment[legacyExternalJITEnvironmentKey]) {
                return checkExternalJIT(device: device, sourceError: error)
            }
            return .unavailable(
                deviceName: device.name,
                message: "Metal image preflight failed on \(device.name): \(error)"
            )
        }
        #else
        return .unavailable(
            deviceName: nil,
            message: "Metal is not available in this build."
        )
        #endif
    }

    public static func validateForImageGeneration(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let report = check(environment: environment)
        guard report.isAvailable else {
            throw EngineError.metalRuntimeUnavailable(
                "preflight failed before generation. \(report.userFacingMessage)"
            )
        }
    }

    private static func isTruthy(_ value: String?) -> Bool {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        else { return false }
        return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
    }

    #if canImport(Metal)
    private static func checkExternalJIT(
        device: MTLDevice,
        sourceError: Error
    ) -> Report {
        let functionName = "vmlx_image_external_preflight"
        let source = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void \(functionName)(
            constant float *input [[buffer(0)]],
            device float *output [[buffer(1)]],
            uint id [[thread_position_in_grid]]
        ) {
            output[id] = input[id] + 1.0f;
        }
        """
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmlx-image-metal-preflight-\(UUID().uuidString)")
        let sourceURL = temp.appendingPathExtension("metal")
        let libraryURL = temp.appendingPathExtension("metallib")
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: libraryURL)
        }

        do {
            try source.write(to: sourceURL, atomically: true, encoding: .utf8)
            let process = Process()
            let stderr = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            process.arguments = [
                "-sdk", "macosx", "metal",
                sourceURL.path,
                "-o", libraryURL.path,
            ]
            process.standardError = stderr
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                return .unavailable(
                    deviceName: device.name,
                    message: "External Metal CLI compile failed on \(device.name): \(output). Source JIT error: \(sourceError)"
                )
            }

            let library = try device.makeLibrary(URL: libraryURL)
            guard let function = library.makeFunction(name: functionName) else {
                return .unavailable(
                    deviceName: device.name,
                    message: "External Metal CLI compile succeeded, but the preflight kernel was missing. Source JIT error: \(sourceError)"
                )
            }
            _ = try device.makeComputePipelineState(function: function)
            return .available(
                deviceName: device.name,
                message: "External Metal CLI JIT + pipeline preflight passed on \(device.name)."
            )
        } catch {
            return .unavailable(
                deviceName: device.name,
                message: "External Metal pipeline preflight failed on \(device.name): \(error). Source JIT error: \(sourceError)"
            )
        }
    }
    #endif
}
