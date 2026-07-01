import Foundation
import Metal

guard CommandLine.arguments.count == 3 else {
    fputs("usage: metal-pipeline-preflight.swift <metallib> <function>\n", stderr)
    exit(2)
}

guard let device = MTLCreateSystemDefaultDevice() else {
    fputs("ERROR: no default Metal device is available\n", stderr)
    exit(3)
}

do {
    let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let function = library.makeFunction(name: CommandLine.arguments[2]) else {
        fputs("ERROR: function not found: \(CommandLine.arguments[2])\n", stderr)
        exit(4)
    }
    _ = try device.makeComputePipelineState(function: function)
    print("OK: Metal pipeline preflight passed for \(CommandLine.arguments[2]) on \(device.name)")
} catch {
    fputs("ERROR: Metal pipeline preflight failed on \(device.name): \(error)\n", stderr)
    exit(5)
}
