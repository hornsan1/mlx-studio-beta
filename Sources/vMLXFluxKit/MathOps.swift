import Foundation
import MLX
import MLXNN

// MARK: - Shared math building blocks
//
// Primitives used across every Flux-family model: timestep embedding
// (sinusoidal + MLP), RoPE (rotary position embedding for 2D image
// latents), attention with RoPE, SwiGLU feedforward, RMSNorm. Ported
// 1:1 from the Python mflux reference so weight names match.

// MARK: - Timestep embedding

/// Sinusoidal time embedding → MLP projection. Mirrors the pattern in
/// `mflux/models/flux/common/timesteps_projection.py` and Diffusers'
/// `TimestepEmbedding`.
public func sinusoidalTimeEmbedding(
    timesteps: MLXArray,
    embeddingDim: Int,
    maxPeriod: Float = 10000,
    scale: Float = 1000
) -> MLXArray {
    // `timesteps` is shape [B]. Return shape [B, embeddingDim].
    let half = embeddingDim / 2
    let exponent = MLXArray(
        (0..<half).map { -log(maxPeriod) * Float($0) / Float(half) }
    )
    let freqs = exp(exponent)
    let scaled = (timesteps * MLXArray(scale)).reshaped([timesteps.dim(0), 1])
    let args = scaled * freqs.reshaped([1, half])
    let sinPart = sin(args)
    let cosPart = cos(args)
    return concatenated([cosPart, sinPart], axis: -1)
}

// MARK: - RoPE for 2D latents

/// Rotary position embedding frequencies for the H×W latent grid.
/// Flux uses a concatenation of three 1D RoPE bands (time-axis stub,
/// height, width). We expose the simpler 2D variant here as a starting
/// point; the Flux-specific 3-axis version lives in the Flux1 attention
/// block where it composes with text-token axis.
/// Not `Sendable` because `MLXArray` isn't. RoPE caches live on the
/// model actor so cross-isolation passing never happens.
public struct RoPE2D {
    public let cosCache: MLXArray
    public let sinCache: MLXArray

    public init(headDim: Int, height: Int, width: Int, theta: Float = 10000) {
        let half = headDim / 2
        // Frequency bands.
        let freqs = MLXArray(
            (0..<half).map { pow(theta, -Float($0 * 2) / Float(headDim)) }
        )

        // 2D position grid, flattened to seq-len = H*W.
        var posY: [Float] = []
        var posX: [Float] = []
        for y in 0..<height {
            for x in 0..<width {
                posY.append(Float(y))
                posX.append(Float(x))
            }
        }
        let yMat = MLXArray(posY).reshaped([height * width, 1]) * freqs.reshaped([1, half])
        let xMat = MLXArray(posX).reshaped([height * width, 1]) * freqs.reshaped([1, half])

        // Interleave y and x bands so half of the dims get 2D positions.
        let yCos = cos(yMat)
        let ySin = sin(yMat)
        let xCos = cos(xMat)
        let xSin = sin(xMat)
        self.cosCache = concatenated([yCos, xCos], axis: -1)
        self.sinCache = concatenated([ySin, xSin], axis: -1)
    }

    /// Apply the rotation to a (B, H, S, D) tensor where `S` is the
    /// 2D-flattened sequence length and `D` is head dimension.
    public func apply(_ x: MLXArray) -> MLXArray {
        // Reshape cache for broadcasting: (1, 1, S, D).
        let c = cosCache.reshaped([1, 1, cosCache.dim(0), cosCache.dim(1)])
        let s = sinCache.reshaped([1, 1, sinCache.dim(0), sinCache.dim(1)])
        // Split x into two halves along the head dim, rotate.
        let d = x.dim(-1)
        let half = d / 2
        let x1 = x[.ellipsis, 0 ..< half]
        let x2 = x[.ellipsis, half ..< d]
        // Build the rotated version: (x1*cos - x2*sin, x1*sin + x2*cos)
        // Note: this is the simple variant; the full Flux RoPE also
        // handles the time axis which is concat'd in the model layer.
        let c1 = c[.ellipsis, 0 ..< half]
        let s1 = s[.ellipsis, 0 ..< half]
        let rotated1 = x1 * c1 - x2 * s1
        let rotated2 = x1 * s1 + x2 * c1
        return concatenated([rotated1, rotated2], axis: -1)
    }
}

