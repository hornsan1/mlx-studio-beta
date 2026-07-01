import Foundation
@preconcurrency import MLX
import MLXNN
import MLXFast

// MARK: - CLIP-L text encoder
//
// 1:1 Swift port of mflux's CLIP-L encoder used for FLUX.1 pooled
// conditioning. Architecture (HF CLIPTextModel):
//
//   embeddings:
//     token_embedding    (49408 × 768)
//     position_embedding (77 × 768)
//   encoder.layers[12]:
//     layer_norm1 (768)
//     self_attn (Q/K/V/out 768, 12 heads × 64)
//     layer_norm2 (768)
//     mlp (768 → 3072 [QuickGELU] → 768)
//   final_layer_norm (768)
//   pooled = final_layer_norm[arg_max(tokens)]   # last EOS token
//
// Reference:
//   /tmp/mflux-ref/src/mflux/models/flux/model/flux_text_encoder/clip_encoder/*

// MARK: - QuickGELU activation (CLIP-specific)

@inlinable
public func quickGELU(_ x: MLXArray) -> MLXArray {
    return x * sigmoid(MLXArray(Float(1.702)) * x)
}

// MARK: - CLIP self-attention (causal)

public final class CLIPSdpaAttention: Module {
    @ModuleInfo public var qProj: Linear
    @ModuleInfo public var kProj: Linear
    @ModuleInfo public var vProj: Linear
    @ModuleInfo public var outProj: Linear

    public let dim: Int
    public let numHeads: Int
    public let headDim: Int

    public init(dim: Int = 768, numHeads: Int = 12) {
        self.dim = dim
        self.numHeads = numHeads
        self.headDim = dim / numHeads
        self._qProj.wrappedValue = Linear(dim, dim)
        self._kProj.wrappedValue = Linear(dim, dim)
        self._vProj.wrappedValue = Linear(dim, dim)
        self._outProj.wrappedValue = Linear(dim, dim)
        super.init()
    }

    public func callAsFunction(_ x: MLXArray, causalMask: MLXArray) -> MLXArray {
        let b = x.dim(0)

        let q = reshapeHeads(qProj(x), batchSize: b)
        let k = reshapeHeads(kProj(x), batchSize: b)
        let v = reshapeHeads(vProj(x), batchSize: b)

        let scale = Float(1.0 / sqrt(Float(headDim)))
        let mask = causalMask.asType(q.dtype)
        let attnOut = MLXFast.scaledDotProductAttention(
            queries: q, keys: k, values: v, scale: scale, mask: mask
        )

        // (B, H, S, D) → (B, S, dim)
        let merged = attnOut.transposed(0, 2, 1, 3).reshaped([b, -1, dim])
        return outProj(merged)
    }

    private func reshapeHeads(_ x: MLXArray, batchSize: Int) -> MLXArray {
        // (B, S, dim) → (B, H, S, headDim)
        return x.reshaped([batchSize, -1, numHeads, headDim]).transposed(0, 2, 1, 3)
    }
}

// MARK: - CLIP MLP (QuickGELU sandwich)

public final class CLIPMLP: Module {
    @ModuleInfo public var fc1: Linear
    @ModuleInfo public var fc2: Linear

    public init(dim: Int = 768, ffnDim: Int = 3072) {
        self._fc1.wrappedValue = Linear(dim, ffnDim)
        self._fc2.wrappedValue = Linear(ffnDim, dim)
        super.init()
    }

    public func callAsFunction(_ x: MLXArray) -> MLXArray {
        return fc2(quickGELU(fc1(x)))
    }
}

// MARK: - CLIP encoder layer

public final class CLIPEncoderLayer: Module {
    public let layerNorm1: LayerNorm
    public let selfAttn: CLIPSdpaAttention
    public let layerNorm2: LayerNorm
    public let mlp: CLIPMLP

    public init(dim: Int = 768, numHeads: Int = 12, ffnDim: Int = 3072) {
        self.layerNorm1 = LayerNorm(dimensions: dim)
        self.selfAttn = CLIPSdpaAttention(dim: dim, numHeads: numHeads)
        self.layerNorm2 = LayerNorm(dimensions: dim)
        self.mlp = CLIPMLP(dim: dim, ffnDim: ffnDim)
        super.init()
    }

