// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import vMLXEngine

final class HuggingFaceRuntimeCompatibilityTests: XCTestCase {
    private let supported: Set<String> = ["qwen3", "qwen3_5", "gemma3", "lfm2"]

    func testMLXTextModelWithRuntimeTypeIsCompatible() {
        let compatibility = HuggingFaceRuntimeCompatibility.evaluate(
            modelId: "mlx-community/Qwen3-0.6B-8bit",
            tags: ["mlx", "text-generation", "8-bit"],
            pipeline: "text-generation",
            libraryName: "mlx",
            config: ["model_type": "qwen3"],
            siblingFilenames: ["config.json", "model.safetensors", "tokenizer.json"],
            supportedModelTypes: supported
        )

        XCTAssertTrue(compatibility.isCompatible)
        XCTAssertEqual(compatibility.format, .mlx)
        XCTAssertEqual(compatibility.modelType, "qwen3")
        XCTAssertEqual(compatibility.modality, .text)
    }

    func testJANGModelIsCompatibleOnlyWhenModelTypeIsRuntimeSupported() {
        let compatibility = HuggingFaceRuntimeCompatibility.evaluate(
            modelId: "dealign/Qwen3-JANGTQ",
            tags: ["jang", "mxtq", "qwen3"],
            pipeline: "text-generation",
            libraryName: nil,
            config: ["model_type": "qwen3"],
            siblingFilenames: ["config.json", "jang_config.json", "model.safetensors", "tokenizer.json"],
            supportedModelTypes: supported
        )

        XCTAssertTrue(compatibility.isCompatible)
        XCTAssertEqual(compatibility.format, .jang)
        XCTAssertEqual(compatibility.modelType, "qwen3")
    }

    func testUnsupportedModelTypeIsBlockedWithReason() {
        let compatibility = HuggingFaceRuntimeCompatibility.evaluate(
            modelId: "mlx-community/LongCat-Next-MLX",
            tags: ["mlx"],
            pipeline: "text-generation",
            libraryName: "mlx",
            config: ["model_type": "longcat_next"],
            siblingFilenames: ["config.json", "model.safetensors", "tokenizer.json"],
            supportedModelTypes: supported
        )

        XCTAssertFalse(compatibility.isCompatible)
        XCTAssertEqual(compatibility.format, .mlx)
        XCTAssertEqual(compatibility.modelType, "longcat_next")
        XCTAssertTrue(compatibility.reason.contains("not loadable"))
    }

    func testMissingRuntimeFilesAreBlocked() {
        let compatibility = HuggingFaceRuntimeCompatibility.evaluate(
            modelId: "mlx-community/Qwen3-tokenizer-only",
            tags: ["mlx"],
            pipeline: "text-generation",
            libraryName: "mlx",
            config: ["model_type": "qwen3"],
            siblingFilenames: ["config.json", "tokenizer.json"],
            supportedModelTypes: supported
        )

        XCTAssertFalse(compatibility.isCompatible)
        XCTAssertEqual(compatibility.reason, "Missing config, safetensors, or tokenizer files")
    }

    func testTransformersTextModelWithNativeRuntimeTypeIsCompatible() {
        let compatibility = HuggingFaceRuntimeCompatibility.evaluate(
            modelId: "LiquidAI/LFM2.5-350M",
            tags: ["transformers", "safetensors", "lfm2", "text-generation"],
            pipeline: "text-generation",
            libraryName: "transformers",
            config: [
                "architectures": ["Lfm2ForCausalLM"],
                "model_type": "lfm2",
            ],
            siblingFilenames: ["config.json", "model.safetensors", "tokenizer.json"],
            supportedModelTypes: supported
        )

        XCTAssertTrue(compatibility.isCompatible)
        XCTAssertEqual(compatibility.format, .transformers)
        XCTAssertEqual(compatibility.modelType, "lfm2")
        XCTAssertEqual(compatibility.modality, .text)
        XCTAssertEqual(compatibility.reason, "HF lfm2 is supported by vMLX")
    }

    func testNonNativeRepoWithoutTransformersMetadataIsBlocked() {
        let compatibility = HuggingFaceRuntimeCompatibility.evaluate(
            modelId: "org/Qwen3-pytorch",
            tags: ["safetensors"],
            pipeline: "text-generation",
            libraryName: "pytorch",
            config: ["model_type": "qwen3"],
            siblingFilenames: ["config.json", "model.safetensors", "tokenizer.json"],
            supportedModelTypes: supported
        )

        XCTAssertFalse(compatibility.isCompatible)
        XCTAssertNil(compatibility.format)
        XCTAssertEqual(compatibility.reason, "Repo is not tagged or packaged as MLX/JANG/HF")
    }

    func testMLXFluxSchnellImageModelIsCompatible() {
        let compatibility = HuggingFaceRuntimeCompatibility.evaluate(
            modelId: "AITRADER/FLUX1-schnell-mlx-4bit",
            tags: [
                "mflux",
                "mlx",
                "flux",
                "image-generation",
                "base_model:black-forest-labs/FLUX.1-schnell",
            ],
            pipeline: nil,
            libraryName: "mflux",
            config: [:],
            siblingFilenames: [
                "text_encoder/0.safetensors",
                "text_encoder_2/0.safetensors",
                "tokenizer/tokenizer.json",
                "tokenizer_2/tokenizer.json",
                "transformer/0.safetensors",
                "transformer/1.safetensors",
                "vae/0.safetensors",
            ],
            supportedModelTypes: supported
        )

        XCTAssertTrue(compatibility.isCompatible)
        XCTAssertEqual(compatibility.format, .mlx)
        XCTAssertEqual(compatibility.modelType, "flux1-schnell")
        XCTAssertEqual(compatibility.modality, .image)
    }

