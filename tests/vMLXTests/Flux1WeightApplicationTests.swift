// SPDX-License-Identifier: Apache-2.0

import XCTest
import vMLXFluxKit
@testable import vMLXFluxModels

final class Flux1WeightApplicationTests: XCTestCase {
    func testFlux1PlaceholderTextEncoderFallbackIsExplicit() {
        XCTAssertFalse(fluxAllowsPlaceholderTextEncoderFallback(environment: [:]))
        XCTAssertFalse(fluxAllowsPlaceholderTextEncoderFallback(environment: [
            "VMLX_FLUX_BYPASS_TEXT_ENCODERS": "1",
        ]))
        XCTAssertTrue(fluxAllowsPlaceholderTextEncoderFallback(environment: [
            "VMLX_FLUX_ALLOW_PLACEHOLDER_TEXT_ENCODERS": "1",
        ]))
    }

    func testFlux2KleinTokenizerPrefersDedicatedTokenizerDirectory() throws {
        let root = try makeTemporaryDirectory()
        let tokenizerDir = root.appendingPathComponent("tokenizer", isDirectory: true)
        let textEncoderDir = root.appendingPathComponent("text_encoder", isDirectory: true)
        try FileManager.default.createDirectory(at: tokenizerDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: textEncoderDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: tokenizerDir.appendingPathComponent("tokenizer.json"))
        try Data("{}".utf8).write(to: textEncoderDir.appendingPathComponent("tokenizer.json"))

        XCTAssertEqual(
            try Flux2KleinTokenizer.resolveTokenizerDirectory(modelPath: root).standardizedFileURL,
            tokenizerDir.standardizedFileURL
        )
    }

    func testFlux2KleinTokenizerFallsBackToTextEncoderDirectory() throws {
        let root = try makeTemporaryDirectory()
        let textEncoderDir = root.appendingPathComponent("text_encoder", isDirectory: true)
        try FileManager.default.createDirectory(at: textEncoderDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: textEncoderDir.appendingPathComponent("tokenizer.json"))

        XCTAssertEqual(
            try Flux2KleinTokenizer.resolveTokenizerDirectory(modelPath: root).standardizedFileURL,
            textEncoderDir.standardizedFileURL
        )
    }

    func testFlux2KleinTokenizerRejectsMissingTokenizer() throws {
        let root = try makeTemporaryDirectory()

        XCTAssertThrowsError(try Flux2KleinTokenizer.resolveTokenizerDirectory(modelPath: root)) { error in
            XCTAssertTrue(String(describing: error).contains("weights not found"))
        }
    }

    func testFlux2KleinSwiftGeneratorRegistryRemainsPlaceholderUntilPromptProof() throws {
        vMLXFluxModels.registerAll()

        let entry = try XCTUnwrap(ModelRegistry.lookup(name: "flux2-klein"))

        XCTAssertTrue(entry.isPlaceholder)
        XCTAssertEqual(entry.defaultSteps, 28)
        XCTAssertEqual(entry.defaultGuidance, 3.5)
    }