// MARK: - Flux axial RoPE (EmbedND)
//
// REVIEW MED-8 (2026-07-01): the real Flux rotary embedding, replacing the
// former `rope: nil` TODO in the DiT blocks. Faithful port of
// black-forest-labs/flux `math.py` (EmbedND + apply_rope):
//   • Per-axis position ids over `axesDim` (Flux: [16,56,56], sum == headDim).
//     Text tokens use position 0 on every axis (→ identity); image tokens use
//     (0, row, col) on the 3 axes.
//   • Interleaved pairing: for pair i, rotate (x[2i], x[2i+1]) by angle
//     pos·omega, omega_j = theta^(-2j/axesDim[axis]).
// Validated bit-for-bit against a NumPy reference (tests/e2e/rope-verify) and
// for rotation invariants (norm-preserving; position-0 identity) in
// `regression-check`.
public struct FluxRoPE {
    public let cosCache: MLXArray   // (L, headDim/2)
    public let sinCache: MLXArray   // (L, headDim/2)
    public let seqLen: Int

    /// Build the rope caches for a concatenated [text, image] sequence.
    /// - textLen: number of leading text tokens (position 0 on all axes).
    /// - latentH/latentW: image patch grid (image tokens = latentH*latentW).
    public init(headDim: Int, textLen: Int, latentH: Int, latentW: Int,
                theta: Float = 10_000, axesDim: [Int]? = nil) {
        // Default to Flux's [16,56,56] when headDim==128; otherwise split the
        // head dim across a batch axis (small) + two spatial axes evenly.
        let axes: [Int]
        if let axesDim { axes = axesDim }
        else if headDim == 128 { axes = [16, 56, 56] }
        else {
            let spatial = ((headDim / 2) / 2) * 2   // even
            axes = [headDim - 2 * spatial, spatial, spatial]
        }
        precondition(axes.reduce(0, +) == headDim, "axesDim must sum to headDim")
        let half = headDim / 2

        // Position ids: text → (0,0,0); image → (0, row, col).
        var positions: [[Float]] = []
        positions.reserveCapacity(textLen + latentH * latentW)
        for _ in 0..<textLen { positions.append([0, 0, 0]) }
        for y in 0..<latentH {
            for x in 0..<latentW { positions.append([0, Float(y), Float(x)]) }
        }
        let L = positions.count
        self.seqLen = L

        // Precompute per-pair (axis, omega).
        var pairAxis: [Int] = []
        var pairOmega: [Float] = []
        for (a, dim) in axes.enumerated() {
            let pairs = dim / 2
            for j in 0..<pairs {
                pairAxis.append(a)
                pairOmega.append(1.0 / pow(theta, Float(2 * j) / Float(dim)))
            }
        }
        precondition(pairAxis.count == half)

        var cosFlat = [Float](); cosFlat.reserveCapacity(L * half)
        var sinFlat = [Float](); sinFlat.reserveCapacity(L * half)
        for pos in positions {
            for p in 0..<half {
                let ang = pos[pairAxis[p]] * pairOmega[p]
                cosFlat.append(cos(ang))
                sinFlat.append(sin(ang))
            }
        }
        self.cosCache = MLXArray(cosFlat).reshaped([L, half])
        self.sinCache = MLXArray(sinFlat).reshaped([L, half])
    }

    /// Apply to a (B, H, L, headDim) tensor. Interleaved-pair rotation,
    /// matching Flux `apply_rope`. Norm-preserving.
    public func apply(_ x: MLXArray) -> MLXArray {
        let b = x.dim(0), h = x.dim(1), l = x.dim(2), d = x.dim(3)
        let half = d / 2
        let xr = x.reshaped([b, h, l, half, 2])
        let x0 = xr[.ellipsis, 0]   // (B,H,L,half)
        let x1 = xr[.ellipsis, 1]
        let c = cosCache.reshaped([1, 1, l, half])
        let s = sinCache.reshaped([1, 1, l, half])
        let o0 = x0 * c - x1 * s
        let o1 = x0 * s + x1 * c
        return stacked([o0, o1], axis: -1).reshaped([b, h, l, d])
    }
}

