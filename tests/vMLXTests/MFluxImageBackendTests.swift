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

    func testRelocatableLauncherIsRejectedWithoutItsPythonFramework() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mflux-broken-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("Resources/mflux-venv/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let launcher = bin.appendingPathComponent("mflux-generate")
        try Data("#!/bin/sh\nPYTHON_FRAMEWORK=missing\n".utf8).write(to: launcher)
        try Data().write(to: bin.appendingPathComponent("python3.14"))
        for url in [launcher, bin.appendingPathComponent("python3.14")] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        XCTAssertNil(MFluxImageBackend.resolvedExecutable(
            environment: ["MLX_STUDIO_MFLUX_BIN": launcher.path, "PATH": ""]
        ))
    }

    func testRelocatableLauncherIsReadyWithItsPythonFramework() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mflux-ready-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("Contents/Resources/mflux-venv/bin")
        let framework = root.appendingPathComponent(
            "Contents/Frameworks/Python.framework/Versions/3.14/Python"
        )
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: framework.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let launcher = bin.appendingPathComponent("mflux-generate")
        let python = bin.appendingPathComponent("python3.14")
        try Data("#!/bin/sh\nPYTHON_FRAMEWORK=relative\n".utf8).write(to: launcher)
        try Data().write(to: python)
        try Data().write(to: framework)
        for url in [launcher, python, framework] {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        XCTAssertEqual(
            MFluxImageBackend.resolvedExecutable(
                environment: ["MLX_STUDIO_MFLUX_BIN": launcher.path, "PATH": ""]
            )?.path,
            launcher.path
        )
    }
}
