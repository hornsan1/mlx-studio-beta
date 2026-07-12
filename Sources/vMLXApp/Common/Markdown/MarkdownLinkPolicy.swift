import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Safe-open policy for Markdown links.
///
/// External destinations require user activation. Only an explicit scheme
/// allowlist is permitted; `file:`, custom schemes, and automatic remote
/// media loads are blocked.
enum MarkdownLinkPolicy {
    /// Schemes the user may open after an explicit activation (click / VoiceOver).
    static let allowedSchemes: Set<String> = ["https", "http", "mailto"]

    /// Normalize and validate a link destination from Markdown.
    /// Returns `nil` when the URL is missing, malformed, or disallowed.
    static func sanitizedURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Reject obvious path-style local references used as schemes.
        if trimmed.hasPrefix("file:"),
           !trimmed.lowercased().hasPrefix("file://") {
            return nil
        }

        guard let url = URL(string: trimmed) ?? URL(string: trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? trimmed) else {
            return nil
        }
        return isAllowed(url) ? url : nil
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            // Scheme-less relative URLs are not opened — chat has no base document.
            return false
        }
        return allowedSchemes.contains(scheme)
    }

    /// Human-readable destination for hover / accessibility context.
    static func displayLabel(for url: URL) -> String {
        if url.scheme?.lowercased() == "mailto" {
            return url.absoluteString
        }
        return url.absoluteString
    }

    /// Open only when the URL passes the allowlist. Call only from user actions.
    @discardableResult
    static func openUserActivated(_ url: URL) -> Bool {
        guard isAllowed(url) else { return false }
        #if canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #else
        return false
        #endif
    }

    /// Convenience for raw strings from Markdown link destinations.
    @discardableResult
    static func openUserActivated(raw: String) -> Bool {
        guard let url = sanitizedURL(from: raw) else { return false }
        return openUserActivated(url)
    }
}

// MARK: - OpenURL gate (all AttributedString markdown surfaces)

/// Shared link open path for every SwiftUI surface that renders Markdown
/// via `AttributedString`. Always pair with `sanitizeLinks` so disallowed
/// destinations are stripped even if the environment action is bypassed.
enum MarkdownOpenURL {
    /// Environment action: allow only `https` / `http` / `mailto`.
    static var action: OpenURLAction {
        OpenURLAction { url in
            guard MarkdownLinkPolicy.isAllowed(url) else { return .discarded }
            return MarkdownLinkPolicy.openUserActivated(url) ? .handled : .discarded
        }
    }

    /// Strip link attributes whose URL fails the allowlist so click targets
    /// cannot open unsafe schemes. Hard guarantee independent of `openURL`.
    static func sanitizeLinks(_ attributed: AttributedString) -> AttributedString {
        var result = attributed
        // Collect ranges first — mutating while iterating runs is unsafe.
        var disallowed: [Range<AttributedString.Index>] = []
        for run in result.runs {
            guard let url = run.link else { continue }
            if !MarkdownLinkPolicy.isAllowed(url) {
                disallowed.append(run.range)
            }
        }
        for range in disallowed {
            result[range].link = nil
        }
        return result
    }
}

// MARK: - Inline AttributedString helper

/// Builds inline Markdown `AttributedString` values with disallowed link
/// attributes already stripped. Apply `.environment(\.openURL, MarkdownOpenURL.action)`
/// on the presenting `Text` as a second gate.
enum MarkdownAttributed {
    static func inline(_ source: String) -> AttributedString? {
        guard let attr = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return nil
        }
        return MarkdownOpenURL.sanitizeLinks(attr)
    }
}
