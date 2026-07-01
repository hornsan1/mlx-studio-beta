// SPDX-License-Identifier: Apache-2.0
//
// AppCopy — canonical user-facing copy for the fixes in REVIEW-2026-07-01.md
// (HIGH-4 branding, MED-9 sliding-window honesty, MED-10 tools-toggle clarity).
//
// These strings live in the shared `vMLXTheme` library (not inline in the
// SwiftUI executable) specifically so they can be asserted by the
// XCTest-free `regression-check` harness — the SwiftUI views themselves can't
// be rendered headlessly, but their copy IS the substance of those findings,
// and centralizing it here makes it behaviorally testable + guards against
// regressions (e.g. reverting to the old misleading "Built-in Tools" label).
public enum AppCopy {

    /// HIGH-4 — the single user-facing product name. "vMLX" remains the
    /// baked-in runtime/engine + CLI name; the shipped app is "MLX Studio".
    public static let productName = "MLX Studio"

    // MED-10 — the tool-calling master switch (was the misleading
    // "Built-in Tools Enabled", which looked like it added tools itself).
    public static let allowToolCallingLabel = "Allow tool calling"
    public static let allowToolCallingFootnote =
        "Master switch that lets the model call tools. The available tools come from the Shell tool (above) and any connected MCP servers — enable Shell and/or configure MCP for this to have an effect."

    // MED-9 — sliding-window controls are not yet consumed by the Swift
    // engine; label them honestly (mirrors the "Smelt mode (Python engine
    // only)" convention) instead of implying Long/Bounded do something.
    public static let slidingWindowSessionLabel = "Sliding window (not yet wired)"
    public static let slidingWindowTrayLabel = "Sliding window (not wired)"
    public static let slidingWindowCaption =
        "Not yet wired in the Swift engine: the model's own config window is always used (equivalent to Auto). Long / Bounded persist but currently have no effect."
}
