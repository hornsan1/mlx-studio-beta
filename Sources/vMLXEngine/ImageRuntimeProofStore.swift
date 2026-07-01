import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
#endif

public enum ImageRuntimeProofStore {
    public static let directoryEnvironmentKey = "MLX_STUDIO_IMAGE_PROOF_DIR"

    public struct PNGVerification: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public let pixelVariance: Double
        public let byteCount: Int
    }

    public struct VerificationFailure: Error, LocalizedError, Equatable, Sendable {
        public let message: String

        public init(_ message: String) {
            self.message = message
        }

        public var errorDescription: String? { message }
    }

    public struct Proof: Codable, Equatable, Sendable {
        public let runtimeName: String
        public let modelPath: String
        public let outputPath: String
        public let width: Int
        public let height: Int
        public let steps: Int
        public let seed: Int
        public let pixelVariance: Double?
        public let verifiedAt: Date

        public init(
            runtimeName: String,
            modelPath: String,
            outputPath: String,
            width: Int,
            height: Int,
            steps: Int,
            seed: Int,
            pixelVariance: Double?,
            verifiedAt: Date = Date()
        ) {
            self.runtimeName = runtimeName
            self.modelPath = modelPath
            self.outputPath = outputPath
            self.width = width
            self.height = height
            self.steps = steps
            self.seed = seed
            self.pixelVariance = pixelVariance
            self.verifiedAt = verifiedAt
        }
    }

    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let raw = environment[directoryEnvironmentKey],
           !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return URL(fileURLWithPath: raw)
        }
        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/vMLX/image-runtime-proofs", isDirectory: true)
    }

    public static func proofURL(
        runtimeName: String,
        directory: URL? = nil
    ) -> URL {
        let dir = directory ?? defaultDirectory()
        return dir.appendingPathComponent("\(safeFilename(for: runtimeName)).json")
    }

    public static func record(_ proof: Proof, directory: URL? = nil) throws {
        let url = proofURL(runtimeName: proof.runtimeName, directory: directory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(proof)
        try data.write(to: url, options: .atomic)
    }

    public static func latestProof(
        runtimeName: String,
        directory: URL? = nil
    ) -> Proof? {
        let url = proofURL(runtimeName: runtimeName, directory: directory)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Proof.self, from: data)
    }

    public static func isVerified(
        runtimeName: String,
        modelPath: String? = nil,
        directory: URL? = nil
    ) -> Bool {
        guard let proof = latestProof(runtimeName: runtimeName, directory: directory) else {
            return false
        }
        guard proof.runtimeName == runtimeName
            && proof.width >= ImageGenerationSafety.minimumDimension
            && proof.height >= ImageGenerationSafety.minimumDimension
            && proof.steps > 0
            && (proof.pixelVariance ?? 1) >= 1
            && FileManager.default.fileExists(atPath: proof.outputPath)
        else {
            return false
        }
        guard let modelPath else { return true }
        return canonicalPath(proof.modelPath) == canonicalPath(modelPath)
    }

    @discardableResult
    public static func recordVerifiedPNG(
        runtimeName: String,
        modelPath: String,
        outputURL: URL,
        settings: ImageGenSettings,
        directory: URL? = nil
    ) throws -> PNGVerification {
        let verification = try verifyPNG(
            at: outputURL,
            expectedWidth: settings.width,
            expectedHeight: settings.height
        )
        try record(
            Proof(
                runtimeName: runtimeName,
                modelPath: modelPath,
                outputPath: outputURL.path,
                width: verification.width,
                height: verification.height,
                steps: settings.steps,
                seed: settings.seed,
                pixelVariance: verification.pixelVariance
            ),
            directory: directory
        )
        return verification
    }

    public static func verifyPNG(
        at url: URL,
        expectedWidth: Int? = nil,
        expectedHeight: Int? = nil,
        minimumPixelVariance: Double = 1
    ) throws -> PNGVerification {
        let data = try Data(contentsOf: url)
        let signature = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].map(UInt8.init)
        guard data.count >= signature.count,
              Array(data.prefix(signature.count)) == signature
        else {
            throw VerificationFailure("not a PNG: \(url.path)")
        }

        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw VerificationFailure("could not decode PNG: \(url.path)")
        }

        let width = image.width
        let height = image.height
        if let expectedWidth, width != expectedWidth {
            throw VerificationFailure("PNG width \(width), expected \(expectedWidth)")
        }
        if let expectedHeight, height != expectedHeight {
            throw VerificationFailure("PNG height \(height), expected \(expectedHeight)")
        }
        guard width > 0, height > 0 else {
            throw VerificationFailure("PNG has invalid dimensions \(width)x\(height)")
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: &pixels,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw VerificationFailure("could not allocate PNG verification buffer")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var count = 0
        var mean = 0.0
        var m2 = 0.0
        for index in stride(from: 0, to: pixels.count, by: bytesPerPixel) {
            for channel in 0..<3 {
                count += 1
                let value = Double(pixels[index + channel])
                let delta = value - mean
                mean += delta / Double(count)
                m2 += delta * (value - mean)
            }
        }
        guard count > 0 else {
            throw VerificationFailure("PNG has no pixel samples")
        }
        let variance = m2 / Double(count)
        guard variance >= minimumPixelVariance else {
            throw VerificationFailure(
                String(format: "PNG appears blank; pixel variance %.4f", variance)
            )
        }
        return PNGVerification(
            width: width,
            height: height,
            pixelVariance: variance,
            byteCount: data.count
        )
        #else
        throw VerificationFailure("PNG verification requires CoreGraphics/ImageIO")
        #endif
    }

    private static func safeFilename(for runtimeName: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        let value = runtimeName.unicodeScalars.map { scalar -> String in
            allowed.contains(scalar) ? String(scalar) : "-"
        }.joined()
            .trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return value.isEmpty ? "unknown-runtime" : value
    }

    private static func canonicalPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}
