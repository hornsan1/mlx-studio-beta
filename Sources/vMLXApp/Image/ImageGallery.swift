// SPDX-License-Identifier: Apache-2.0
//
// ImageGallery — full-parity grid. Renders:
//
//   • Error banner (HF 401/403 gated auth, or generic failure)
//   • Live GeneratingSkeleton (ImageGenStateView) when a job is in flight
//   • Empty state when no images yet
//   • Grid of past generations with redo buttons ALWAYS visible (not
//     hover-only) — per feedback_image_checklist.md + MEMORY "Redo buttons
//     always visible".

import SwiftUI
import Foundation
import vMLXTheme
import vMLXEngine
#if canImport(AppKit)
import AppKit
#endif

struct GeneratedImage: Identifiable, Hashable {
    let id: UUID
    let data: Data
    let prompt: String
    let modelAlias: String
    let createdAt: Date
    let durationMs: Int?
    let settingsSummary: String?
    let outputPath: String?

    init(
        id: UUID = UUID(),
        data: Data,
        prompt: String,
        modelAlias: String = "Image output",
        createdAt: Date,
        durationMs: Int? = nil,
        settingsSummary: String? = nil,
        outputPath: String? = nil
    ) {
        self.id = id
        self.data = data
        self.prompt = prompt
        self.modelAlias = modelAlias
        self.createdAt = createdAt
        self.durationMs = durationMs
        self.settingsSummary = settingsSummary
        self.outputPath = outputPath
    }
}

struct ImageGallery: View {
    @Environment(\.appLocale) private var appLocale: AppLocale
    let images: [GeneratedImage]
    let isGenerating: Bool
    let currentStep: Int
    let totalSteps: Int
    let elapsedSeconds: Int
    let preview: Data?
    let errorBanner: ImageErrorBanner?
    let onRedo: (GeneratedImage) -> Void
    let onDelete: (GeneratedImage) -> Void
    let onStop: () -> Void
    let onDismissError: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Color.clear
                        .frame(height: 0)
                        .id("gallery-top")

                    if let banner = errorBanner {
                        errorView(banner)
                    }

                    if isGenerating {
                        ImageGenStateView(
                            currentStep: currentStep,
                            totalSteps: totalSteps,
                            elapsedSeconds: elapsedSeconds,
                            preview: preview,
                            onStop: onStop
                        )
                        .id("generating")
                    }

