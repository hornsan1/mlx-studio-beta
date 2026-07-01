// SPDX-License-Identifier: Apache-2.0
//
// ImageHistory — sidebar for the Image screen. Lists every past generation
// from `ImageHistoryStore` grouped by day. Clicking an item re-loads the
// prompt + settings into the prompt bar.
//
// Matches the Electron ImageHistory component:
//   • grouped by date (Today / Yesterday / absolute date)
//   • Gen / Edit badge per row
//   • status dot (pending/completed/failed/cancelled)
//   • click to recall

import SwiftUI
import vMLXTheme
import vMLXEngine

#if canImport(AppKit)
import AppKit
#endif

struct ImageHistory: View {
    let records: [ImageGenerationRecord]
    let onRecall: (ImageGenerationRecord) -> Void
    let onDelete: (ImageGenerationRecord) -> Void
    @Environment(\.appLocale) private var appLocale: AppLocale

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(Theme.Colors.textLow)
                Text(L10n.ImageUI.history.render(appLocale))
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textLow)
                Spacer()
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.md)

            Text("Recent outputs")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
                .padding(.horizontal, Theme.Spacing.md)

            if records.isEmpty {
                emptyState
            } else {
                historyStatusStrip
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        ForEach(grouped, id: \.0) { pair in
                            let (day, items) = pair
                            Text(day)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textLow)
                                .padding(.horizontal, Theme.Spacing.md)
                            ForEach(items) { r in
                                row(r)
                            }
                        }
                    }
                    .padding(.vertical, Theme.Spacing.sm)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 210)
        .background(Theme.Colors.surface.opacity(0.92))
    }

    private var historyStatusStrip: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 82), spacing: Theme.Spacing.xs)],
            alignment: .leading,
            spacing: Theme.Spacing.xs
        ) {
            ForEach(statusCounts, id: \.label) { item in
                Label("\(item.count) \(item.label)", systemImage: item.systemImage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(statusColor(for: item.tone))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(statusColor(for: item.tone).opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
    }

    private var statusCounts: [(label: String, count: Int, systemImage: String, tone: ImageHistoryRecordState.Tone)] {
        let summaries = records.map(statusSummary)
        return [
            statusCount("Ready output", in: summaries),
            statusCount("Missing file", in: summaries),
            statusCount("Failed output", in: summaries),
            statusCount("Cancelled", in: summaries),
            statusCount("Rendering", in: summaries),
        ].compactMap { $0 }
    }

    private func statusCount(
        _ label: String,
        in summaries: [ImageHistoryRecordState.Summary]
    ) -> (label: String, count: Int, systemImage: String, tone: ImageHistoryRecordState.Tone)? {
        let matching = summaries.filter { $0.label == label }
        guard let first = matching.first else { return nil }
        return (label, matching.count, first.systemImage, first.tone)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "photo.stack")
                .foregroundStyle(Theme.Colors.textLow)
                .font(.title2)
            Text(L10n.ImageUI.noHistoryYet.render(appLocale))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Spacing.lg)
    }

    private var grouped: [(String, [ImageGenerationRecord])] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        var buckets: [(String, [ImageGenerationRecord])] = []
        var current: (String, [ImageGenerationRecord]) = ("", [])
        let df = DateFormatter()
        df.dateStyle = .medium
        for r in records {
            let day = cal.startOfDay(for: r.createdAt)
            let label: String
            if day == today { label = "Today" }
            else if day == yesterday { label = "Yesterday" }
            else { label = df.string(from: r.createdAt) }
            if current.0 != label {
                if !current.1.isEmpty { buckets.append(current) }
                current = (label, [r])
            } else {
                current.1.append(r)
            }
        }
        if !current.1.isEmpty { buckets.append(current) }
        return buckets
    }

    private func row(_ r: ImageGenerationRecord) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.xs) {
            Button {
                onRecall(r)
            } label: {
                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    thumbnail(for: r)
                        .frame(width: 48, height: 48)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Theme.Spacing.xs) {
                            Text(isEdit(r) ? "EDIT" : "GEN")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(isEdit(r) ? Theme.Colors.accentHi : Theme.Colors.textHigh)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(isEdit(r)
                                              ? Theme.Colors.accent.opacity(0.7)
                                              : Theme.Colors.surfaceHi)
                                )
                            Text(r.modelAlias)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textMid)
                                .lineLimit(1)
                        }
                        Label(statusLabel(r), systemImage: statusIcon(r))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(statusColor(r))
                            .lineLimit(1)
                        Text(r.prompt)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textMid)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(historyActionTitle("Recall history output", for: r))
            .accessibilityLabel(historyActionTitle("Recall history output", for: r))

            Button(role: .destructive) {
                onDelete(r)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textLow)
                    .frame(width: 24, height: 24)
                    .background(Theme.Colors.surfaceHi.opacity(0.64))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(historyActionTitle("Delete history output", for: r))
            .accessibilityLabel(historyActionTitle("Delete history output", for: r))
            .help("Delete output")
        }
        .padding(.trailing, Theme.Spacing.xs)
        .background(Theme.Colors.surfaceHi.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .padding(.horizontal, Theme.Spacing.sm)
        .contextMenu {
            Button(L10n.Misc.recallPrompt.render(appLocale)) { onRecall(r) }
            Divider()
            Button(L10n.Common.delete.render(appLocale), role: .destructive) { onDelete(r) }
        }
    }

    private func historyActionTitle(_ action: String, for record: ImageGenerationRecord) -> String {
        "\(action) \(record.prompt)"
    }

    @ViewBuilder
    private func thumbnail(for r: ImageGenerationRecord) -> some View {
        #if canImport(AppKit)
        if let outputPath = r.outputPath,
           let image = NSImage(contentsOf: URL(fileURLWithPath: outputPath)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(statusColor(r).opacity(0.62), lineWidth: 1)
                )
        } else {
            thumbnailPlaceholder(for: r)
        }
        #else
        thumbnailPlaceholder(for: r)
        #endif
    }

    private func thumbnailPlaceholder(for r: ImageGenerationRecord) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(statusColor(r).opacity(0.12))
            Image(systemName: isEdit(r) ? "photo.badge.arrow.down" : "photo")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(statusColor(r))
        }
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    private func isEdit(_ r: ImageGenerationRecord) -> Bool {
        r.sourceImagePath != nil
    }

    private func outputExists(_ r: ImageGenerationRecord) -> Bool {
        guard let outputPath = r.outputPath else { return false }
        return FileManager.default.fileExists(atPath: outputPath)
    }

    private func statusSummary(_ r: ImageGenerationRecord) -> ImageHistoryRecordState.Summary {
        ImageHistoryRecordState.summary(for: r, outputExists: outputExists(r))
    }

    private func statusLabel(_ r: ImageGenerationRecord) -> String {
        statusSummary(r).label
    }

    private func statusIcon(_ r: ImageGenerationRecord) -> String {
        statusSummary(r).systemImage
    }

    private func statusColor(_ r: ImageGenerationRecord) -> Color {
        statusColor(for: statusSummary(r).tone)
    }

    private func statusColor(for tone: ImageHistoryRecordState.Tone) -> Color {
        switch tone {
        case .active:
            return Theme.Colors.accent
        case .success:
            return Theme.Colors.success
        case .warning:
            return Theme.Colors.warning
        case .danger:
            return Theme.Colors.danger
        case .muted:
            return Theme.Colors.textLow
        }
    }
}
