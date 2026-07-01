// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import vMLXEngine
import vMLXTheme

#if canImport(AppKit)
import AppKit
#endif

struct ImageLibraryView: View {
    let records: [ImageGenerationRecord]
    let onDelete: (ImageGenerationRecord) -> Void
    let onReuse: (ImageGenerationRecord, ImageGenSettings) -> Void

    private var visibleRecords: [ImageGenerationRecord] {
        records.filter { record in
            record.outputPath != nil || record.status != .pending
        }
    }

    var body: some View {
        if visibleRecords.isEmpty {
            EmptyStateView(
                systemImage: "photo.on.rectangle.angled",
                title: "No generated images",
                caption: "Images created in Create will appear here with their prompts and files.",
                cta: nil
            )
            .frame(minHeight: 160)
        } else {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 520), spacing: Theme.Spacing.md)],
                spacing: Theme.Spacing.md
            ) {
                ForEach(visibleRecords) { record in
                    ImageLibraryCard(record: record) {
                        onDelete(record)
                    } onReuse: { settings in
                        onReuse(record, settings)
                    }
                }
            }
        }
    }
}

private struct ImageLibraryCard: View {
    let record: ImageGenerationRecord
    let onDelete: () -> Void
    let onReuse: (ImageGenSettings) -> Void

    private var outputURL: URL? {
        record.outputPath.map { URL(fileURLWithPath: $0) }
    }

    private var outputExists: Bool {
        guard let outputURL else { return false }
        return FileManager.default.fileExists(atPath: outputURL.path)
    }

    private var sidecarStatus: ImageGenerationRecord.MetadataSidecarStatus {
        record.metadataSidecarStatus
    }

    private var statusSummary: StudioImageRecordStatus.Summary {
        StudioImageRecordStatus.summary(
            for: record,
            fileExists: outputExists,
            sidecarStatus: sidecarStatus
        )
    }