                    if images.isEmpty && !isGenerating {
                        emptyState
                    } else {
                        if let featured = images.first {
                            featuredStage(featured)
                                .id(featured.id)
                        }

                        let recent = Array(images.dropFirst())
                        if !recent.isEmpty {
                            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                                HStack {
                                    Text("Recent outputs")
                                        .font(Theme.Typography.captionHi)
                                        .foregroundStyle(Theme.Colors.textLow)
                                    Spacer()
                                    Text("\(recent.count)")
                                        .font(Theme.Typography.monoCaption)
                                        .foregroundStyle(Theme.Colors.textLow)
                                }

                                LazyVGrid(columns: [
                                    GridItem(.adaptive(minimum: 200), spacing: Theme.Spacing.lg)
                                ], spacing: Theme.Spacing.lg) {
                                    ForEach(recent) { img in
                                        ImageCard(
                                            image: img,
                                            onRedo: { onRedo(img) },
                                            onDelete: { onDelete(img) }
                                        )
                                        .id(img.id)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(Theme.Spacing.lg)
            }
            // UI-4: when a new image lands at the top of `images`,
            // scroll back to it so the user actually sees their result
            // without manually scrolling past the prompt bar. We anchor
            // to .top because the gallery is sorted newest-first; the
            // newest entry will always be the first array element.
            // Also scroll to the live "generating" placeholder so the
            // user follows the in-progress preview.
            .onChange(of: images.first?.id) { _, newId in
                guard let id = newId else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(id, anchor: .top)
                }
            }
            .onChange(of: isGenerating) { _, nowGenerating in
                guard nowGenerating else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("generating", anchor: .top)
                }
            }
            .onChange(of: errorBanner) { _, banner in
                guard banner != nil else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("gallery-top", anchor: .top)
                }
            }
        }
    }

    private func featuredStage(_ image: GeneratedImage) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Canvas stage", systemImage: "sparkles.rectangle.stack")
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.creative)
                    Text("Latest output")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textHigh)
                    Text("Saved with prompt, model, settings, runtime, and file provenance.")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMid)
                }
                Spacer(minLength: Theme.Spacing.md)
                if outputFileExists(image) {
                    stagePill("Ready for reuse", systemImage: "arrow.triangle.2.circlepath", color: Theme.Colors.success)
                } else {
                    stagePill("File missing", systemImage: "doc.badge.exclamationmark", color: Theme.Colors.warning)
                }
            }

            HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    outputArtboard(image)
                        .frame(maxWidth: 560, maxHeight: 560)
                        .frame(maxWidth: .infinity)

                    HStack(spacing: Theme.Spacing.sm) {
                        stagePill(image.modelAlias, systemImage: "cpu", color: Theme.Colors.accent)
                        stagePill(image.settingsSummary ?? "Settings unavailable", systemImage: "slider.horizontal.3", color: Theme.Colors.creative)
                        if let durationMs = image.durationMs {
                            stagePill(durationString(durationMs), systemImage: "timer", color: Theme.Colors.warning)
                        }
                    }
                    .lineLimit(1)

                    resultHandoff(image)
                }
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    promptProvenance(image)

                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Run details")
                            .font(Theme.Typography.captionHi)
                            .foregroundStyle(Theme.Colors.textLow)
                        stageMetric("Model", image.modelAlias, systemImage: "cpu")
                        stageMetric("Created", Self.relativeFormatter.localizedString(for: image.createdAt, relativeTo: Date()), systemImage: "clock")
                        stageMetric("Settings", image.settingsSummary ?? "Settings unavailable", systemImage: "slider.horizontal.3")
                        if let durationMs = image.durationMs {
                            stageMetric("Runtime", durationString(durationMs), systemImage: "timer")
                        }
                        stageMetric("Saved asset", fileDisplayName(for: image), systemImage: "doc")
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text("Output actions")
                            .font(Theme.Typography.captionHi)
                            .foregroundStyle(Theme.Colors.textLow)

                        LazyVGrid(
                            columns: [GridItem(.flexible()), GridItem(.flexible())],
                            spacing: Theme.Spacing.sm
                        ) {
                            Button {
                                revealOutput(image)
                            } label: {
                                Label("Reveal file", systemImage: "folder")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(!outputFileExists(image))

                            Button {
                                copyOutputPath(image)
                            } label: {
                                Label("Copy path", systemImage: "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .disabled(!outputFileExists(image))

                            Button {
                                onRedo(image)
                            } label: {
                                Label("Reuse prompt", systemImage: "arrow.clockwise")
                                    .frame(maxWidth: .infinity)
                            }

                            Button(role: .destructive) {
                                onDelete(image)
                            } label: {
                                Label("Delete output", systemImage: "trash")
                                    .frame(maxWidth: .infinity)
                            }
                        }
                    }
                }
                .frame(width: 280, alignment: .topLeading)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 560, alignment: .topLeading)
        .background(Theme.ProNoirPanelBackground(active: true))
    }

    private func resultHandoff(_ image: GeneratedImage) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label("Result handoff", systemImage: "checkmark.seal")
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textMid)

            HStack(spacing: Theme.Spacing.sm) {
                handoffStep(
                    "Prompt",
                    "Reuse-ready",
                    accessibilityTitle: "Prompt captured",
                    color: Theme.Colors.creative
                )
                handoffStep(
                    "Settings",
                    "Editable",
                    accessibilityTitle: "Settings captured",
                    color: Theme.Colors.accent
                )
                handoffStep(
                    "File",
                    fileHandoffCaption(for: image),
                    accessibilityTitle: "File captured",
                    color: outputFileExists(image) ? Theme.Colors.success : Theme.Colors.warning
                )
            }
        }
        .padding(Theme.Spacing.sm)
        .background(Theme.Colors.surfaceHi.opacity(0.38))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border.opacity(0.72), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func handoffStep(
        _ title: String,
        _ caption: String,
        accessibilityTitle: String,
        color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(color)
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 46, alignment: .leading)
        .background(color.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .stroke(color.opacity(0.18), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(accessibilityTitle) \(caption)")
    }

    private func outputArtboard(_ image: GeneratedImage) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(
                    LinearGradient(
                        colors: [
                            Theme.Colors.surfaceHi.opacity(0.88),
                            Theme.Colors.background.opacity(0.96),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Canvas { context, size in
                let step: CGFloat = 18
                var path = Path()
                var x: CGFloat = 0
                while x <= size.width {
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    x += step
                }
                var y: CGFloat = 0
                while y <= size.height {
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    y += step
                }
                context.stroke(path, with: .color(Theme.Colors.border.opacity(0.18)), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))

            #if canImport(AppKit)
            if let nsimg = NSImage(data: image.data) {
                Image(nsImage: nsimg)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(Theme.Spacing.lg)
            } else {
                Image(systemName: "photo")
                    .font(.system(size: 46, weight: .medium))
                    .foregroundStyle(Theme.Colors.textLow)
            }
            #else
            Image(systemName: "photo")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(Theme.Colors.textLow)
            #endif

            VStack {
                HStack {
                    Label("Output canvas", systemImage: "photo")
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.textMid)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(Theme.Colors.background.opacity(0.72))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    Spacer()
                }
                Spacer()
            }
            .padding(Theme.Spacing.md)
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(Theme.Colors.borderHi.opacity(0.82), lineWidth: 1)
        )
    }

    private func promptProvenance(_ image: GeneratedImage) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label("Prompt provenance", systemImage: "quote.bubble")
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.creative)
            Text(image.prompt)
                .font(Theme.Typography.bodyHi)
                .foregroundStyle(Theme.Colors.textHigh)
                .lineSpacing(2)
                .lineLimit(5)
                .textSelection(.enabled)
            Text("Reuse keeps the same prompt source while leaving settings editable before the next run.")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surfaceHi.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func stageMetric(_ label: String, _ value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(label, systemImage: systemImage)
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textLow)
            Text(value)
                .font(label == "Saved asset" ? Theme.Typography.monoCaption : Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textMid)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surfaceHi.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func stagePill(_ title: String, systemImage: String, color: Color) -> some View {
        Label(title, systemImage: systemImage)
            .font(Theme.Typography.captionHi)
            .foregroundStyle(Theme.Colors.textMid)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(color.opacity(0.12))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .stroke(color.opacity(0.28), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private func fileDisplayName(for image: GeneratedImage) -> String {
        guard let outputPath = image.outputPath else { return "Not exported" }
        let name = URL(fileURLWithPath: outputPath).lastPathComponent
        return outputFileExists(image) ? name : "Missing: \(name)"
    }

    private func fileHandoffCaption(for image: GeneratedImage) -> String {
        guard image.outputPath != nil else { return "Not exported" }
        return outputFileExists(image) ? "Saved asset" : "Missing file"
    }

    private func outputFileExists(_ image: GeneratedImage) -> Bool {
        guard let outputPath = image.outputPath else { return false }
        return FileManager.default.fileExists(atPath: outputPath)
    }

    private func revealOutput(_ image: GeneratedImage) {
        guard let outputPath = image.outputPath,
              FileManager.default.fileExists(atPath: outputPath)
        else { return }
        #if canImport(AppKit)
        let url = URL(fileURLWithPath: outputPath)
        if let logURL = automatedRevealLogURL() {
            appendRevealLog(url.path, to: logURL)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    private func copyOutputPath(_ image: GeneratedImage) {
        guard let outputPath = image.outputPath,
              FileManager.default.fileExists(atPath: outputPath)
        else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outputPath, forType: .string)
        #endif
    }

    private func automatedRevealLogURL() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["MLX_STUDIO_CREATE_REVEAL_LOG"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func appendRevealLog(_ path: String, to logURL: URL) {
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

    private func durationString(_ durationMs: Int) -> String {
        if durationMs >= 1_000 {
            return String(format: "%.1f sec", Double(durationMs) / 1_000)
        }
        return "\(durationMs) ms"
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.xl) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.xl)
                    .fill(
                        LinearGradient(
                            colors: [
                                Theme.Colors.surfaceHi.opacity(0.95),
                                Theme.Colors.surface.opacity(0.74),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.xl)
                            .stroke(Theme.Colors.borderHi, lineWidth: 1)
                    )

                VStack(spacing: Theme.Spacing.md) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(Theme.Colors.creative)
                    Text("Create your first local image")
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textHigh)
                    Text("Choose a ready image model, keep the memory estimate in range, then describe what you want in the prompt bar.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textMid)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .frame(maxWidth: 440)
                }
                .padding(Theme.Spacing.xl)
            }
            .frame(maxWidth: 620)
            .frame(height: 320)

            HStack(spacing: Theme.Spacing.md) {
                createHint("1", "Pick model", "Downloaded or proof-gated")
                createHint("2", "Tune settings", "Steps, size, seed")
                createHint("3", "Generate", "Saved with provenance")
            }
            .frame(maxWidth: 620)
        }
        .frame(maxWidth: .infinity, minHeight: 460)
    }

    private func createHint(_ number: String, _ title: String, _ caption: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Text(number)
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.background)
                .frame(width: 22, height: 22)
                .background(Theme.Colors.textHigh)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    private func errorView(_ banner: ImageErrorBanner) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: banner.hfAuth
                  ? "lock.shield"
                  : "exclamationmark.triangle")
                .foregroundStyle(banner.hfAuth ? Theme.Colors.warning : Theme.Colors.danger)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.hfAuth
                     ? "Gated model — Hugging Face authentication required"
                     : banner.title)
                    .font(Theme.Typography.bodyHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .textSelection(.enabled)
                Text(banner.message)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .textSelection(.enabled)
            }
            Spacer()
            Button {
                onDismissError()
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(Theme.Colors.textLow)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .fill(Theme.Colors.surfaceHi)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(
                            banner.hfAuth ? Theme.Colors.warning : Theme.Colors.danger,
                            lineWidth: 1
                        )
                )
        )
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

