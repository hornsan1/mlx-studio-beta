import Foundation
import XCTest
@testable import vMLXApp

final class StudioServerCommandFormatterTests: XCTestCase {
    func testEndpointNormalizesConfiguredHostAndPort() {
        XCTAssertEqual(
            StudioServerCommandFormatter.endpoint(host: " http://0.0.0.0/ ", port: 8123),
            "http://0.0.0.0:8123"
        )
        XCTAssertEqual(
            StudioServerCommandFormatter.endpoint(host: "   ", port: 9000),
            "http://127.0.0.1:9000"
        )
    }

    func testStoppedEndpointUsesConfiguredBinding() {
        let config = ServerConfig(host: "127.0.0.1", port: 8123, apiKey: "")
        let health = ServerHealth(
            status: .stopped,
            label: "Stopped",
            endpoint: "http://127.0.0.1:8000"
        )

        XCTAssertEqual(
            StudioServerCommandFormatter.endpoint(config: config, health: health),
            "http://127.0.0.1:8123"
        )
    }

    func testRunningEndpointUsesHealthBinding() {
        let config = ServerConfig(host: "127.0.0.1", port: 8123, apiKey: "")
        let health = ServerHealth(
            status: .running,
            label: "Running",
            endpoint: "http://127.0.0.1:9001"
        )

        XCTAssertEqual(
            StudioServerCommandFormatter.endpoint(config: config, health: health),
            "http://127.0.0.1:9001"
        )
    }

    func testBindingDisplayUsesEffectiveEndpointWithoutScheme() {
        let config = ServerConfig(host: "127.0.0.1", port: 8123, apiKey: "")
        let health = ServerHealth(
            status: .running,
            label: "Running",
            endpoint: "http://0.0.0.0:9001/"
        )

        XCTAssertEqual(
            StudioServerCommandFormatter.binding(config: config, health: health),
            "0.0.0.0:9001"
        )
    }

    func testClientAPIKeyUsesLiveServerAuthWhenActive() {
        let config = ServerConfig(host: "127.0.0.1", port: 8123, apiKey: "draft-token")
        let health = ServerHealth(
            status: .running,
            label: "Running",
            endpoint: "http://127.0.0.1:9001",
            apiKey: " live-token "
        )

        XCTAssertEqual(
            StudioServerCommandFormatter.clientAPIKey(config: config, health: health),
            "live-token"
        )
    }

    func testClientAPIKeyUsesDraftAuthWhenStopped() {
        let config = ServerConfig(host: "127.0.0.1", port: 8123, apiKey: " draft-token ")
        let health = ServerHealth(
            status: .stopped,
            label: "Stopped",
            endpoint: "http://127.0.0.1:9001",
            apiKey: "live-token"
        )

        XCTAssertEqual(
            StudioServerCommandFormatter.clientAPIKey(config: config, health: health),
            "draft-token"
        )
    }

    func testServerModelResolverRejectsExplicitImageModel() throws {
        let imageURL = URL(fileURLWithPath: "/tmp/models/FLUX1-schnell")
        let textURL = URL(fileURLWithPath: "/tmp/models/Qwen3")
        let models = [
            modelSummary(name: "FLUX.1 Schnell", path: imageURL, modality: "image"),
            modelSummary(name: "Qwen3", path: textURL, modality: "text"),
        ]

        XCTAssertThrowsError(
            try StudioServerModelCompatibility.resolveServerModelPath(
                selectedPath: imageURL,
                localModels: models
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("image model"))
        }
    }

    func testServerModelResolverFallsBackOnlyWhenNoExplicitSelection() throws {
        let imageURL = URL(fileURLWithPath: "/tmp/models/FLUX1-schnell")
        let textURL = URL(fileURLWithPath: "/tmp/models/Qwen3")
        let models = [
            modelSummary(name: "FLUX.1 Schnell", path: imageURL, modality: "image"),
            modelSummary(name: "Qwen3", path: textURL, modality: "text"),
        ]

        let resolved = try StudioServerModelCompatibility.resolveServerModelPath(
            selectedPath: nil,
            localModels: models
        )

        XCTAssertEqual(resolved, textURL)
    }

    func testClientProbeCommandIncludesEndpointAuthAndValidJSONBody() throws {
        let command = StudioServerCommandFormatter.clientProbeCommand(
            endpoint: "http://127.0.0.1:8123/",
            model: #"Smoke "Model""#,
            apiKey: "secret-token"
        )

        XCTAssertTrue(command.hasPrefix("curl http://127.0.0.1:8123/v1/chat/completions"))
        XCTAssertTrue(command.contains("-H 'Content-Type: application/json'"))
        XCTAssertTrue(command.contains("-H 'Authorization: Bearer secret-token'"))

        let body = try copiedJSONBody(from: command)
        XCTAssertEqual(body["model"] as? String, #"Smoke "Model""#)
        XCTAssertEqual(body["stream"] as? Bool, false)
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [
            [
                "role": "user",
                "content": "Say ready in one sentence.",
            ],
        ])
    }

    func testHealthProbeCommandUsesEffectiveEndpoint() {
        XCTAssertEqual(
            StudioServerCommandFormatter.healthProbeCommand(endpoint: "http://127.0.0.1:8123/"),
            "curl http://127.0.0.1:8123/health"
        )
    }

    private func copiedJSONBody(from command: String) throws -> [String: Any] {
        let marker = "-d '"
        let range = try XCTUnwrap(command.range(of: marker))
        let start = range.upperBound
        let end = try XCTUnwrap(command[start...].lastIndex(of: "'"))
        let json = String(command[start..<end])
        let data = try XCTUnwrap(json.data(using: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func modelSummary(
        name: String,
        path: URL,
        modality: String
    ) -> ModelSummary {
        ModelSummary(
            id: path.path,
            ref: ModelRef(id: path.path, displayName: name, repo: nil, localURL: path),
            family: modality,
            modality: modality,
            sizeBytes: 1024,
            labels: [],
            isLoaded: false
        )
    }
}
