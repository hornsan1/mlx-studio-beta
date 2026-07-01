// SPDX-License-Identifier: Apache-2.0
//
// REVIEW-2026-07-01 HIGH-2 regression guard.
//
// `Engine.setupCacheCoordinator` used to read cache configuration from
// `settings.global()`, silently dropping per-session overrides that
// SessionConfigForm writes to the session tier. The fix threads the
// resolved per-session snapshot through `LoadOptions(from:)` and has the
// coordinator read `opts`. This test locks the plumbing: per-session cache
// overrides must survive resolution into LoadOptions.

import XCTest
@testable import vMLXEngine

final class LoadOptionsCacheResolutionTests: XCTestCase {

    private func tempDBPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("vmlx-cacheopts-\(UUID()).sqlite3")
    }

    func testSessionCacheOverridesReachLoadOptions() async throws {
        let url = tempDBPath()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SettingsStore(database: SettingsDB(customPath: url))

        let sid = UUID()
        var s = SessionSettings(modelPath: URL(fileURLWithPath: "/dev/null"))
        s.maxCacheBlocks = 123
        s.pagedCacheBlockSize = 256
        s.memoryCachePercent = 0.55
        s.memoryCacheTTLMinutes = 7
        s.diskCacheMaxGB = 33
        s.enableDiskCache = true
        await store.setSession(sid, s)

        let resolved = await store.resolved(sessionId: sid, chatId: nil, request: nil)
        let opts = Engine.LoadOptions(
            modelPath: URL(fileURLWithPath: "/dev/null"), from: resolved)

        XCTAssertEqual(opts.maxCacheBlocks, 123)
        XCTAssertEqual(opts.pagedCacheBlockSize, 256)
        XCTAssertEqual(opts.memoryCachePercent, 0.55, accuracy: 1e-9)
        XCTAssertEqual(opts.memoryCacheTTLMinutes, 7, accuracy: 1e-9)
        XCTAssertEqual(opts.diskCacheMaxGB, 33, accuracy: 1e-9)
        XCTAssertTrue(opts.enableDiskCache)
    }

    /// When nothing overrides at the session tier, LoadOptions carries the
    /// compiled-in defaults (mirrors GlobalSettings) — bare construction and
    /// resolved construction agree.
    func testDefaultsMatchGlobalWhenNoSessionOverride() async throws {
        let url = tempDBPath()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = SettingsStore(database: SettingsDB(customPath: url))

        let resolved = await store.resolved()
        let opts = Engine.LoadOptions(
            modelPath: URL(fileURLWithPath: "/dev/null"), from: resolved)
        let bare = Engine.LoadOptions(modelPath: URL(fileURLWithPath: "/dev/null"))

        XCTAssertEqual(opts.usePagedCache, bare.usePagedCache)
        XCTAssertEqual(opts.pagedCacheBlockSize, bare.pagedCacheBlockSize)
        XCTAssertEqual(opts.memoryCachePercent, bare.memoryCachePercent, accuracy: 1e-9)
        XCTAssertEqual(opts.memoryCacheTTLMinutes, bare.memoryCacheTTLMinutes, accuracy: 1e-9)
    }
}
