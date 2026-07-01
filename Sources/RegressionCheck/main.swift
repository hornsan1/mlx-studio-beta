// SPDX-License-Identifier: Apache-2.0
//
// XCTest-free regression harness — `swift run regression-check`.
//
// WHY THIS EXISTS: some CI / dev environments have Xcode CommandLineTools
// only (no Xcode.app), where `XCTest` is absent and `swift test` fails with
// "no such module 'XCTest'". This harness re-asserts the same engine-logic
// invariants the XCTest suites cover, using plain assertions so it runs
// anywhere `swift build` works. It backs the fixes recorded in
// REVIEW-2026-07-01.md (HIGH-1, HIGH-2, HIGH-5, MED-14 + resolver precedence).
//
// Exit code 0 = all checks passed; non-zero = at least one failed.

import Foundation
import vMLXEngine
import vMLXServer
import vMLXTheme
import vMLXFluxKit
import MLX

var failures = 0
var total = 0
func check(_ cond: Bool, _ msg: String) {
    total += 1
    if cond { print("  ok  \(msg)") }
    else { print("  FAIL \(msg)"); failures += 1 }
}
func section(_ name: String) { print("\n▸ \(name)") }

func tempDB() -> SettingsDB {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("vmlx-regression-\(UUID()).sqlite3")
    return SettingsDB(customPath: url)
}

// ── HIGH-1: chat-tier sampling folds into resolved settings ──────────────
// Proves ChatViewModel.send()'s use of `resolved.settings.default*` carries
// the per-chat ChatSettingsPopover slider values (the sliders are NOT inert).
func high1_chatTierFold() async {
    section("HIGH-1 — chat-tier sampling folds into resolved settings")
    let store = SettingsStore(database: tempDB())
    let chatId = UUID()
    var c = ChatSettings()
    c.temperature = 1.7; c.topP = 0.42; c.topK = 11; c.maxTokens = 4242
    await store.setChat(chatId, c)

    let r = await store.resolved(sessionId: nil, chatId: chatId, request: nil)
    check(abs(r.temperature - 1.7) < 1e-9, "chat temperature reaches resolved.temperature")
    check(r.settings.defaultTopP == 0.42, "chat topP folds into settings")
    check(r.settings.defaultTopK == 11, "chat topK folds into settings")
    check(r.settings.defaultMaxTokens == 4242, "chat maxTokens folds into settings")
    check(r.resolutionTrace["defaultTemperature"] == .chat, "trace attributes temperature to .chat")

    // chat beats session for the same field
    let store2 = SettingsStore(database: tempDB())
    let sid = UUID(); let cid = UUID()
    var s = SessionSettings(modelPath: URL(fileURLWithPath: "/dev/null")); s.defaultTemperature = 0.6
    await store2.setSession(sid, s)
    var cc = ChatSettings(); cc.temperature = 1.25
    await store2.setChat(cid, cc)
    let r2 = await store2.resolved(sessionId: sid, chatId: cid, request: nil)
    check(abs(r2.temperature - 1.25) < 1e-9, "chat tier beats session tier")
    check(r2.resolutionTrace["defaultTemperature"] == .chat, "trace says .chat when both set")
}

// ── Resolver precedence sanity: request > session > global ───────────────
func resolverPrecedence() async {
    section("Resolver precedence — request > session > global")
    let store = SettingsStore(database: tempDB())
    let sid = UUID()
    var s = SessionSettings(modelPath: URL(fileURLWithPath: "/dev/null")); s.defaultTemperature = 0.9
    await store.setSession(sid, s)
    let override = RequestOverride(
        temperature: 0.1, topP: nil, topK: nil, minP: nil,
        repetitionPenalty: nil, maxTokens: nil, systemPrompt: nil,
        stopSequences: nil, enableThinking: nil, reasoningEffort: nil,
        toolChoice: nil, tools: nil)
    let r = await store.resolved(sessionId: sid, request: override)
    check(abs(r.temperature - 0.1) < 1e-9, "request beats session")
    check(r.resolutionTrace["defaultTemperature"] == .request, "trace says .request")

    let bare = await store.resolved()
    check(bare.resolutionTrace["defaultTemperature"] == .global, "untouched traces to .global")
}