    private var settings: ImageGenSettings {
        (try? JSONDecoder().decode(ImageGenSettings.self, from: Data(record.settingsJSON.utf8)))
            ?? ImageGenSettings()
    }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            imagePreview
                .frame(width: 148, height: 148)

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Memory tile", systemImage: "sparkles.rectangle.stack")
                            .font(Theme.Typography.captionHi)
                            .foregroundStyle(Theme.Colors.creative)
                        Text(record.prompt)
                            .font(Theme.Typography.bodyHi)
                            .foregroundStyle(Theme.Colors.textHigh)
                            .lineLimit(2)
                    }
                    Spacer(minLength: Theme.Spacing.sm)
                    Text(Self.dateFormatter.string(from: record.createdAt))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                        .lineLimit(1)
                }

                HStack(spacing: Theme.Spacing.xs) {
                    chip(record.modelAlias, "wand.and.stars", tint: Theme.Colors.creative)
                    chip("\(settings.width)x\(settings.height)", "aspectratio", tint: Theme.Colors.accent)
                    chip("\(settings.steps) steps", "dial.medium", tint: Theme.Colors.warning)
                    chip(settings.seed >= 0 ? "seed \(settings.seed)" : "random seed", "number", tint: Theme.Colors.textLow)
                }

                provenanceStrip

                HStack(spacing: Theme.Spacing.sm) {
                    Button {
                        onReuse(settings)
                    } label: {
                        Label("Reuse", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(imageActionTitle("Reuse image"))
                    .accessibilityLabel(imageActionTitle("Reuse image"))

                    Button(action: openImage) {
                        Label("Open", systemImage: "arrow.up.right.square")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!outputExists)
                    .accessibilityIdentifier(imageActionTitle("Open image"))
                    .accessibilityLabel(imageActionTitle("Open image"))

                    Button(action: revealImage) {
                        Label("Reveal", systemImage: "folder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!outputExists)
                    .accessibilityIdentifier(imageActionTitle("Reveal image"))
                    .accessibilityLabel(imageActionTitle("Reveal image"))

                    iconAction(
                        "Copy prompt",
                        accessibilityTitle: imageActionTitle("Copy prompt"),
                        systemImage: "doc.on.doc",
                        action: copyPrompt
                    )
                    iconAction(
                        "Export metadata",
                        accessibilityTitle: imageActionTitle("Export metadata"),
                        systemImage: "square.and.arrow.down",
                        action: exportMetadata
                    )
                    iconAction(
                        "Delete image record and file",
                        accessibilityTitle: imageActionTitle("Delete image record and file"),
                        systemImage: "trash",
                        role: .destructive,
                        action: onDelete
                    )
                }
                .controlSize(.small)
                .font(Theme.Typography.captionHi)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.ProNoirPanelBackground(active: true))
    }

    private var provenanceStrip: some View {
        HStack(spacing: Theme.Spacing.sm) {
            statusTile(
                "Prompt",
                "Captured",
                accessibilityTitle: "Prompt packet",
                systemImage: "text.quote",
                tint: Theme.Colors.accent
            )
            statusTile(
                "Settings",
                "Reusable",
                accessibilityTitle: "Settings",
                systemImage: "slider.horizontal.3",
                tint: Theme.Colors.success
            )
            statusTile(
                "File",
                fileStateText,
                accessibilityTitle: "File",
                systemImage: fileStateSystemImage,
                tint: fileStateTint
            )
            statusTile(
                "Provenance",
                provenanceStateText,
                accessibilityTitle: "Provenance",
                systemImage: "doc.badge.gearshape",
                tint: provenanceStateTint
            )
        }
    }

    private var provenanceStateText: String {
        statusSummary.provenanceLabel
    }

    private var provenanceStateTint: Color {
        switch sidecarStatus {
        case .saved:
            return Theme.Colors.success
        case .missing:
            return Theme.Colors.warning
        case .stale:
            return Theme.Colors.danger
        }
    }

    private func chip(_ text: String, _ systemImage: String, tint: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textLow)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(tint.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .stroke(tint.opacity(0.20), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private var fileStateText: String {
        statusSummary.fileLabel
    }

    private var fileStateSystemImage: String {
        outputExists ? "doc.badge.checkmark" : "doc.badge.exclamationmark"
    }

    private var fileStateTint: Color {
        if outputExists { return Theme.Colors.creative }
        if outputURL != nil { return Theme.Colors.warning }
        switch record.status {
        case .pending, .completed: return Theme.Colors.warning
        case .failed: return Theme.Colors.danger
        case .cancelled: return Theme.Colors.textLow
        }
    }

    private func statusTile(
        _ title: String,
        _ value: String,
        accessibilityTitle: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .lineLimit(1)
                Text(value)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(2)
                    .minimumScaleFactor(0.88)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
        .background(tint.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityTitle) \(value)")
    }

    private func iconAction(
        _ title: String,
        accessibilityTitle: String,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Image(systemName: systemImage)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityIdentifier(accessibilityTitle)
        .accessibilityLabel(accessibilityTitle)
    }

    private func imageActionTitle(_ action: String) -> String {
        "\(action) \(record.prompt)"
    }

    @ViewBuilder
    private var imagePreview: some View {
        #if canImport(AppKit)
        if let outputURL,
           let image = NSImage(contentsOf: outputURL) {
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .background(Theme.Colors.surfaceHi)

                Label("Ready artifact", systemImage: "checkmark.seal")
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 5)
                    .background(Theme.Colors.background.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .padding(Theme.Spacing.sm)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.borderHi.opacity(0.72), lineWidth: 1)
            )
        } else {
            missingPreview
        }
        #else
        missingPreview
        #endif
    }

    private var missingPreview: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: "photo.badge.exclamationmark")
                .font(.title2)
            Text("Missing file")
                .font(Theme.Typography.caption)
        }
        .foregroundStyle(Theme.Colors.textLow)
        .frame(maxWidth: .infinity)
        .frame(height: 148)
        .background(Theme.Colors.surfaceHi)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func openImage() {
        #if canImport(AppKit)
        if let outputURL {
            if let logURL = automatedOpenLogURL() {
                appendAutomationLog(outputURL.path, to: logURL)
                return
            }
            NSWorkspace.shared.open(outputURL)
        }
        #endif
    }

    private func revealImage() {
        #if canImport(AppKit)
        if let outputURL {
            if let logURL = automatedRevealLogURL() {
                appendAutomationLog(outputURL.path, to: logURL)
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([outputURL])
        }
        #endif
    }

    private func copyPrompt() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.prompt, forType: .string)
        #endif
    }

    private func exportMetadata() {
        #if canImport(AppKit)
        if let directory = automatedMetadataExportDirectory() {
            do {
                let url = try record.writeMetadataExport(to: directory)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            } catch {
                StudioDiagnosticIssueStore.record(
                    source: .diagnostics,
                    title: "Image metadata export failed",
                    message: error.localizedDescription,
                    context: record.prompt
                )
            }
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = record.metadataExportFilename()
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try record.metadataExportData()
            try data.write(to: url, options: .atomic)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        } catch {
            StudioDiagnosticIssueStore.record(
                source: .diagnostics,
                title: "Image metadata export failed",
                message: error.localizedDescription,
                context: record.prompt
            )
        }
        #endif
    }

    private func automatedMetadataExportDirectory() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["MLX_STUDIO_IMAGE_METADATA_EXPORT_DIR"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func automatedRevealLogURL() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["MLX_STUDIO_LIBRARY_REVEAL_LOG"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func automatedOpenLogURL() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["MLX_STUDIO_LIBRARY_OPEN_LOG"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func appendAutomationLog(_ path: String, to logURL: URL) {
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: logURL.path) {
            _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        handle.seekToEndOfFile()
        handle.write(Data("\(path)\n".utf8))
        handle.closeFile()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
