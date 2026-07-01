import Foundation
import Metal

func runExternalMetalPreflight(device: MTLDevice) -> Bool {
    let functionName = "mlx_studio_external_jit_preflight"
    let source = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void \(functionName)(
        device const float* a [[buffer(0)]],
        device const float* b [[buffer(1)]],
        device float* out [[buffer(2)]],
        uint gid [[thread_position_in_grid]]
    ) {
        out[gid] = a[gid] * b[gid];
    }
    """

    let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("mlx-studio-metal-preflight-\(UUID().uuidString)")
    let sourceURL = temp.appendingPathExtension("metal")
    let libraryURL = temp.appendingPathExtension("metallib")
    do {
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "-sdk", "macosx", "metal",
            sourceURL.path,
            "-o", libraryURL.path,
        ]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus == 0,
           FileManager.default.fileExists(atPath: libraryURL.path) {
            let library = try device.makeLibrary(URL: libraryURL)
            guard let function = library.makeFunction(name: functionName) else {
                fputs("ERROR: external Metal CLI JIT preflight missing \(functionName)\n", stderr)
                return false
            }
            _ = try device.makeComputePipelineState(function: function)
            print("OK: external Metal CLI JIT + pipeline preflight passed")
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: libraryURL)
            return true
        }
    } catch {
        fputs("ERROR: external Metal CLI JIT preflight failed: \(error)\n", stderr)
        return false
    }

    fputs("ERROR: external Metal CLI JIT preflight failed\n", stderr)
    return false
}

guard let device = MTLCreateSystemDefaultDevice() else {
    fputs("ERROR: no default Metal device is available\n", stderr)
    exit(3)
}

let source = """
#include <metal_stdlib>
using namespace metal;

kernel void mlx_studio_jit_preflight(
    device const float* a [[buffer(0)]],
    device const float* b [[buffer(1)]],
    device float* out [[buffer(2)]],
    uint gid [[thread_position_in_grid]]
) {
    out[gid] = a[gid] * b[gid];
}
"""

let options = MTLCompileOptions()
options.fastMathEnabled = false

do {
    _ = try device.makeLibrary(source: source, options: options)
    print("OK: Metal source JIT preflight passed on \(device.name)")
} catch {
    if ProcessInfo.processInfo.environment["VMLINUX_METAL_EXTERNAL_JIT"] == "1"
        || ProcessInfo.processInfo.environment["VMLX_METAL_EXTERNAL_JIT"] == "1" {
        if runExternalMetalPreflight(device: device) {
            exit(0)
        }
    }
    fputs("ERROR: Metal source JIT preflight failed on \(device.name): \(error)\n", stderr)
    exit(4)
}
