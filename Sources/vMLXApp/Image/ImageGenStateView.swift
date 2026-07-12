// SPDX-License-Identifier: Apache-2.0
//
// ImageGenStateView — the live "generating" row rendered at the top of
// the gallery while a job is in flight. Owns no state; drives off the
// ImageViewModel's published generation fields.
//
// Shows:
//   • Indeterminate progress while the backend runs
//   • Requested step budget
//   • Elapsed time
//   • Optional partial-preview image
//   • Stop button

import SwiftUI
import vMLXTheme

struct ImageGenStateView: View {
    let requestedSteps: Int
    let elapsedSeconds: Int
    let preview: Data?
    let onStop: () -> Void
    @Environment(\.appLocale) private var appLocale: AppLocale

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            previewThumb
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(L10n.ImageUI.generating.render(appLocale))
                    .font(Theme.Typography.bodyHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                ProgressView()
                    .tint(Theme.Colors.accent)
                HStack {
                    Text(L10n.ImageUI.requestedStepsFormat.format(locale: appLocale, Int64(requestedSteps)))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMid)
                        .monospacedDigit()
                    Spacer()
                    Text(L10n.ImageUI.elapsedFormat.format(locale: appLocale, Int64(elapsedSeconds)))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                        .monospacedDigit()
                    Button(L10n.Chat.stop.render(appLocale), action: onStop)
                        .buttonStyle(.bordered)
                        .tint(Theme.Colors.danger)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(Theme.Colors.surfaceHi)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .stroke(Theme.Colors.accent.opacity(0.5), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var previewThumb: some View {
        #if canImport(AppKit)
        if let data = preview, let img = NSImage(data: data) {
            Image(nsImage: img)
                .resizable()
                .scaledToFill()
                .frame(width: 120, height: 120)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        } else {
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surface)
                .frame(width: 120, height: 120)
                .overlay(
                    Image(systemName: "sparkles")
                        .foregroundStyle(Theme.Colors.textLow)
                )
        }
        #else
        RoundedRectangle(cornerRadius: Theme.Radius.md)
            .fill(Theme.Colors.surface)
            .frame(width: 120, height: 120)
        #endif
    }
}
