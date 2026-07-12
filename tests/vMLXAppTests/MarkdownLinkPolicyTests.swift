import XCTest
@testable import vMLXApp

final class MarkdownLinkPolicyTests: XCTestCase {
    func testAllowsHttpHttpsMailto() {
        XCTAssertNotNil(MarkdownLinkPolicy.sanitizedURL(from: "https://example.com/x"))
        XCTAssertNotNil(MarkdownLinkPolicy.sanitizedURL(from: "http://localhost:8080"))
        XCTAssertNotNil(MarkdownLinkPolicy.sanitizedURL(from: "mailto:user@example.com"))
        XCTAssertTrue(MarkdownLinkPolicy.isAllowed(URL(string: "https://example.com")!))
    }

    func testBlocksUnsafeSchemes() {
        XCTAssertNil(MarkdownLinkPolicy.sanitizedURL(from: "file:///etc/passwd"))
        XCTAssertNil(MarkdownLinkPolicy.sanitizedURL(from: "javascript:alert(1)"))
        XCTAssertNil(MarkdownLinkPolicy.sanitizedURL(from: "vmlx://local"))
        XCTAssertNil(MarkdownLinkPolicy.sanitizedURL(from: "data:text/html,hi"))
        XCTAssertNil(MarkdownLinkPolicy.sanitizedURL(from: ""))
        // Relative / scheme-less destinations are not opened from chat.
        XCTAssertNil(MarkdownLinkPolicy.sanitizedURL(from: "/etc/passwd"))
        XCTAssertNil(MarkdownLinkPolicy.sanitizedURL(from: "example.com/path"))
    }

    func testDisplayLabel() {
        let url = URL(string: "https://example.com/docs")!
        XCTAssertEqual(MarkdownLinkPolicy.displayLabel(for: url), "https://example.com/docs")
    }

    func testGoldenCorpusLinkPolicy() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        let url = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("e2e/fixtures/markdown-golden.json")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let policy = try XCTUnwrap(root["linkPolicy"] as? [String: Any])
        let allowed = try XCTUnwrap(policy["allowedExamples"] as? [String])
        let blocked = try XCTUnwrap(policy["blockedExamples"] as? [String])
        for example in allowed {
            XCTAssertNotNil(
                MarkdownLinkPolicy.sanitizedURL(from: example),
                "expected allow: \(example)"
            )
        }
        for example in blocked {
            XCTAssertNil(
                MarkdownLinkPolicy.sanitizedURL(from: example),
                "expected block: \(example)"
            )
        }
    }
}