    func testFluxTokenizerLoaderAddsModelConfigAndOverridesTokenizerClass() throws {
        let root = try makeTemporaryDirectory()
        try Data("{}".utf8).write(to: root.appendingPathComponent("tokenizer.json"))
        try Data(#"{"tokenizer_class":"CLIPTokenizer"}"#.utf8)
            .write(to: root.appendingPathComponent("tokenizer_config.json"))

        let prepared = try FluxTokenizerLoader.prepareDirectoryForAutoTokenizer(
            sourceDirectory: root,
            modelType: "clip",
            tokenizerClassOverride: "PreTrainedTokenizer"
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: prepared)
        }

        let modelConfig = try readJSONObject(prepared.appendingPathComponent("config.json"))
        let tokenizerConfig = try readJSONObject(prepared.appendingPathComponent("tokenizer_config.json"))

        XCTAssertEqual(modelConfig["model_type"] as? String, "clip")
        XCTAssertEqual(tokenizerConfig["tokenizer_class"] as? String, "PreTrainedTokenizer")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: prepared.appendingPathComponent("tokenizer.json").path
        ))
    }

    func testCLIPPooledTokenIndexUsesFirstMaximumToken() {
        let eos = CLIPBPETokenizer.eosTokenID
        let ids = [
            CLIPBPETokenizer.bosTokenID,
            321,
            eos,
            eos,
            eos,
        ]

        XCTAssertEqual(CLIPLEncoder.pooledTokenIndex(for: ids), 2)
        XCTAssertEqual(CLIPLEncoder.pooledTokenIndex(for: []), 0)
    }

    func testT5MFluxKeysRemapToSwiftModuleKeys() {
        XCTAssertEqual(
            T5XXLWeightRemap.remapKey("t5_blocks.0.attention.SelfAttention.relative_attention_bias.weight"),
            "blocks.0.attention.SelfAttention.relativeAttentionBias.weight"
        )
        XCTAssertEqual(
            T5XXLWeightRemap.remapKey("t5_blocks.3.ff.DenseReluDense.wi_0.weight"),
            "blocks.3.ff.DenseReluDense.wi0.weight"
        )
        XCTAssertEqual(
            T5XXLWeightRemap.remapKey("final_layer_norm.weight"),
            "finalLayerNorm.weight"
        )
    }

    func testVAEDecoderKeysRemapToSwiftModuleKeys() {
        XCTAssertEqual(
            VAEWeightRemap.remapKey("decoder.conv_in.conv2d.weight"),
            "convIn.weight"
        )
        XCTAssertEqual(
            VAEWeightRemap.remapKey("decoder.mid_block.attentions.0.to_out.0.bias"),
            "midAttn.proj.bias"
        )
        XCTAssertEqual(
            VAEWeightRemap.remapKey("decoder.up_blocks.2.resnets.0.conv_shortcut.weight"),
            "upBlocks.2.0.convShortcut.weight"
        )
        XCTAssertEqual(
            VAEWeightRemap.remapKey("decoder.up_blocks.1.upsamplers.0.conv.weight"),
            "upsamples.1.conv.weight"
        )
    }

    func testDiffusersFluxTransformerKeysRemapToSwiftModuleKeys() {
        XCTAssertEqual(
            Flux1WeightRemap.remapKey("x_embedder.weight"),
            "imgIn.weight"
        )
        XCTAssertEqual(
            Flux1WeightRemap.remapKey("time_text_embed.timestep_embedder.linear_1.weight"),
            "timeIn0.weight"
        )
        XCTAssertEqual(
            Flux1WeightRemap.remapKey("time_text_embed.text_embedder.linear_2.bias"),
            "vectorIn2.bias"
        )
        XCTAssertEqual(
            Flux1WeightRemap.remapKey("context_embedder.weight"),
            "txtIn.weight"
        )
        XCTAssertEqual(
            Flux1WeightRemap.remapKey("transformer_blocks.0.attn.to_q.weight"),
            "doubleBlocks.0.imgAttnQKV.weight"
        )
        XCTAssertEqual(
            Flux1WeightRemap.remapKey("transformer_blocks.0.attn.add_v_proj.weight"),
            "doubleBlocks.0.txtAttnQKV.weight"
        )
        XCTAssertEqual(
            Flux1WeightRemap.remapKey("single_transformer_blocks.0.proj_mlp.weight"),
            "singleBlocks.0.linear1.weight"
        )
        XCTAssertEqual(
            Flux1WeightRemap.remapKey("norm_out.linear.weight"),
            "finalLayer.mod.weight"
        )
    }

    func testFlux2KleinTextProjectionMatchesQwen2VLHiddenWidth() {
        XCTAssertEqual(FluxDiTConfig.flux2Klein.textDim, 3584)

        let plan = planRemappedComponentWeights(
            sourceShapes: [
                (key: "context_embedder.weight", shape: [3072, 3584]),
            ],
            targetShapes: [
                "txtIn.weight": [3072, 3584],
            ],
            remapKey: Flux1WeightRemap.remapKey
        )

        XCTAssertEqual(plan.appliedPairs.map(\.target), ["txtIn.weight"])
        XCTAssertEqual(plan.skippedShapeMismatchKeys, [])
    }

    func testQwen2VLWeightKeysRemapToSwiftModuleKeys() {
        XCTAssertEqual(
            Qwen2VL7BWeightRemap.remapKey("text_encoder.model.embed_tokens.weight"),
            "embedTokens.weight"
        )
        XCTAssertEqual(
            Qwen2VL7BWeightRemap.remapKey("model.layers.0.self_attn.q_proj.weight"),
            "layers.0.selfAttn.qProj.weight"
        )
        XCTAssertEqual(
            Qwen2VL7BWeightRemap.remapKey("model.layers.4.mlp.down_proj.bias"),
            "layers.4.mlp.downProj.bias"
        )
        XCTAssertNil(Qwen2VL7BWeightRemap.remapKey("model.visual.patch_embed.weight"))
    }

    func testShapeMatchedUpdaterSkipsQuantizedGroupsAndAppliesPlainParameters() throws {
        let plan = planRemappedComponentWeights(
            sourceShapes: [
                (key: "dense.weight", shape: [4, 1]),
                (key: "dense.bias", shape: [4]),
                (key: "dense.scales", shape: [4, 1]),
                (key: "dense.biases", shape: [4, 1]),
                (key: "norm.weight", shape: [4]),
                (key: "norm.bias", shape: [4]),
                (key: "missing.weight", shape: [4]),
                (key: "wrongShape.weight", shape: [2, 2]),
            ],
            targetShapes: [
                "dense.weight": [4, 4],
                "dense.bias": [4],
                "norm.weight": [4],
                "norm.bias": [4],
            ],
            remapKey: { key in
                key == "wrongShape.weight" ? "norm.weight" : key
            }
        )

        XCTAssertEqual(Set(plan.appliedPairs.map(\.target)), ["norm.bias", "norm.weight"])
        XCTAssertEqual(
            Set(plan.skippedQuantizedKeys),
            ["dense.bias", "dense.biases", "dense.scales", "dense.weight"]
        )
        XCTAssertEqual(plan.skippedShapeMismatchKeys, ["norm.weight"])
        XCTAssertEqual(plan.extraCheckpointKeys, ["missing.weight"])
    }

    func testQuantizedReplacementPlannerInfersBitsAndGroupSize() {
        let plan = planQuantizedModuleReplacements(
            sourceShapes: [
                (key: "dense.weight", shape: [768, 96]),
                (key: "dense.scales", shape: [768, 12]),
                (key: "dense.biases", shape: [768, 12]),
                (key: "dense.bias", shape: [768]),
                (key: "norm.weight", shape: [768]),
            ],
            targetShapes: [
                "dense.weight": [768, 768],
                "dense.bias": [768],
                "norm.weight": [768],
            ],
            remapKey: { $0 }
        )

        XCTAssertEqual(plan.unsupportedKeys, [])
        XCTAssertEqual(plan.replacements, [
            FluxQuantizedReplacement(
                sourcePrefix: "dense",
                targetPrefix: "dense",
                bits: 4,
                groupSize: 64,
                targetShape: [768, 768]
            ),
        ])
    }

    func testQuantizedReplacementPlannerFusesDiffusersQKVParts() {
        let plan = planQuantizedModuleReplacements(
            sourceShapes: [
                (key: "transformer_blocks.0.attn.to_q.weight", shape: [4, 8]),
                (key: "transformer_blocks.0.attn.to_q.scales", shape: [4, 1]),
                (key: "transformer_blocks.0.attn.to_k.weight", shape: [4, 8]),
                (key: "transformer_blocks.0.attn.to_k.scales", shape: [4, 1]),
                (key: "transformer_blocks.0.attn.to_v.weight", shape: [4, 8]),
                (key: "transformer_blocks.0.attn.to_v.scales", shape: [4, 1]),
            ],
            targetShapes: [
                "doubleBlocks.0.imgAttnQKV.weight": [12, 64],
            ],
            remapKey: Flux1WeightRemap.remapKey
        )

        XCTAssertEqual(plan.unsupportedKeys, [])
        XCTAssertEqual(plan.replacements, [
            FluxQuantizedReplacement(
                sourcePrefixes: [
                    "transformer_blocks.0.attn.to_q",
                    "transformer_blocks.0.attn.to_k",
                    "transformer_blocks.0.attn.to_v",
                ],
                targetPrefix: "doubleBlocks.0.imgAttnQKV",
                bits: 4,
                groupSize: 64,
                targetShape: [12, 64]
            ),
        ])
    }

    func testQuantizedReplacementPlannerFusesSingleBlockAttentionAndMLPParts() {
        let plan = planQuantizedModuleReplacements(
            sourceShapes: [
                (key: "single_transformer_blocks.0.attn.to_q.weight", shape: [4, 8]),
                (key: "single_transformer_blocks.0.attn.to_q.scales", shape: [4, 1]),
                (key: "single_transformer_blocks.0.attn.to_k.weight", shape: [4, 8]),
                (key: "single_transformer_blocks.0.attn.to_k.scales", shape: [4, 1]),
                (key: "single_transformer_blocks.0.attn.to_v.weight", shape: [4, 8]),
                (key: "single_transformer_blocks.0.attn.to_v.scales", shape: [4, 1]),
                (key: "single_transformer_blocks.0.proj_mlp.weight", shape: [8, 8]),
                (key: "single_transformer_blocks.0.proj_mlp.scales", shape: [8, 1]),
            ],
            targetShapes: [
                "singleBlocks.0.linear1.weight": [20, 64],
            ],
            remapKey: Flux1WeightRemap.remapKey
        )

        XCTAssertEqual(plan.unsupportedKeys, [])
        XCTAssertEqual(plan.replacements, [
            FluxQuantizedReplacement(
                sourcePrefixes: [
                    "single_transformer_blocks.0.attn.to_q",
                    "single_transformer_blocks.0.attn.to_k",
                    "single_transformer_blocks.0.attn.to_v",
                    "single_transformer_blocks.0.proj_mlp",
                ],
                targetPrefix: "singleBlocks.0.linear1",
                bits: 4,
                groupSize: 64,
                targetShape: [20, 64]
            ),
        ])
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmlx-flux-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func readJSONObject(_ url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
