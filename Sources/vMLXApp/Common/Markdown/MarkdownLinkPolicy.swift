import Foundation
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