    public func callAsFunction(_ x: MLXArray, causalMask: MLXArray) -> MLXArray {
        var h = x
        h = h + selfAttn(layerNorm1(h), causalMask: causalMask)
        h = h + mlp(layerNorm2(h))
        return h
    }
}

// MARK: - CLIP embeddings

public final class CLIPEmbeddings: Module {
    @ModuleInfo public var tokenEmbedding: Embedding
    @ModuleInfo public var positionEmbedding: Embedding

    public init(dim: Int = 768, vocab: Int = 49408, maxLen: Int = 77) {
        self._tokenEmbedding.wrappedValue = Embedding(embeddingCount: vocab, dimensions: dim)
        self._positionEmbedding.wrappedValue = Embedding(embeddingCount: maxLen, dimensions: dim)
        super.init()
    }

    public func callAsFunction(_ tokens: MLXArray) -> MLXArray {
        let s = tokens.dim(-1)
        let positions = MLXArray((0..<s).map { Int32($0) }).reshaped([1, s])
        return tokenEmbedding(tokens) + positionEmbedding(positions)
    }
}

// MARK: - CLIP-L encoder

public final class CLIPLEncoder: Module, PooledTextEncoder, @unchecked Sendable {
    public let embeddings: CLIPEmbeddings
    public let layers: [CLIPEncoderLayer]
    public let finalLayerNorm: LayerNorm

    public let hiddenSize: Int
    public let pooledSize: Int
    public let maxSeqLen: Int

    public init(
        dim: Int = 768,
        numLayers: Int = 12,
        numHeads: Int = 12,
        ffnDim: Int = 3072,
        vocab: Int = 49408,
        maxLen: Int = 77
    ) {
        self.hiddenSize = dim
        self.pooledSize = dim
        self.maxSeqLen = maxLen
        self.embeddings = CLIPEmbeddings(dim: dim, vocab: vocab, maxLen: maxLen)
        self.layers = (0..<numLayers).map { _ in
            CLIPEncoderLayer(dim: dim, numHeads: numHeads, ffnDim: ffnDim)
        }
        self.finalLayerNorm = LayerNorm(dimensions: dim)
        super.init()
    }

    public func encode(tokenIds: [Int]) -> MLXArray {
        let (hidden, _) = encodePooled(tokenIds: tokenIds)
        return hidden
    }

    public func encodePooled(tokenIds: [Int]) -> (hidden: MLXArray, pooled: MLXArray) {
        let truncated = Array(tokenIds.prefix(maxSeqLen))
        let tokens = MLXArray(truncated.map { Int32($0) }).reshaped([1, truncated.count])
        return forward(tokens: tokens, pooledIndices: [Self.pooledTokenIndex(for: truncated)])
    }

    /// Internal forward pass. Builds a causal mask, runs the layer
    /// stack, and returns (last_hidden_state, pooled_at_eos).
    public func forward(tokens: MLXArray) -> (hidden: MLXArray, pooled: MLXArray) {
        forward(tokens: tokens, pooledIndices: nil)
    }

    /// Internal forward pass. `pooledIndices` lets tokenizer-driven
    /// callers avoid a GPU argmax over static token IDs; generic callers
    /// still fall back to MLX argmax.
    public func forward(tokens: MLXArray, pooledIndices: [Int]?) -> (hidden: MLXArray, pooled: MLXArray) {
        let s = tokens.dim(1)
        let mask = Self.causalMask(seqLen: s)
        var h = embeddings(tokens)
        for layer in layers {
            h = layer(h, causalMask: mask)
        }
        h = finalLayerNorm(h)

        // Pooled output = h at the position of the max token id (CLIP's
        // EOS-token convention from the original OpenAI checkpoint).
        let b = h.dim(0)
        let resolvedIndices: [Int]
        if let pooledIndices, pooledIndices.count == b {
            resolvedIndices = pooledIndices.map { min(max(0, $0), s - 1) }
        } else {
            // mflux uses `mx.argmax(tokens, axis=-1)`. Keep that fallback
            // for direct tensor callers that do not have CPU token IDs.
            let argmaxIdx = MLX.argMax(tokens, axis: -1)   // (B,)
            resolvedIndices = (0..<b).map { argmaxIdx[$0].item(Int.self) }
        }
        // Gather along the seq axis. h: (B, S, D); we want (B, D) by
        // selecting position argmaxIdx[b] for each batch b.
        var pooledRows: [MLXArray] = []
        for bi in 0..<b {
            pooledRows.append(h[bi, resolvedIndices[bi]])
        }
        let pooled = stacked(pooledRows, axis: 0)
        return (hidden: h, pooled: pooled)
    }

