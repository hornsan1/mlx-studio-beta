import Foundation
import XCTest
@testable import vMLXApp

@MainActor
final class StudioJANGWorkerFactoryTests: XCTestCase {
    func testBundledWorkerWinsSystemFallbackAndSetsPythonHome() throws {
        let resources = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-studio-jang-worker-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: resources) }
        let python = resources.appendingPathComponent("jang-python/bin/python3.11")
        try FileManager.default.createDirectory(
            at: python.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: python)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: python.path
        )

        let configuration = StudioJANGWorkerFactory.configuration(
            secretEnvironment: ["HF_HUB_TOKEN": "secret"],
            variables: [:],
            resourceURL: resources
        )

        XCTAssertEqual(configuration.executableURL, python)
        XCTAssertEqual(
            configuration.environment?["PYTHONHOME"],
            resources.appendingPathComponent("jang-python").path
        )
        XCTAssertNil(configuration.environment?["HF_HUB_TOKEN"])
        XCTAssertEqual(configuration.secretEnvironment["HF_HUB_TOKEN"], "secret")
    }

    func testExplicitWorkerAndPythonPathOverrideBundle() {
        let configuration = StudioJANGWorkerFactory.configuration(
            variables: [
                "MLX_STUDIO_JANG_PYTHON": "/opt/jang/python3.11",
                "MLX_STUDIO_JANG_PYTHONPATH": "/opt/jang/site-packages",
            ],
            resourceURL: URL(fileURLWithPath: "/missing")
        )

        XCTAssertEqual(configuration.executableURL.path, "/opt/jang/python3.11")
        XCTAssertEqual(configuration.environment?["PYTHONPATH"], "/opt/jang/site-packages")
        XCTAssertNil(configuration.environment?["PYTHONHOME"])
    }
}
