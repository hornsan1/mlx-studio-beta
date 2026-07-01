import Foundation

public enum ImageGenerationSafety {
    public struct Estimate: Sendable, Equatable {
        public let width: Int
        public let height: Int
        public let numImages: Int
        public let modelStorageBytes: Int64
        public let estimatedPeakBytes: Int64
        public let unifiedMemoryBytes: Int64
        public let budgetBytes: Int64

        public var summary: String {
            "\(Self.format(estimatedPeakBytes)) peak / \(Self.format(unifiedMemoryBytes)) unified"
        }

        public var budgetSummary: String {
            "\(Self.format(budgetBytes)) recommended ceiling"
        }

        static func format(_ bytes: Int64) -> String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
        }
    }

    public struct ValidationFailure: Error, LocalizedError, Sendable, Equatable {
        public let message: String

        public var errorDescription: String? { message }
    }

    public static let maximumDimension = 1_024
    public static let minimumDimension = 256
    public static let dimensionStep = 64
    public static let maximumPixels = 1_024 * 1_024
    public static let maximumNumImages = 1
    public static let reservedSystemBytes: Int64 = 4 * 1_024 * 1_024 * 1_024

    public static func normalizedForEditing(_ settings: ImageGenSettings) -> ImageGenSettings {
        var normalized = settings
        normalized.width = normalizedDimension(settings.width)
        normalized.height = normalizedDimension(settings.height)
        normalized.steps = max(1, settings.steps)
        normalized.numImages = min(max(1, settings.numImages), maximumNumImages)
        return normalized
    }

    public static func estimate(
        settings: ImageGenSettings,
        modelStorageBytes: Int64?,
        physicalMemoryBytes: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    ) -> Estimate {
        let storage = max(0, modelStorageBytes ?? 0)
        let pixels = max(0, Int64(settings.width)) * max(0, Int64(settings.height))
        let steps = max(1, Int64(settings.steps))
        let imageScratch = pixels * steps * 18
        let modelResident = storage > 0 ? Int64(Double(storage) * 1.35) : 8 * 1_024 * 1_024 * 1_024
        let promptAndVAEOverhead: Int64 = 2 * 1_024 * 1_024 * 1_024
        let peak = modelResident + imageScratch + promptAndVAEOverhead
        let budget = max(0, physicalMemoryBytes - reservedSystemBytes)
        return Estimate(
            width: settings.width,
            height: settings.height,
            numImages: settings.numImages,
            modelStorageBytes: storage,
            estimatedPeakBytes: peak,
            unifiedMemoryBytes: physicalMemoryBytes,
            budgetBytes: budget
        )
    }

    public static func validationMessage(
        settings: ImageGenSettings,
        modelStorageBytes: Int64?,
        physicalMemoryBytes: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    ) -> String? {
        guard settings.width >= minimumDimension, settings.height >= minimumDimension else {
            return "Image dimensions must be at least \(minimumDimension)x\(minimumDimension)."
        }
        guard settings.width <= maximumDimension, settings.height <= maximumDimension else {
            return "Image dimensions above \(maximumDimension)x\(maximumDimension) are disabled for the beta Metal path."
        }
        guard settings.width % dimensionStep == 0, settings.height % dimensionStep == 0 else {
            return "Image dimensions must be multiples of \(dimensionStep) for the Flux runtime."
        }
        guard settings.width * settings.height <= maximumPixels else {
            return "Image area is too large for the beta Metal path. Start at 1024x1024 or smaller."
        }
        guard settings.steps > 0 else {
            return "Image steps must be greater than zero."
        }
        guard settings.numImages <= maximumNumImages else {
            return "Batch image generation is disabled for the beta Metal path. Generate one image at a time."
        }

        let estimate = estimate(
            settings: settings,
            modelStorageBytes: modelStorageBytes,
            physicalMemoryBytes: physicalMemoryBytes
        )
        guard estimate.estimatedPeakBytes <= estimate.budgetBytes else {
            return "This run needs about \(Estimate.format(estimate.estimatedPeakBytes)) unified memory; the recommended ceiling on this Mac is \(Estimate.format(estimate.budgetBytes))."
        }
        return nil
    }

    public static func validate(
        settings: ImageGenSettings,
        modelStorageBytes: Int64?,
        physicalMemoryBytes: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)
    ) throws {
        if let message = validationMessage(
            settings: settings,
            modelStorageBytes: modelStorageBytes,
            physicalMemoryBytes: physicalMemoryBytes
        ) {
            throw ValidationFailure(message: message)
        }
    }

    private static func normalizedDimension(_ value: Int) -> Int {
        let bounded = min(max(value, minimumDimension), maximumDimension)
        let remainder = bounded % dimensionStep
        guard remainder != 0 else { return bounded }

        let roundedUp = bounded + (dimensionStep - remainder)
        if roundedUp <= maximumDimension {
            return roundedUp
        }
        return maximumDimension - (maximumDimension % dimensionStep)
    }
}