    public static func pooledTokenIndex(for tokenIds: [Int]) -> Int {
        guard let first = tokenIds.first else { return 0 }
        var bestIndex = 0
        var bestToken = first
        for (index, token) in tokenIds.enumerated().dropFirst() where token > bestToken {
            bestIndex = index
            bestToken = token
        }
        return bestIndex
    }

    /// Standard CLIP causal attention mask.
    /// Returns (1, 1, S, S) with -inf above the diagonal.
    public static func causalMask(seqLen: Int) -> MLXArray {
        // Build a triangular mask: 0 on/below diagonal, -inf above.
        let ones = MLXArray.ones([seqLen, seqLen])
        let lower = tril(ones, k: 0)
        let upper = MLXArray(Float(1)) - lower
        let masked = upper * MLXArray(Float(-3.4e38))
        return masked.reshaped([1, 1, seqLen, seqLen])
    }
}

// MARK: - HuggingFace CLIP weight remap
//
// FLUX safetensors ship CLIP-L under `text_encoder/`. HF naming:
//   text_model.embeddings.token_embedding.weight                            → embeddings.tokenEmbedding.weight
//   text_model.embeddings.position_embedding.weight                         → embeddings.positionEmbedding.weight
//   text_model.encoder.layers.{i}.self_attn.{q,k,v,out}_proj.{weight,bias}  → layers.{i}.selfAttn.{qProj,kProj,vProj,outProj}.{weight,bias}
//   text_model.encoder.layers.{i}.layer_norm{1,2}.{weight,bias}             → layers.{i}.layerNorm{1,2}.{weight,bias}
//   text_model.encoder.layers.{i}.mlp.fc{1,2}.{weight,bias}                 → layers.{i}.mlp.fc{1,2}.{weight,bias}
//   text_model.final_layer_norm.{weight,bias}                               → finalLayerNorm.{weight,bias}

public enum CLIPLWeightRemap {

    public static func remap(_ weights: [String: MLXArray]) -> [String: MLXArray] {
        var out: [String: MLXArray] = [:]
        for (k, v) in weights {
            out[remapKey(k)] = v
        }
        return out
    }

    public static func remapKey(_ key: String) -> String {
        var k = key
        if k.hasPrefix("text_encoder.") {
            k.removeFirst("text_encoder.".count)
        }
        if k.hasPrefix("text_model.") {
            k.removeFirst("text_model.".count)
        }
        // embeddings.token_embedding → embeddings.tokenEmbedding
        k = k.replacingOccurrences(
            of: "embeddings.token_embedding",
            with: "embeddings.tokenEmbedding"
        )
        k = k.replacingOccurrences(
            of: "embeddings.position_embedding",
            with: "embeddings.positionEmbedding"
        )
        // encoder.layers.{i}.* → layers.{i}.*
        if k.hasPrefix("encoder.layers.") {
            k.removeFirst("encoder.".count)
        }
        // self_attn.{q,k,v,out}_proj → selfAttn.{qProj,kProj,vProj,outProj}
        k = k.replacingOccurrences(of: "self_attn.q_proj", with: "selfAttn.qProj")
        k = k.replacingOccurrences(of: "self_attn.k_proj", with: "selfAttn.kProj")
        k = k.replacingOccurrences(of: "self_attn.v_proj", with: "selfAttn.vProj")
        k = k.replacingOccurrences(of: "self_attn.out_proj", with: "selfAttn.outProj")
        // layer_norm1/2 (HF) → layerNorm1/2 (Swift property)
        k = k.replacingOccurrences(of: "layer_norm1", with: "layerNorm1")
        k = k.replacingOccurrences(of: "layer_norm2", with: "layerNorm2")
        // final_layer_norm → finalLayerNorm
        k = k.replacingOccurrences(of: "final_layer_norm", with: "finalLayerNorm")
        return k
    }
}
