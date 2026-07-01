import SwiftUI
import vMLXTheme

/// Reusable empty-state panel. Mirrors the Electron `<EmptyState />` used in
/// chat / sessions / downloads / images — big SF symbol, short title,
/// caption, optional CTA button. Theme tokens only.
struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var caption: String? = nil
    var cta: (String, () -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Spacing.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.xl)
                    .fill(Theme.Colors.surfaceHi.opacity(0.72))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.xl)
                            .stroke(Theme.Colors.border, lineWidth: 1)
                    )
                Image(systemName: systemImage)
                    .font(.system(size: 30, weight: .regular))
                    .foregroundStyle(Theme.Colors.textMid)
            }
            .frame(width: 72, height: 72)

            VStack(spacing: Theme.Spacing.sm) {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.textHigh)
                if let caption, !caption.isEmpty {
                    Text(caption)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textMid)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 420)
                }
            }

            if let cta {
                Button(cta.0, action: cta.1)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