// ── HIGH-2: per-session cache overrides reach LoadOptions ────────────────
// setupCacheCoordinator now reads `opts` (LoadOptions(from: resolved)), so
// per-session cache config must survive resolution.
func high2_cacheOptions() async {
    section("HIGH-2 — per-session cache overrides reach LoadOptions")
    let store = SettingsStore(database: tempDB())
    let sid = UUID()
    var s = SessionSettings(modelPath: URL(fileURLWithPath: "/dev/null"))
    s.maxCacheBlocks = 123; s.pagedCacheBlockSize = 256
    s.memoryCachePercent = 0.55; s.memoryCacheTTLMinutes = 7
    s.diskCacheMaxGB = 33; s.enableDiskCache = true
    await store.setSession(sid, s)

    let resolved = await store.resolved(sessionId: sid, chatId: nil, request: nil)
    let opts = Engine.LoadOptions(modelPath: URL(fileURLWithPath: "/dev/null"), from: resolved)
    check(opts.maxCacheBlocks == 123, "maxCacheBlocks reaches opts")
    check(opts.pagedCacheBlockSize == 256, "pagedCacheBlockSize reaches opts")
    check(abs(opts.memoryCachePercent - 0.55) < 1e-9, "memoryCachePercent reaches opts")
    check(abs(opts.memoryCacheTTLMinutes - 7) < 1e-9, "memoryCacheTTLMinutes reaches opts")
    check(abs(opts.diskCacheMaxGB - 33) < 1e-9, "diskCacheMaxGB reaches opts")
    check(opts.enableDiskCache, "enableDiskCache reaches opts")

    // Defaults agree with bare construction when nothing overrides.
    let bare = Engine.LoadOptions(modelPath: URL(fileURLWithPath: "/dev/null"))
    let dflt = Engine.LoadOptions(modelPath: URL(fileURLWithPath: "/dev/null"),
                                  from: await store.resolved())
    check(dflt.usePagedCache == bare.usePagedCache, "usePagedCache default matches bare")
    check(dflt.pagedCacheBlockSize == bare.pagedCacheBlockSize, "pagedCacheBlockSize default matches bare")
}

// ── HIGH-5: corsOrigins is the single CORS source (session-foldable) ─────
func high5_corsOrigins() async {
    section("HIGH-5 — corsOrigins resolves (single CORS source)")
    let store = SettingsStore(database: tempDB())
    let sid = UUID()
    var s = SessionSettings(modelPath: URL(fileURLWithPath: "/dev/null"))
    s.corsOrigins = ["https://example.com", "https://app.com"]
    await store.setSession(sid, s)
    let r = await store.resolved(sessionId: sid)
    check(r.settings.corsOrigins == ["https://example.com", "https://app.com"],
          "session corsOrigins folds into resolved (the field CORS binding reads)")
}

// ── MED-14: clipboard import forces skipSecurityValidation = false ───────
func med14_clipboardSecurity() {
    section("MED-14 — clipboard import cannot enable skip_security_validation")
    let json = """
    { "mcpServers": {
        "evil": { "command": "sh", "args": ["-c","echo hi"],
                  "skip_security_validation": true }
    } }
    """
    do {
        let result = try MCPClipboardImport.parse(json: json)
        // The server may be imported or skipped by validation, but if
        // imported it MUST NOT carry skipSecurityValidation = true.
        let anyBypassed = result.servers.contains { $0.skipSecurityValidation }
        check(!anyBypassed, "pasted skip_security_validation:true is forced to false")
    } catch {
        // A throw (rejected outright) is also an acceptable safe outcome.
        check(true, "clipboard import rejected the entry (\(error))")
    }
}