struct ImageErrorBanner: Equatable {
    let title: String
    let message: String
    let hfAuth: Bool

    init(
        title: String = "Image generation failed",
        message: String,
        hfAuth: Bool
    ) {
        self.title = title
        self.message = message
        self.hfAuth = hfAuth
    }
}

private struct ImageCard: View {
    let image: GeneratedImage
    let onRedo: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            #if canImport(AppKit)
            if let nsimg = NSImage(data: image.data) {
                Image(nsImage: nsimg)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .background(Theme.Colors.surfaceHi)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
            #endif

            Text(image.prompt)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textMid)
                .lineLimit(2)

            // Redo + delete ALWAYS visible (not hover-only) — see
            // feedback_image_checklist.md.
            HStack(spacing: Theme.Spacing.sm) {
                Button(action: onRedo) {
                    Label("Redo", systemImage: "arrow.clockwise")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .fill(Theme.Colors.surfaceHi)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(imageActionTitle("Redo output"))
                .accessibilityLabel(imageActionTitle("Redo output"))

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Colors.textLow)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, Theme.Spacing.xs)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .fill(Theme.Colors.surfaceHi)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(imageActionTitle("Delete output"))
                .accessibilityLabel(imageActionTitle("Delete output"))
                Spacer()
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(Theme.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .stroke(Theme.Colors.border, lineWidth: 1)
                )
        )
    }

    private func imageActionTitle(_ action: String) -> String {
        "\(action) \(image.prompt)"
    }
}