    func testMLXImageRepoWithoutFluxComponentLayoutIsBlocked() {
        let compatibility = HuggingFaceRuntimeCompatibility.evaluate(
            modelId: "argmaxinc/mlx-FLUX.1-schnell-4bit-quantized",
            tags: ["diffusionkit", "text-to-image", "image-generation", "flux", "mlx"],
            pipeline: "text-to-image",
            libraryName: "diffusionkit",
            config: [:],
            siblingFilenames: [
                "config.json",
                "ae.safetensors",
                "flux-schnell-4bit-quantized.safetensors",
            ],
            supportedModelTypes: supported
        )

        XCTAssertFalse(compatibility.isCompatible)
        XCTAssertEqual(compatibility.format, .mlx)
        XCTAssertEqual(compatibility.modelType, "flux1-schnell")
        XCTAssertEqual(compatibility.reason, "Missing Flux component weights, VAE, or tokenizer files")
    }

    func testFlux1DevImageModelIsCompatible() {
        let compatibility = HuggingFaceRuntimeCompatibility.evaluate(
            modelId: "mlx-community/FLUX.1-dev-4bit",
            tags: ["mlx", "mflux", "flux.1-dev", "text-to-image"],
            pipeline: "text-to-image",
            libraryName: "mflux",
            config: [:],
            siblingFilenames: [
                "text_encoder/0.safetensors",
                "text_encoder_2/0.safetensors",
                "tokenizer/tokenizer.json",
                "tokenizer_2/tokenizer.json",
                "transformer/0.safetensors",
                "vae/0.safetensors",
            ],
            supportedModelTypes: supported
        )

        XCTAssertTrue(compatibility.isCompatible)
        XCTAssertEqual(compatibility.modelType, "flux1-dev")
        XCTAssertEqual(compatibility.modality, .image)
    }

    func testFlux2KleinOfficialRepoIsCompatible() {
        let compatibility = HuggingFaceRuntimeCompatibility.evaluate(
            modelId: "black-forest-labs/FLUX.2-klein-4B",
            tags: ["mlx", "flux2", "klein", "image-generation"],
            pipeline: "text-to-image",
            libraryName: "mlx",
            config: [:],
            siblingFilenames: [
                "transformer/0.safetensors",
                "tokenizer/tokenizer.json",
                "vae/0.safetensors",
            ],
            supportedModelTypes: supported
        )

        XCTAssertTrue(compatibility.isCompatible)
        XCTAssertEqual(compatibility.format, .mlx)
        XCTAssertEqual(compatibility.modelType, "flux2-klein")
        XCTAssertEqual(
            compatibility.reason,
            "MLX flux2-klein image pipeline is supported by the MLX Studio image backend"
        )
    }

    func testMLXCommunityFlux2Klein4BitIsCompatible() {
        let compatibility = HuggingFaceRuntimeCompatibility.evaluate(
            modelId: "mlx-community/flux2-klein-4b-4bit",
            tags: ["mlx", "mflux", "flux2", "klein", "text-to-image"],
            pipeline: "text-to-image",
            libraryName: "mflux",
            config: [:],
            siblingFilenames: [
                "transformer/0.safetensors",
                "text_encoder/0.safetensors",
                "tokenizer/tokenizer.json",
                "vae/0.safetensors",
            ],
            supportedModelTypes: supported
        )

        XCTAssertTrue(compatibility.isCompatible)
        XCTAssertEqual(compatibility.format, .mlx)
        XCTAssertEqual(compatibility.modelType, "flux2-klein")
        XCTAssertEqual(compatibility.modality, .image)
        XCTAssertEqual(
            compatibility.reason,
            "MLX flux2-klein image pipeline is supported by the MLX Studio image backend"
        )
    }

    func testQwenImageModelIsBlockedUntilPromptProvenRuntimeExists() {
        let compatibility = HuggingFaceRuntimeCompatibility.evaluate(
            modelId: "mlx-community/Qwen-Image-4bit",
            tags: ["mlx", "mflux", "qwen-image", "text-to-image"],
            pipeline: "text-to-image",
            libraryName: "mflux",
            config: [:],
            siblingFilenames: [
                "transformer/0.safetensors",
                "text_encoder/0.safetensors",
                "tokenizer/tokenizer.json",
                "vae/0.safetensors",
            ],
            supportedModelTypes: supported
        )

        XCTAssertFalse(compatibility.isCompatible)
        XCTAssertEqual(compatibility.format, .mlx)
        XCTAssertEqual(compatibility.modelType, "qwen-image")
        XCTAssertEqual(compatibility.modality, .image)
        XCTAssertTrue(compatibility.reason.contains("not prompt-proven"))
    }

    func testJANGImageModelIsBlockedUntilRuntimeExists() {
        let compatibility = HuggingFaceRuntimeCompatibility.evaluate(
            modelId: "dealign/flux1-schnell-jang",
            tags: ["jang", "mxtq", "flux", "image-generation"],
            pipeline: "text-to-image",
            libraryName: nil,
            config: ["jang": true],
            siblingFilenames: [
                "jang_config.json",
                "tokenizer/tokenizer.json",
                "transformer/0.safetensors",
                "vae/0.safetensors",
            ],
            supportedModelTypes: supported
        )

        XCTAssertFalse(compatibility.isCompatible)
        XCTAssertEqual(compatibility.format, .jang)
        XCTAssertEqual(compatibility.modality, .image)
        XCTAssertEqual(compatibility.reason, "Only MLX image pipelines are wired in the Swift runtime yet")
    }
}
