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
        XCTAssertNil(MarkdownLinkPolicy.sanitizedURL(from: "https:"))
        XCTAssertNil(MarkdownLinkPolicy.sanitizedURL(from: "http://"))
        XCTAssertNil(MarkdownLinkPolicy.sanitizedURL(from: "https:///etc/passwd"))
        XCTAssertNil(MarkdownLinkPolicy.sanitizedURL(from: "mailto:"))
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

    // MARK: - sanitizeLinks + allow/block matrix (K7)

    func testSanitizeLinksStripsDisallowedSchemes() throws {
        // Build attributed strings via markdown so link attributes exist.
        let unsafe = try XCTUnwrap(
            try? AttributedString(
                markdown: "[x](javascript:alert(1)) [y](file:///etc/passwd) [z](vmlx://local)",
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        )
        // Precondition: parser attached some link attributes.
        let hadAnyLink = unsafe.runs.contains { $0.link != nil }
        XCTAssertTrue(hadAnyLink, "fixture should produce link attributes")

        let cleaned = MarkdownOpenURL.sanitizeLinks(unsafe)
        for run in cleaned.runs {
            if let url = run.link {
                XCTFail("disallowed link should be stripped, found \(url)")
            }
        }
    }

    func testSanitizeLinksKeepsAllowedSchemes() throws {
        let safe = try XCTUnwrap(
            try? AttributedString(
                markdown: "[a](https://example.com) [b](http://localhost) [c](mailto:u@example.com)",
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        )
        let cleaned = MarkdownOpenURL.sanitizeLinks(safe)
        var schemes: Set<String> = []
        for run in cleaned.runs {
            if let url = run.link, let scheme = url.scheme?.lowercased() {
                schemes.insert(scheme)
            }
        }
        XCTAssertEqual(schemes, Set(["https", "http", "mailto"]))
    }

    func testSanitizeLinksMixedKeepsOnlyAllowed() throws {
        let mixed = try XCTUnwrap(
            try? AttributedString(
                markdown: "[ok](https://example.com/docs) [bad](javascript:void(0))",
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            )
        )
        let cleaned = MarkdownOpenURL.sanitizeLinks(mixed)
        var kept: [URL] = []
        for run in cleaned.runs {
            if let url = run.link {
                kept.append(url)
            }
        }
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.scheme?.lowercased(), "https")
        XCTAssertTrue(MarkdownLinkPolicy.isAllowed(kept[0]))
    }

    func testMarkdownAttributedInlineSanitizes() {
        let attr = MarkdownAttributed.inline("[go](javascript:alert(1)) plain")
        XCTAssertNotNil(attr)
        if let attr {
            for run in attr.runs {
                XCTAssertNil(run.link, "inline helper must strip unsafe links")
            }
        }
    }

    func testMarkdownAttributedInlineStripsImageURLAttributes() throws {
        let source = """
        ![local](file:///etc/passwd)
        ![remote](https://example.com/image.png)
        ![data](data:image/png;base64,AAAA)
        ![custom](vmlx://local/image)
        """
        let attributed = try XCTUnwrap(MarkdownAttributed.inline(source))
        for run in attributed.runs {
            XCTAssertNil(
                run[MarkdownImageURLAttribute.self],
                "model-provided Markdown images must not retain URL attributes"
            )
        }
    }

    func testIsAllowedDecisionMatrix() {
        let cases: [(String, Bool)] = [
            ("https://example.com", true),
            ("http://127.0.0.1:8080/x", true),
            ("mailto:a@b.c", true),
            ("https:", false),
            ("http://", false),
            ("https:///etc/passwd", false),
            ("mailto:", false),
            ("file:///tmp/x", false),
            ("javascript:alert(1)", false),
            ("data:text/html,hi", false),
            ("vmlx://session", false),
            ("ftp://example.com", false),
            ("ssh://host", false),
        ]
        for (raw, expect) in cases {
            guard let url = URL(string: raw) else {
                XCTFail("could not form URL for \(raw)")
                continue
            }
            XCTAssertEqual(
                MarkdownLinkPolicy.isAllowed(url),
                expect,
                "isAllowed(\(raw))"
            )
        }
    }
}
