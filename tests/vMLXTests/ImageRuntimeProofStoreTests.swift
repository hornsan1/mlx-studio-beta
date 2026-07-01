// SPDX-License-Identifier: Apache-2.0

import Foundation
import CoreGraphics
import ImageIO
import XCTest
@testable import vMLXEngine

final class ImageRuntimeProofStoreTests: XCTestCase {
    func testRecordVerifiedPNGUsesRealOutputArtifact() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("real.png")
        try writePNG(output, width: 256, height: 256, pattern: .checkerboard)

        let verification = try ImageRuntimeProofStore.recordVerifiedPNG(
            runtimeName: "flux1-schnell",
            modelPath: "/tmp/model",
            outputURL: output,
            settings: ImageGenSettings(width: 256, height: 256, seed: 7),
            directory: dir
        )

        XCTAssertEqual(verification.width, 256)
        XCTAssertEqual(verification.height, 256)
        XCTAssertGreaterThan(verification.pixelVariance, 1)
        XCTAssertTrue(ImageRuntimeProofStore.isVerified(runtimeName: "flux1-schnell", directory: dir))
    }

    func testVerifyPNGRejectsBlankOutput() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("blank.png")
        try writePNG(output, width: 256, height: 256, pattern: .solid)

        XCTAssertThrowsError(
            try ImageRuntimeProofStore.verifyPNG(
                at: output,
                expectedWidth: 256,
                expectedHeight: 256
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("blank"))
        }
    }

    func testVerifyPNGRejectsWrongDimensions() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("wrong-size.png")
        try writePNG(output, width: 256, height: 256, pattern: .checkerboard)

        XCTAssertThrowsError(
            try ImageRuntimeProofStore.verifyPNG(
                at: output,
                expectedWidth: 512,
                expectedHeight: 256
            )
        ) { error in
            XCTAssertTrue(String(describing: error).contains("width"))
        }
    }

    func testRecordsAndReadsRuntimeProof() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("out.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: output)

        let proof = ImageRuntimeProofStore.Proof(
            runtimeName: "flux1-schnell",
            modelPath: "/tmp/model",
            outputPath: output.path,
            width: 256,
            height: 256,
            steps: 1,
            seed: 7,
            pixelVariance: 42.5,
            verifiedAt: Date(timeIntervalSinceReferenceDate: 100)
        )

        try ImageRuntimeProofStore.record(proof, directory: dir)

        XCTAssertEqual(
            ImageRuntimeProofStore.latestProof(runtimeName: "flux1-schnell", directory: dir),
            proof
        )
        XCTAssertTrue(ImageRuntimeProofStore.isVerified(runtimeName: "flux1-schnell", directory: dir))
        XCTAssertTrue(
            ImageRuntimeProofStore.isVerified(
                runtimeName: "flux1-schnell",
                modelPath: "/tmp/model",
                directory: dir
            )
        )
        XCTAssertFalse(
            ImageRuntimeProofStore.isVerified(
                runtimeName: "flux1-schnell",
                modelPath: "/tmp/other-model",
                directory: dir
            )
        )
    }

    func testLowVarianceProofDoesNotCountAsVerified() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let output = dir.appendingPathComponent("blank.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: output)

        try ImageRuntimeProofStore.record(
            ImageRuntimeProofStore.Proof(
                runtimeName: "flux1-schnell",
                modelPath: "/tmp/model",
                outputPath: output.path,
                width: 256,
                height: 256,
                steps: 1,
                seed: 7,
                pixelVariance: 0.1
            ),
            directory: dir
        )

        XCTAssertFalse(ImageRuntimeProofStore.isVerified(runtimeName: "flux1-schnell", directory: dir))
    }

    func testMissingOutputFileProofDoesNotCountAsVerified() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try ImageRuntimeProofStore.record(
            ImageRuntimeProofStore.Proof(
                runtimeName: "flux1-schnell",
                modelPath: "/tmp/model",
                outputPath: dir.appendingPathComponent("missing.png").path,
                width: 256,
                height: 256,
                steps: 1,
                seed: 7,
                pixelVariance: 42
            ),
            directory: dir
        )

        XCTAssertFalse(ImageRuntimeProofStore.isVerified(runtimeName: "flux1-schnell", directory: dir))
    }

    func testRuntimeNameIsSanitizedForProofFilename() {
        let dir = URL(fileURLWithPath: "/tmp/proofs", isDirectory: true)
        let url = ImageRuntimeProofStore.proofURL(
            runtimeName: "../FLUX 1/Schnell",
            directory: dir
        )

        XCTAssertEqual(url.lastPathComponent, "FLUX-1-Schnell.json")
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmlx-image-proof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private enum PNGPattern {
        case checkerboard
        case solid
    }

    private func writePNG(
        _ url: URL,
        width: Int,
        height: Int,
        pattern: PNGPattern
    ) throws {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let value: UInt8
                switch pattern {
                case .checkerboard:
                    value = ((x / 16 + y / 16) % 2 == 0) ? 0 : 255
                case .solid:
                    value = 32
                }
                pixels[offset] = value
                pixels[offset + 1] = value
                pixels[offset + 2] = value
                pixels[offset + 3] = 255
            }
        }

        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                "public.png" as CFString,
                1,
                nil
              )
        else {
            throw NSError(
                domain: "ImageRuntimeProofStoreTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not create PNG fixture"]
            )
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw NSError(
                domain: "ImageRuntimeProofStoreTests",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not write PNG fixture"]
            )
        }
    }
}