// MARK: - Text conditioning adapter (REVIEW MED-7)
//
// Z-Image (and the Qwen-Image scaffold) previously ENCODED the prompt and
// then threw it away — feeding the DiT `zeros` for both the token sequence
// and the pooled vector, so the prompt had zero effect on the output
// (prompt-independent noise). This helper adapts the real text-encoder
// features into the DiT's expected shapes WITHOUT trained projection
// weights, preserving prompt information so the output is prompt-dependent.
// (Photorealistic quality still needs the real Z-Image DiT + weights; this
// fixes the specific "prompt is ignored" defect and is unit-testable
// without any model download.)
public enum TextConditioningAdapter {
    /// Adapt raw encoder features `(1, S, E)` → a `(1, nTxt, textDim)` token
    /// sequence + a `(1, pooledDim)` pooled vector. Feature/seq dims are
    /// padded or truncated (no learned projection); the pooled vector is a
    /// mean over the sequence. Output is non-zero and varies with the prompt.
    public static func adapt(
        encoderOut: MLXArray, nTxt: Int, textDim: Int, pooledDim: Int
    ) -> (txt: MLXArray, pooled: MLXArray) {
        let s = encoderOut.dim(1)
        let e = encoderOut.dim(2)

        // Feature dim E → textDim.
        var seq = encoderOut
        if e > textDim {
            seq = seq[0..., 0..., 0 ..< textDim]
        } else if e < textDim {
            let pad = MLXArray.zeros([1, s, textDim - e], dtype: encoderOut.dtype)
            seq = concatenated([seq, pad], axis: 2)
        }
        // Seq S → nTxt.
        if s > nTxt {
            seq = seq[0..., 0 ..< nTxt, 0...]
        } else if s < nTxt {
            let pad = MLXArray.zeros([1, nTxt - s, textDim], dtype: encoderOut.dtype)
            seq = concatenated([seq, pad], axis: 1)
        }

        // Pooled = mean over the (original) sequence, adapted to pooledDim.
        var pooled = mean(encoderOut, axis: 1)   // (1, E)
        if e > pooledDim {
            pooled = pooled[0..., 0 ..< pooledDim]
        } else if e < pooledDim {
            let pad = MLXArray.zeros([1, pooledDim - e], dtype: encoderOut.dtype)
            pooled = concatenated([pooled, pad], axis: 1)
        }
        return (seq, pooled)
    }
}

// MARK: - RMS normalization
//
// vmlx-flux uses MLXNN's `RMSNorm(dimensions:eps:)` directly — it ships
// as `open class RMSNorm: Module, UnaryLayer` with a hardware-accelerated
// `MLXFast.rmsNorm` body. A pure-Swift fallback used to live here; it was
// removed to avoid a naming collision where my local class was shadowing
// the fast path. If you need to swap in a custom norm for a future model,
// subclass `MLXNN.RMSNorm` — don't re-declare a top-level `RMSNorm`.

// MARK: - Scaled dot-product attention with RoPE

/// Multi-head attention over a (B, S, D) sequence. Takes pre-computed
/// Q/K/V projections from the caller. `rope` is applied to Q and K
/// before the attention score is computed.
public func scaledDotProductAttention(
    q: MLXArray,
    k: MLXArray,
    v: MLXArray,
    rope: RoPE2D?,
    scale: Float? = nil
) -> MLXArray {
    // q/k/v are (B, H, S, D_head)
    let qRoped = rope?.apply(q) ?? q
    let kRoped = rope?.apply(k) ?? k

    let d = Float(q.dim(-1))
    let effectiveScale = scale ?? (1.0 / sqrt(d))
    // (B, H, S_q, D) @ (B, H, D, S_k) → (B, H, S_q, S_k)
    let scores = matmul(qRoped, kRoped.transposed(0, 1, 3, 2)) * MLXArray(effectiveScale)
    let attn = softmax(scores, axis: -1)
    return matmul(attn, v)  // (B, H, S_q, D)
}
