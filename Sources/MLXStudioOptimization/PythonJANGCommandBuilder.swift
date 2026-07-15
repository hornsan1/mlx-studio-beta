// Adapted from hornsan1/jangq-private@5d5487c27fa81d9f51da27264ae855964e334070
// JANGStudio/JANGStudio/Runner/CLIArgsBuilder.swift.
import Foundation
import MLXStudioDomain

public enum PythonJANGCommandBuilderError: Error, Equatable, Sendable {
    case unsupportedOperation(String)
    case missingOutputURL
    case missingParameter(String)
    case unsupportedParameter(String)
    case invalidParameter(name: String, value: String)
}

public enum PythonJANGCommandBuilder {
    public static func arguments(
        for request: OptimizationWorkerRequest,
        moduleName: String = "jang_tools"
    ) throws -> [String] {
        let base = ["-m", moduleName, "--progress=json", "--quiet-text"]
        switch request.operation {
        case .convert:
            let allowed = Set(["profile", "method", "hadamard", "block-size", "force-dtype"])
            if let unsupported = request.parameters.keys
                .filter({ !allowed.contains($0) })
                .sorted()
                .first {
                throw PythonJANGCommandBuilderError.unsupportedParameter(unsupported)
            }
            guard let outputURL = request.outputURL else {
                throw PythonJANGCommandBuilderError.missingOutputURL
            }
            guard let profile = request.parameters["profile"], !profile.isEmpty else {
                throw PythonJANGCommandBuilderError.missingParameter("profile")
            }
            guard let method = request.parameters["method"], !method.isEmpty else {
                throw PythonJANGCommandBuilderError.missingParameter("method")
            }
            var arguments = base + [
                "convert", request.sourceURL.path,
                "-o", outputURL.path,
                "-p", profile,
                "-m", method,
            ]
            if let hadamard = request.parameters["hadamard"] {
                guard hadamard == "true" || hadamard == "false" else {
                    throw PythonJANGCommandBuilderError.invalidParameter(
                        name: "hadamard",
                        value: hadamard
                    )
                }
                if hadamard == "true" { arguments.append("--hadamard") }
            }
            if let blockSize = request.parameters["block-size"] {
                guard let value = Int(blockSize), value > 0 else {
                    throw PythonJANGCommandBuilderError.invalidParameter(
                        name: "block-size",
                        value: blockSize
                    )
                }
                arguments.append(contentsOf: ["-b", String(value)])
            }
            if let forceDType = request.parameters["force-dtype"] {
                guard ["bf16", "fp16", "fp8"].contains(forceDType) else {
                    throw PythonJANGCommandBuilderError.invalidParameter(
                        name: "force-dtype",
                        value: forceDType
                    )
                }
                arguments.append(contentsOf: ["--force-dtype", forceDType])
            }
            return arguments

        case .pruneQwenMoE:
            let allowed = Set(["keep-map", "require-reviewed-comparison", "force"])
            if let unsupported = request.parameters.keys
                .filter({ !allowed.contains($0) })
                .sorted()
                .first {
                throw PythonJANGCommandBuilderError.unsupportedParameter(unsupported)
            }
            guard let outputURL = request.outputURL else {
                throw PythonJANGCommandBuilderError.missingOutputURL
            }
            guard let keepMap = request.parameters["keep-map"],
                  keepMap.hasPrefix("/") else {
                throw PythonJANGCommandBuilderError.missingParameter("keep-map")
            }
            guard request.parameters["require-reviewed-comparison"] == "true" else {
                throw PythonJANGCommandBuilderError.invalidParameter(
                    name: "require-reviewed-comparison",
                    value: request.parameters["require-reviewed-comparison"] ?? "missing"
                )
            }
            var arguments = base + [
                "prequant-prune-qwen-moe", request.sourceURL.path, outputURL.path,
                "--keep-map", keepMap, "--require-reviewed-comparison", "--json",
            ]
            if let force = request.parameters["force"] {
                guard force == "true" || force == "false" else {
                    throw PythonJANGCommandBuilderError.invalidParameter(
                        name: "force",
                        value: force
                    )
                }
                if force == "true" { arguments.append("--force") }
            }
            return arguments

        case .inspect, .validate, .profile:
            if let unsupported = request.parameters.keys.sorted().first {
                throw PythonJANGCommandBuilderError.unsupportedParameter(unsupported)
            }
            return base + [request.operation.rawValue, request.sourceURL.path]

        default:
            throw PythonJANGCommandBuilderError.unsupportedOperation(
                request.operation.rawValue
            )
        }
    }
}
