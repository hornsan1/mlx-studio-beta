// SPDX-License-Identifier: Apache-2.0
//
// Regression guard for MLX Studio's Hugging Face selector. Hub search rows can
// include sibling filenames without byte sizes; the app relies on the per-model
// detail hydration pass to fill weights/storage before rendering cards.

import Foundation
import XCTest
@testable import vMLXEngine

final class HuggingFaceSearchHydrationTests: XCTestCase {
    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HuggingFaceSearchHydrationURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() async throws {
        HuggingFaceSearchHydrationURLProtocol.handler = nil
        session.invalidateAndCancel()
        session = nil
        try await super.tearDown()
    }

    func testRuntimeCompatibleSearchHydratesMissingSearchSizes() async throws {
        HuggingFaceSearchHydrationURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let queryItems = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
            )

            if components.path == "/api/models" {
                let body = queryItems["filter"] == "mlx" ? Self.searchRowsWithoutSizes : "[]"
                return Self.response(for: url, body: body)
            }

            if components.path == "/api/models/mlx-community/Qwen3-0.6B-8bit" {
                return Self.response(for: url, body: Self.detailRowWithSizes)
            }

            XCTFail("Unexpected Hugging Face request: \(url.absoluteString)")
            return Self.response(for: url, statusCode: 404, body: "{}")
        }

        let rows = try await HuggingFaceSearch(session: session)
            .searchRuntimeCompatible(query: "qwen", limit: 5)

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.modelId, "mlx-community/Qwen3-0.6B-8bit")
        XCTAssertEqual(row.runtimeCompatibility.format, .mlx)
        XCTAssertEqual(row.runtimeCompatibility.modelType, "qwen3")
        XCTAssertEqual(row.weightBytes, 633_442_994)
        XCTAssertEqual(row.usedStorageBytes, 644_865_648)
        XCTAssertEqual(row.libraryName, "mlx")
        XCTAssertEqual(row.lastModified.map(Self.iso8601.string(from:)), "2025-05-04T11:58:56Z")
    }

    func testRuntimeCompatibleSearchIncludesNativeTransformersTextModels() async throws {
        HuggingFaceSearchHydrationURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let queryItems = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
            )

            if components.path == "/api/models" {
                let query = queryItems["search"] ?? ""
                let body = queryItems["filter"] == nil && query == "LFM2.5-350M"
                    ? Self.lfm25SearchRowsWithoutSizes
                    : "[]"
                return Self.response(for: url, body: body)
            }

            if components.path == "/api/models/LiquidAI/LFM2.5-350M" {
                return Self.response(for: url, body: Self.lfm25DetailRowWithSizes)
            }

            XCTFail("Unexpected Hugging Face request: \(url.absoluteString)")
            return Self.response(for: url, statusCode: 404, body: "{}")
        }

        let rows = try await HuggingFaceSearch(session: session)
            .searchRuntimeCompatible(query: "LFM2.5-350M", limit: 5)

        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(row.modelId, "LiquidAI/LFM2.5-350M")
        XCTAssertEqual(row.runtimeCompatibility.format, .transformers)
        XCTAssertEqual(row.runtimeCompatibility.modelType, "lfm2")
        XCTAssertEqual(row.runtimeCompatibility.modality, .text)
        XCTAssertEqual(row.weightBytes, 708_967_936)
        XCTAssertEqual(row.usedStorageBytes, 708_984_464)
        XCTAssertEqual(row.libraryName, "transformers")
    }

    func testFlux2KleinDetailKeepsCurrentSizeAndSupportedRuntimeEvidence() async throws {
        HuggingFaceSearchHydrationURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

            if components.path == "/api/models/mlx-community/flux2-klein-4b-4bit" {
                return Self.response(for: url, body: Self.flux2KleinDetailRow)
            }

            XCTFail("Unexpected Hugging Face request: \(url.absoluteString)")
            return Self.response(for: url, statusCode: 404, body: "{}")
        }

        let detail = try await HuggingFaceSearch(session: session)
            .modelDetails(modelId: "mlx-community/flux2-klein-4b-4bit")
        let row = try XCTUnwrap(detail)

        XCTAssertEqual(row.modelId, "mlx-community/flux2-klein-4b-4bit")
        XCTAssertEqual(row.libraryName, "mlx")
        XCTAssertEqual(row.pipeline, "text-to-image")
        XCTAssertEqual(row.usedStorageBytes, 4_619_599_348)
        XCTAssertEqual(row.weightBytes, 4_608_176_698)
        XCTAssertEqual(row.runtimeCompatibility.format, .mlx)
        XCTAssertEqual(row.runtimeCompatibility.modelType, "flux2-klein")
        XCTAssertEqual(row.runtimeCompatibility.modality, .image)
        XCTAssertTrue(row.runtimeCompatibility.isCompatible)
        XCTAssertEqual(
            row.runtimeCompatibility.reason,
            "MLX flux2-klein image pipeline is supported by the MLX Studio image backend"
        )
    }

    func testRuntimeCompatibleSearchDropsQwenImageUntilPromptProofExists() async throws {
        HuggingFaceSearchHydrationURLProtocol.handler = { request in
            let url = try XCTUnwrap(request.url)
            let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let queryItems = Dictionary(
                uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
            )

            if components.path == "/api/models" {
                let body = queryItems["filter"] == "mlx" ? Self.qwenImageSearchRows : "[]"
                return Self.response(for: url, body: body)
            }

            XCTFail("Qwen Image should be filtered before detail hydration: \(url.absoluteString)")
            return Self.response(for: url, statusCode: 404, body: "{}")
        }

        let rows = try await HuggingFaceSearch(session: session)
            .searchRuntimeCompatible(query: "qwen image", limit: 5)

        XCTAssertTrue(rows.isEmpty)
    }

    private static func response(
        for url: URL,
        statusCode: Int = 200,
        body: String
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (response, Data(body.utf8))
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let searchRowsWithoutSizes = #"""
    [
      {
        "modelId": "mlx-community/Qwen3-0.6B-8bit",
        "downloads": 1200,
        "likes": 42,
        "lastModified": "2025-05-01T00:00:00.000Z",
        "tags": ["mlx", "safetensors", "qwen3", "text-generation", "8-bit"],
        "gated": false,
        "pipeline_tag": "text-generation",
        "library_name": "mlx",
        "config": { "model_type": "qwen3" },
        "siblings": [
          { "rfilename": "config.json" },
          { "rfilename": "model.safetensors" },
          { "rfilename": "tokenizer.json" }
        ]
      }
    ]
    """#

    private static let detailRowWithSizes = #"""
    {
      "modelId": "mlx-community/Qwen3-0.6B-8bit",
      "downloads": 1200,
      "likes": 42,
      "lastModified": "2025-05-04T11:58:56.000Z",
      "usedStorage": 644865648,
      "tags": ["mlx", "safetensors", "qwen3", "text-generation", "8-bit"],
      "gated": false,
      "pipeline_tag": "text-generation",
      "library_name": "mlx",
      "config": { "model_type": "qwen3" },
      "siblings": [
        { "rfilename": ".gitattributes", "size": 1570 },
        { "rfilename": "config.json", "size": 937 },
        { "rfilename": "model.safetensors", "size": 633442994 },
        { "rfilename": "tokenizer.json", "size": 1142916 }
      ]
    }
    """#

    private static let lfm25SearchRowsWithoutSizes = #"""
    [
      {
        "modelId": "LiquidAI/LFM2.5-350M",
        "downloads": 71958,
        "likes": 355,
        "lastModified": "2026-06-03T17:31:38.000Z",
        "tags": ["transformers", "safetensors", "lfm2", "text-generation", "liquid", "lfm2.5"],
        "gated": false,
        "pipeline_tag": "text-generation",
        "library_name": "transformers",
        "config": {
          "architectures": ["Lfm2ForCausalLM"],
          "model_type": "lfm2"
        },
        "siblings": [
          { "rfilename": "config.json" },
          { "rfilename": "model.safetensors" },
          { "rfilename": "tokenizer.json" }
        ]
      }
    ]
    """#

    private static let lfm25DetailRowWithSizes = #"""
    {
      "modelId": "LiquidAI/LFM2.5-350M",
      "downloads": 71958,
      "likes": 355,
      "lastModified": "2026-06-03T17:31:38.000Z",
      "usedStorage": 708984464,
      "tags": ["transformers", "safetensors", "lfm2", "text-generation", "liquid", "lfm2.5"],
      "gated": false,
      "pipeline_tag": "text-generation",
      "library_name": "transformers",
      "config": {
        "architectures": ["Lfm2ForCausalLM"],
        "model_type": "lfm2"
      },
      "siblings": [
        { "rfilename": "LICENSE", "size": 14261 },
        { "rfilename": "config.json", "size": 918 },
        { "rfilename": "model.safetensors", "size": 708967936 },
        { "rfilename": "tokenizer.json", "size": 1436300 },
        { "rfilename": "tokenizer_config.json", "size": 378 }
      ]
    }
    """#

    private static let flux2KleinDetailRow = #"""
    {
      "modelId": "mlx-community/flux2-klein-4b-4bit",
      "downloads": 0,
      "likes": 1,
      "lastModified": "2026-05-23T23:11:42.000Z",
      "usedStorage": 4619599348,
      "tags": [
        "mlx",
        "safetensors",
        "mflux",
        "text-to-image",
        "base_model:black-forest-labs/FLUX.2-klein-4B"
      ],
      "gated": false,
      "pipeline_tag": "text-to-image",
      "library_name": "mlx",
      "config": {},
      "siblings": [
        { "rfilename": "README.md", "size": 607 },
        { "rfilename": "text_encoder/0.safetensors", "size": 2135435122 },
        { "rfilename": "text_encoder/1.safetensors", "size": 127582140 },
        { "rfilename": "text_encoder/model.safetensors.index.json", "size": 51369 },
        { "rfilename": "tokenizer/chat_template.jinja", "size": 4168 },
        { "rfilename": "tokenizer/tokenizer.json", "size": 11422650 },
        { "rfilename": "tokenizer/tokenizer_config.json", "size": 703 },
        { "rfilename": "transformer/0.safetensors", "size": 2145323732 },
        { "rfilename": "transformer/1.safetensors", "size": 34727761 },
        { "rfilename": "transformer/model.safetensors.index.json", "size": 26945 },
        { "rfilename": "vae/0.safetensors", "size": 165107943 },
        { "rfilename": "vae/model.safetensors.index.json", "size": 17584 }
      ]
    }
    """#

    private static let qwenImageSearchRows = #"""
    [
      {
        "modelId": "mlx-community/Qwen-Image-4bit",
        "downloads": 2500,
        "likes": 80,
        "lastModified": "2026-05-04T11:58:56.000Z",
        "usedStorage": 18000000000,
        "tags": ["mlx", "safetensors", "mflux", "qwen-image", "text-to-image"],
        "gated": false,
        "pipeline_tag": "text-to-image",
        "library_name": "mflux",
        "config": {},
        "siblings": [
          { "rfilename": "transformer/0.safetensors", "size": 11000000000 },
          { "rfilename": "text_encoder/0.safetensors", "size": 6500000000 },
          { "rfilename": "tokenizer/tokenizer.json", "size": 11422650 },
          { "rfilename": "vae/0.safetensors", "size": 165107943 }
        ]
      }
    ]
    """#
}

private final class HuggingFaceSearchHydrationURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "huggingface.co"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
