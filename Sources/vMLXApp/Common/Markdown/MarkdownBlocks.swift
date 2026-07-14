import SwiftUI
import vMLXTheme

// MARK: - Shared inline body

/// Renders block-body Markdown with link sanitization + `MarkdownOpenURL`.
/// Used by heading / list / task / blockquote chrome so every inline surface
/// shares the same open path as `MarkdownProseView`.
private struct MarkdownInlineBody: View {
    let text: String
    var font: Font = Theme.Typography.markdownBody
    var foreground: Color = Theme.Colors.markdownText

    var body: some View {
        Group {
            if let attr = MarkdownAttributed.inline(text) {
                Text(attr)
                    .environment(\.openURL, MarkdownOpenURL.action)
            } else {
                Text(text)
            }
        }
        .font(font)
        .foregroundStyle(foreground)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Heading

/// ATX heading with hierarchy font + accessibility header trait / level.
struct MarkdownHeadingView: View {
    let level: Int
    let text: String

    private var clampedLevel: Int { max(1, min(level, 6)) }

    private var headingLevel: AccessibilityHeadingLevel {
        switch clampedLevel {
        case 1: return .h1
        case 2: return .h2
        case 3: return .h3
        case 4: return .h4
        case 5: return .h5
        default: return .h6
        }
    }

    private var plainLabel: String {
        MarkdownPlainText.stripInlineMarkers(text)
    }

    var body: some View {
        MarkdownInlineBody(
            text: text,
            font: Theme.Typography.markdownHeading(level: clampedLevel)
        )
        // Single VoiceOver element with header trait + heading level (rotor).
        .accessibilityElement(children: .combine)
        .accessibilityLabel(plainLabel)
        .accessibilityAddTraits(.isHeader)
        .accessibilityHeading(headingLevel)
    }
}

// MARK: - List item

/// Single list row: indent by `indentLevel`, bullet or ordered index.
struct MarkdownListItemView: View {
    let ordered: Bool
    let index: Int?
    let indentLevel: Int
    let text: String

    private var indent: CGFloat {
        CGFloat(max(indentLevel, 0)) * Theme.Spacing.lg
    }

    private var marker: String {
        if ordered {
            return "\(index ?? 1)."
        }
        return "•"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            Text(marker)
                .font(Theme.Typography.markdownBody)
                .foregroundStyle(Theme.Colors.markdownTextSecondary)
                .frame(minWidth: ordered ? 22 : 12, alignment: .trailing)
                .accessibilityHidden(true)
            MarkdownInlineBody(text: text)
        }
        .padding(.leading, indent)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        if ordered {
            return "\(index ?? 1). \(plainLabel)"
        }
        return plainLabel
    }

    private var plainLabel: String {
        // Prefer stripped plain for VoiceOver when markers are noisy.
        MarkdownPlainText.stripInlineMarkers(text)
    }
}

// MARK: - Task item

/// Display-only task checkbox chrome. Never mutates stored Markdown (K11).
struct MarkdownTaskItemView: View {
    let checked: Bool
    let indentLevel: Int
    let text: String

    private var indent: CGFloat {
        CGFloat(max(indentLevel, 0)) * Theme.Spacing.lg
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .font(Theme.Typography.markdownBody)
                .foregroundStyle(
                    checked
                        ? Theme.Colors.markdownAccent
                        : Theme.Colors.markdownTextSecondary
                )
                .accessibilityHidden(true)
            MarkdownInlineBody(
                text: text,
                foreground: checked
                    ? Theme.Colors.markdownTextSecondary
                    : Theme.Colors.markdownText
            )
        }
        .padding(.leading, indent)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Not a Toggle — chrome is presentation-only.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(checked ? "Checked" : "Unchecked")
        .accessibilityAddTraits(.isStaticText)
    }

    private var accessibilityLabel: String {
        MarkdownPlainText.stripInlineMarkers(text)
    }
}

// MARK: - Blockquote

/// Contiguous quote run with a leading accent bar.
struct MarkdownBlockquoteView: View {
    let text: String
    var quoteDepth: Int = 1

    private var barWidth: CGFloat {
        // Slightly thicker bar for nested depth (capped).
        quoteDepth >= 2 ? 3 : 2
    }

    private var leadingInset: CGFloat {
        CGFloat(max(quoteDepth - 1, 0)) * Theme.Spacing.sm
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Theme.Colors.markdownAccent)
                .frame(width: barWidth)
                .frame(maxHeight: .infinity)
                .accessibilityHidden(true)
            MarkdownInlineBody(
                text: text,
                foreground: Theme.Colors.markdownTextSecondary
            )
        }
        .padding(.leading, leadingInset)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(MarkdownPlainText.stripInlineMarkers(text))
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - Thematic break

/// Horizontal rule as a `Divider`.
struct MarkdownThematicBreakView: View {
    var body: some View {
        Divider()
            .overlay(Theme.Colors.markdownBorder)
            .padding(.vertical, Theme.Spacing.xs)
            .accessibilityLabel("Separator")
    }
}