// ── MED-13: gateway /v1/completions returns 501 (LIVE HTTP) ──────────────
// Boots a real GatewayServer (model-less — the 501 fires before any engine
// work) on a loopback port and verifies the route over HTTP end-to-end.
func med13_gatewayCompletions501() async {
    section("MED-13 — gateway /v1/completions → 501 (live HTTP)")
    let engine = Engine()
    let port = 18917
    let gw = GatewayServer(
        host: "127.0.0.1", port: port,
        defaultEngine: engine,
        resolver: { _ in nil },
        enumerate: { [] })
    let serverTask = Task { try? await gw.run() }
    let base = "http://127.0.0.1:\(port)"

    // Wait for the listener to come up (poll the info route).
    var up = false
    for _ in 0..<60 {
        if let (_, resp) = try? await URLSession.shared.data(
            from: URL(string: base + "/v1/_gateway/info")!),
           (resp as? HTTPURLResponse)?.statusCode == 200 { up = true; break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    check(up, "gateway booted; /v1/_gateway/info responds 200")
    guard up else { serverTask.cancel(); return }

    // POST /v1/completions must be 501 (not a wrong-shaped 200).
    var req = URLRequest(url: URL(string: base + "/v1/completions")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = Data(#"{"model":"x","prompt":"hi"}"#.utf8)
    if let (data, resp) = try? await URLSession.shared.data(for: req) {
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        check(code == 501, "POST /v1/completions → 501 (got \(code))")
        let body = String(data: data, encoding: .utf8) ?? ""
        check(body.contains("per-session"), "501 body directs to the per-session port")
    } else {
        check(false, "POST /v1/completions request failed")
    }

    // Info route lists it as unsupported.
    if let (data, _) = try? await URLSession.shared.data(
        from: URL(string: base + "/v1/_gateway/info")!) {
        // The serializer escapes "/" as "\/", so match on the distinctive
        // phrase from the unsupported-list entry instead of the raw path.
        let body = String(data: data, encoding: .utf8) ?? ""
        check(body.contains("unsupported_in_gateway") && body.contains("legacy text-completion"),
              "/v1/_gateway/info lists the legacy completions endpoint as unsupported")
    } else {
        check(false, "GET /v1/_gateway/info request failed")
    }
    serverTask.cancel()
}

// ── HIGH-3 (server contract): /v1/audio/speech advertises the real
// backend via X-vMLX-TTS-Backend. The in-app TTS button reads this header
// to label output honestly. PlaceholderSynth needs no model, so this is
// testable live. ─────────────────────────────────────────────────────────
func high3_ttsBackendHeader() async {
    section("HIGH-3 — /v1/audio/speech advertises X-vMLX-TTS-Backend (live HTTP)")
    let engine = Engine()
    let port = 18919
    let server = Server(engine: engine, host: "127.0.0.1", port: port)
    let task = Task { try? await server.run() }
    let base = "http://127.0.0.1:\(port)"

    var up = false
    for _ in 0..<60 {
        if let (_, resp) = try? await URLSession.shared.data(from: URL(string: base + "/health")!),
           (resp as? HTTPURLResponse)?.statusCode == 200 { up = true; break }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    check(up, "server booted; /health responds 200")
    guard up else { task.cancel(); return }

    var req = URLRequest(url: URL(string: base + "/v1/audio/speech")!)
    req.httpMethod = "POST"
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = Data(#"{"model":"kokoro","input":"hello","voice":"af_heart","response_format":"wav"}"#.utf8)
    if let (_, resp) = try? await URLSession.shared.data(for: req),
       let http = resp as? HTTPURLResponse {
        let backend = http.value(forHTTPHeaderField: "X-vMLX-TTS-Backend") ?? ""
        check(http.statusCode == 200, "TTS speech returns 200 (got \(http.statusCode))")
        check(backend.hasPrefix("placeholder"),
              "X-vMLX-TTS-Backend advertises placeholder tone (got '\(backend)') — the header the UI honesty fix reads")
    } else {
        check(false, "POST /v1/audio/speech request failed")
    }
    task.cancel()
}

// ── LOW-18: Engine.clearMCP() runs without error (disables MCP) ──────────
func low18_clearMCP() async {
    section("LOW-18 — Engine.clearMCP() executes (--no-mcp path)")
    let engine = Engine()
    await engine.clearMCP()
    check(true, "Engine.clearMCP() completed without error")
}

// ── HIGH-4 / MED-9 / MED-10: user-facing copy (the substance of the three
// UI fixes) is centralized in vMLXTheme.AppCopy and consumed by the SwiftUI
// views. The views can't render headlessly, but the copy is asserted here
// with semantic properties so a revert (e.g. back to "Built-in Tools") fails.
func uiCopyChecks() {
    section("HIGH-4/MED-9/MED-10 — user-facing copy (asserted values)")
    // HIGH-4: product name converged on "MLX Studio" (vMLX = runtime only).
    check(AppCopy.productName == "MLX Studio", "HIGH-4: product name is 'MLX Studio'")
    check(!AppCopy.productName.lowercased().contains("vmlx"), "HIGH-4: product name is not the runtime name 'vMLX'")

    // MED-10: tools toggle is the honest master-switch label, not the old
    // misleading "Built-in Tools", and the footnote explains the dependency.
    check(AppCopy.allowToolCallingLabel == "Allow tool calling", "MED-10: toggle label is 'Allow tool calling'")
    check(!AppCopy.allowToolCallingLabel.lowercased().contains("built-in"), "MED-10: dropped the misleading 'Built-in Tools' wording")
    check(AppCopy.allowToolCallingFootnote.contains("Shell") && AppCopy.allowToolCallingFootnote.contains("MCP"),
          "MED-10: footnote explains tools come from Shell + MCP")

    // MED-9: sliding-window controls are labeled as not-yet-wired, and the
    // caption states Long/Bounded have no effect yet.
    check(AppCopy.slidingWindowSessionLabel.lowercased().contains("not") &&
          AppCopy.slidingWindowSessionLabel.lowercased().contains("wired"),
          "MED-9: session picker label flags 'not yet wired'")
    check(AppCopy.slidingWindowTrayLabel.lowercased().contains("not"), "MED-9: tray label flags not-wired")
    check(AppCopy.slidingWindowCaption.lowercased().contains("no effect"),
          "MED-9: caption states Long/Bounded have no effect yet")
}

// ── MED-8: Flux axial RoPE is a correct rotation (finding "RoPE never
// applied"). Validates the exact-angle rotation, position-0 identity, and
// norm preservation — no model weights needed. ──────────────────────────
func med8_fluxRoPE() {
    section("MED-8 — Flux axial RoPE correctness (no weights)")
    // headDim=4, axes [0,2,2]; seq = [txt(pos0), img(0,0), img(1,0)].
    let rope = FluxRoPE(headDim: 4, textLen: 1, latentH: 2, latentW: 1,
                        theta: 10_000, axesDim: [0, 2, 2])
    check(rope.seqLen == 3, "sequence length = textLen + H*W (got \(rope.seqLen))")

    // Input: distinct value per (token, dim) so rotations are observable.
    let x = MLXArray([
        1.0, 2.0, 3.0, 4.0,   // token0 (text, pos 0 → identity)
        5.0, 6.0, 7.0, 8.0,   // token1 (img 0,0 → all pos 0 → identity)
        9.0, 10.0, 11.0, 12.0 // token2 (img 1,0 → axis1 pos=1 rotates pair0)
    ] as [Float]).reshaped([1, 1, 3, 4])
    let y = rope.apply(x)
    func at(_ l: Int, _ d: Int) -> Float { y[0, 0, l, d].item(Float.self) }

    // token0 & token1 are at position 0 on every axis → identity.
    check(abs(at(0,0)-1) < 1e-5 && abs(at(0,3)-4) < 1e-5, "text token (pos 0) is unrotated (identity)")
    check(abs(at(1,0)-5) < 1e-5 && abs(at(1,3)-8) < 1e-5, "img token at (0,0) is unrotated (identity)")

    // token2: pair0 (axis1, pos=1, omega=1) rotates (9,10) by angle 1.0;
    // pair1 (axis2, pos=0) is identity.
    let c = cosf(1.0), s = sinf(1.0)
    let e0 = 9*c - 10*s, e1 = 9*s + 10*c
    check(abs(at(2,0)-e0) < 1e-4 && abs(at(2,1)-e1) < 1e-4,
          "img token pair0 rotated by exact angle pos·omega=1.0 (ref \(e0),\(e1))")
    check(abs(at(2,2)-11) < 1e-5 && abs(at(2,3)-12) < 1e-5, "img token pair1 (axis2 pos0) is identity")

    // Norm preservation (defining property of a rotation), per token.
    func norm(_ l: Int, _ src: (Int,Int)->Float) -> Float {
        (0..<4).map { let v = src(l,$0); return v*v }.reduce(0,+).squareRoot()
    }
    let inNorm = norm(2) { _,d in [9.0,10,11,12][d] }
    let outNorm = norm(2) { l,d in at(l,d) }
    check(abs(inNorm - outNorm) < 1e-3, "rotation preserves vector norm (\(inNorm) ≈ \(outNorm))")
}

// ── MED-7: Z-Image text conditioning is actually consumed (was zeroed →
// prompt-independent). Prove the adapter is non-zero AND prompt-dependent,
// with synthetic encoder outputs — no weights needed. ────────────────────
func med7_textConditioning() {
    section("MED-7 — Z-Image text conditioning is prompt-dependent (no weights)")
    let s = 4, e = 8
    let promptA = MLXArray((0..<(s*e)).map { Float($0) + 1 }).reshaped([1, s, e])
    let promptB = MLXArray((0..<(s*e)).map { Float($0) * -2 - 1 }).reshaped([1, s, e])
    let (ta, pa) = TextConditioningAdapter.adapt(encoderOut: promptA, nTxt: 6, textDim: 12, pooledDim: 5)
    let (tb, pb) = TextConditioningAdapter.adapt(encoderOut: promptB, nTxt: 6, textDim: 12, pooledDim: 5)

    check(ta.shape == [1, 6, 12], "txt adapted to (1, nTxt, textDim) (got \(ta.shape))")
    check(pa.shape == [1, 5], "pooled adapted to (1, pooledDim) (got \(pa.shape))")
    let nonZero = abs(sum(ta).item(Float.self)) + abs(sum(pa).item(Float.self))
    check(nonZero > 0, "conditioning is non-zero (not the old zeroed embedding)")
    let dTxt = sum(abs(ta - tb)).item(Float.self)
    let dPooled = sum(abs(pa - pb)).item(Float.self)
    check(dTxt > 1e-3, "different prompts → different txt embedding (Δ=\(dTxt))")
    check(dPooled > 1e-3, "different prompts → different pooled vector (Δ=\(dPooled))")
    check(abs(ta[0, 0, 0].item(Float.self) - 1) < 1e-5, "encoder feature preserved into conditioning")
}

med7_textConditioning()
med8_fluxRoPE()
uiCopyChecks()
await high1_chatTierFold()
await resolverPrecedence()
await high2_cacheOptions()
await high5_corsOrigins()
med14_clipboardSecurity()
await med13_gatewayCompletions501()
await high3_ttsBackendHeader()
await low18_clearMCP()

print("\n\(total - failures)/\(total) checks passed.")
print(failures == 0 ? "REGRESSION CHECK: PASS" : "REGRESSION CHECK: FAIL (\(failures))")
exit(failures == 0 ? 0 : 1)
