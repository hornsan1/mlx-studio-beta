// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import vMLXEngine

final class MFluxImageBackendTests: XCTestCase {
    func testRuntimeNamesMapToMFluxBaseModels() {
        XCTAssertEqual(MFluxImageBackend.baseModelName(for: "flux1-schnell"), "schnell")
        XCTAssertEqual(MFluxImageBackend.baseModelName(for: "FLUX.1-schnell"), "schnell")
        XCTAssertEqual(MFluxImageBackend.baseModelName(for: "flux1-dev"), "dev")
        XCTAssertEqual(MFluxImageBackend.baseModelName(for: "krea-2-turbo"), "krea-2")
        XCTAssertEqual(MFluxImageBackend.baseModelName(for: "krea2"), "krea-2")
        XCTAssertEqual(MFluxImageBackend.baseModelName(for: "flux-krea-dev"), "krea-dev")
        XCTAssertEqual(MFluxImageBackend.baseModelName(for: "flux2-klein"), "flux2-klein-4b")
        XCTAssertEqual(MFluxImageBackend.baseModelName(for: "z-image-turbo"), "z-image-turbo")
        XCTAssertEqual(MFluxImageBackend.baseModelName(for: "qwen-image"), "qwen")
        XCTAssertNil(MFluxImageBackend.baseModelName(for: "qwen3"))
    }

    func testRuntimeNamesMapToDedicatedMFluxExecutables() {
        XCTAssertEqual(MFluxImageBackend.executableName(for: "flux1-schnell"), "mflux-generate")
        XCTAssertEqual(MFluxImageBackend.executableName(for: "FLUX.1-dev"), "mflux-generate")
        XCTAssertEqual(MFluxImageBackend.executableName(for: "krea-2-turbo"), "mflux-generate-krea2")
        XCTAssertEqual(MFluxImageBackend.executableName(for: "flux2-klein"), "mflux-generate-flux2")
        XCTAssertEqual(MFluxImageBackend.executableName(for: "z-image-turbo"), "mflux-generate-z-image-turbo")
        XCTAssertEqual(MFluxImageBackend.executableName(for: "qwen-image"), "mflux-generate-qwen")
    }

    func testFlux2KleinUsesBackendGuidanceConstraint() {
        XCTAssertEqual(
            MFluxImageBackend.effectiveGuidance(for: "flux2-klein", requested: 3.5),
            1.0
        )
        XCTAssertEqual(
            MFluxImageBackend.effectiveGuidance(for: "flux1-schnell", requested: 3.5),
            3.5
        )
        XCTAssertNil(
            MFluxImageBackend.effectiveGuidance(for: "flux2-klein", requested: -1)
        )
    }

    func testExplicitExecutableEnvironmentWins() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mflux-backend-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bin = dir.appendingPathComponent("custom-mflux")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: bin)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: bin.path
        )

        let resolved = MFluxImageBackend.resolvedExecutable(
            environment: ["MLX_STUDIO_MFLUX_BIN": bin.path, "PATH": ""]
        )

        XCTAssertEqual(resolved?.path, bin.path)
    }
}
