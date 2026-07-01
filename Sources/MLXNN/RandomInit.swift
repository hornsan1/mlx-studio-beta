// Copyright © 2024 Apple Inc.

import Foundation
import MLX
import MLXRandom

enum MLXNNRandomInit {
    private static var useZeroFallback: Bool {
        ProcessInfo.processInfo.environment["VMLX_MLXNN_ZERO_RANDOM_INIT"] == "1"
    }

    static func uniform(_ range: Range<Float>, _ shape: [Int]) -> MLXArray {
        if useZeroFallback {
            return MLXArray.zeros(shape)
        }
        return MLXRandom.uniform(range, shape)
    }

    static func uniform(low: Float, high: Float, _ shape: [Int]) -> MLXArray {
        if useZeroFallback {
            return MLXArray.zeros(shape)
        }
        return MLXRandom.uniform(low: low, high: high, shape)
    }

    static func normal(_ shape: [Int], scale: Float = 1) -> MLXArray {
        if useZeroFallback {
            return MLXArray.zeros(shape)
        }
        return MLXRandom.normal(shape, scale: scale)
    }
}
