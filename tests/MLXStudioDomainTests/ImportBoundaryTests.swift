import Foundation
import XCTest

final class ImportBoundaryTests: XCTestCase {
    func testDomainSourcesImportFoundationOnly() throws {
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDirectory = repositoryRoot
            .appendingPathComponent("Sources/MLXStudioDomain", isDirectory: true)
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: sourceDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "swift" }

        XCTAssertFalse(sourceURLs.isEmpty)
        for sourceURL in sourceURLs {
            let source = try String(contentsOf: sourceURL, encoding: .utf8)
            let imports = source.split(separator: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter {
                $0.hasPrefix("import ") || ($0.hasPrefix("@") && $0.contains(" import "))
            }
            XCTAssertEqual(
                imports,
                ["import Foundation"],
                "\(sourceURL.lastPathComponent) crossed the Foundation-only boundary"
            )
        }
    }
}
