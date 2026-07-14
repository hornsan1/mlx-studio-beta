import XCTest
@testable import vMLXApp

/// Soft performance harness for the lightweight Markdown parser.
///
/// **Policy (see `docs/adr/001-markdown-parser-spike.md`):**
/// - Soft budgets are **guidelines**, not CI hard gates.
/// - Tests always **record** cold / cached timings via `XCTContext.runActivity`.
/// - Absolute times fail only when far beyond sanity ceilings (machine load /
///   debug builds vary widely). Prefer logging soft-budget misses over red CI.
/// - After ≥3 local runs on a named host class stabilize, budgets may tighten.
final class MarkdownPerformanceTests: XCTestCase {
    private let parser = LightweightMarkdownParser.shared

    // Soft guidelines (ms) from the design ADR — advisory only.
    private enum SoftBudget {
        static let gfm20KBColdMs = 30.0
        static let gfm20KBCachedMs = 5.0
        static let gfm100KBColdMs = 50.0
        // 1_000-line fence: parse proxy for first-paint; no multi-frame hitch target.
        static let code1000ColdMs = 100.0
    }

    /// Sanity ceilings: only fail CI if something is pathologically slow
    /// (debug + thermal / load). ~50–100× soft guidelines.
    private enum HardSanityCeiling {
        static let gfm20KBColdMs = 2_000.0
        static let gfm20KBCachedMs = 500.0
        static let gfm100KBColdMs = 5_000.0
        static let code1000ColdMs = 5_000.0
    }

    // MARK: - Fixtures

    private func gfmMix(targetBytes: Int) -> String {
        let unit = """
        ## Section

        Here is a **bold** claim with a [link](https://example.com/path) and `code`.

        - unordered item one
        - unordered item two
          - nested child

        1. ordered first
        2. ordered second

        > A short blockquote for texture.

        | Col A | Col B | Col C |
        | :---: | ----: | ----- |
        | alpha |  12.0 | note  |
        | beta  |  34.5 | more  |

        ```swift
        func sample(_ n: Int) -> Int {
            n * n + 1
        }
        ```

        ---

        """
        var out = ""
        out.reserveCapacity(targetBytes + unit.utf8.count)
        while out.utf8.count < targetBytes {
            out += unit
        }
        return out
    }

    private func codeFence(lineCount: Int) -> String {
        var lines: [String] = ["```python"]
        lines.reserveCapacity(lineCount + 2)
        for i in 0..<lineCount {
            lines.append("    result = compute_step(\(i), payload=data[\(i % 17)])  # line \(i)")
        }
        lines.append("```")
        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private struct ParseTiming {
        var coldMs: Double
        var cachedMs: Double
        var blockCount: Int
        var sourceBytes: Int
    }

    private func measureParse(_ source: String, label: String) -> ParseTiming {
        // Isolate from process-wide sync cache between fixtures.
        SyncMarkdownRenderCache.shared.removeAll()

        let coldStart = CFAbsoluteTimeGetCurrent()
        let coldDoc = parser.parse(source)
        let coldMs = (CFAbsoluteTimeGetCurrent() - coldStart) * 1_000

        // Warm + measure cached path through the production sync cache.
        let messageID = UUID()
        _ = MarkdownParserSupport.parseSync(source, messageID: messageID, parser: parser)
        let cachedStart = CFAbsoluteTimeGetCurrent()
        let cachedDoc = MarkdownParserSupport.parseSync(
            source,
            messageID: messageID,
            parser: parser
        )
        let cachedMs = (CFAbsoluteTimeGetCurrent() - cachedStart) * 1_000

        XCTAssertEqual(coldDoc.blocks.count, cachedDoc.blocks.count)
        XCTAssertFalse(coldDoc.blocks.isEmpty, "\(label): expected non-empty parse")

        return ParseTiming(
            coldMs: coldMs,
            cachedMs: cachedMs,
            blockCount: coldDoc.blocks.count,
            sourceBytes: source.utf8.count
        )
    }

    private func record(
        _ timing: ParseTiming,
        label: String,
        softCold: Double,
        softCached: Double?,
        hardCold: Double,
        hardCached: Double?
    ) {
        let softColdNote = timing.coldMs <= softCold ? "within" : "EXCEEDED"
        let softCachedNote: String
        if let softCached {
            softCachedNote = timing.cachedMs <= softCached ? "within" : "EXCEEDED"
        } else {
            softCachedNote = "n/a"
        }

        let summary = String(
            format: """
            [%@] bytes=%d blocks=%d cold=%.3fms (soft %.0fms %@) cached=%.3fms (soft %@ %@)
            """,
            label,
            timing.sourceBytes,
            timing.blockCount,
            timing.coldMs,
            softCold,
            softColdNote,
            timing.cachedMs,
            softCached.map { String(format: "%.0fms", $0) } ?? "—",
            softCachedNote
        )
        // Visible in `swift test` output; also attached to the activity.
        print(summary)

        XCTContext.runActivity(named: "Markdown perf: \(label)") { activity in
            let attachment = XCTAttachment(string: summary)
            attachment.name = "timings"
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }

        // Soft miss is recorded only — does not fail.
        if timing.coldMs > softCold {
            print("  soft-budget miss (cold): \(label) — not failing CI")
        }
        if let softCached, timing.cachedMs > softCached {
            print("  soft-budget miss (cached): \(label) — not failing CI")
        }

        // Hard sanity ceilings only.
        XCTAssertLessThan(
            timing.coldMs,
            hardCold,
            "\(label) cold parse \(timing.coldMs)ms exceeded sanity ceiling \(hardCold)ms"
        )
        if let hardCached {
            XCTAssertLessThan(
                timing.cachedMs,
                hardCached,
                "\(label) cached parse \(timing.cachedMs)ms exceeded sanity ceiling \(hardCached)ms"
            )
        }
    }

    // MARK: - Tests

    func testParse20KBGFMMixRecordsTimings() {
        let source = gfmMix(targetBytes: 20_000)
        XCTAssertGreaterThanOrEqual(source.utf8.count, 20_000)

        let timing = measureParse(source, label: "20KB-gfm-mix")
        record(
            timing,
            label: "20KB-gfm-mix",
            softCold: SoftBudget.gfm20KBColdMs,
            softCached: SoftBudget.gfm20KBCachedMs,
            hardCold: HardSanityCeiling.gfm20KBColdMs,
            hardCached: HardSanityCeiling.gfm20KBCachedMs
        )
    }

    func testParse100KBGFMMixRecordsTimings() {
        let source = gfmMix(targetBytes: 100_000)
        XCTAssertGreaterThanOrEqual(source.utf8.count, 100_000)

        let timing = measureParse(source, label: "100KB-gfm-mix")
        record(
            timing,
            label: "100KB-gfm-mix",
            softCold: SoftBudget.gfm100KBColdMs,
            softCached: nil,
            hardCold: HardSanityCeiling.gfm100KBColdMs,
            hardCached: nil
        )
    }

    func testParse1000LineCodeFenceRecordsTimings() {
        let source = codeFence(lineCount: 1_000)
        let timing = measureParse(source, label: "1000-line-code")

        // First-paint proxy: block construction cost + single closed code block.
        XCTAssertEqual(timing.blockCount, 1)
        if case let .code(_, body, _, isClosed) = parser.parse(source).blocks[0] {
            XCTAssertTrue(isClosed)
            let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            XCTAssertGreaterThanOrEqual(lines.count, 1_000)
        } else {
            XCTFail("expected a single code block")
        }

        record(
            timing,
            label: "1000-line-code",
            softCold: SoftBudget.code1000ColdMs,
            softCached: SoftBudget.gfm20KBCachedMs,
            hardCold: HardSanityCeiling.code1000ColdMs,
            hardCached: HardSanityCeiling.gfm20KBCachedMs
        )
    }

    func testDefaultCacheCapacityIs128() {
        XCTAssertEqual(MarkdownRenderCache.defaultCapacity, 128)
        // Fresh instances pick up the raised default (eviction = re-parse cost).
        let sync = SyncMarkdownRenderCache(capacity: MarkdownRenderCache.defaultCapacity)
        XCTAssertNotNil(sync)
    }

    func testParseSyncIsIdempotent() {
        SyncMarkdownRenderCache.shared.removeAll()
        let source = "## Warm me\n\nSome **text** and a list:\n- a\n- b\n"
        let messageID = UUID()
        let a = MarkdownParserSupport.parseSync(source, messageID: messageID)
        let b = MarkdownParserSupport.parseSync(source, messageID: messageID)
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.blocks.isEmpty)
    }

    func testRenderCacheKeyIncludesNormalizedSourceEquality() {
        let messageID = UUID()
        let first = MarkdownRenderCache.Key(
            messageID: messageID,
            source: "first",
            parserName: LightweightMarkdownParser.shared.name
        )
        let second = MarkdownRenderCache.Key(
            messageID: messageID,
            source: "second",
            parserName: LightweightMarkdownParser.shared.name
        )
        XCTAssertNotEqual(first, second)
    }
}
