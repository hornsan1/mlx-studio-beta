// SPDX-License-Identifier: Apache-2.0
//
// ImagePromptBar — the bottom input row on the Image screen. Handles:
//
//   • Prompt textarea
//   • Source-image upload (file picker + drag/drop) in Edit mode
//   • Strength slider (0..1) in Edit mode
//   • "Paint mask" button that opens MaskPainter as a sheet in Edit mode
//   • Generate / Edit button that calls the Engine's typed image API
//
// All settings read/write through the ImageViewModel bound by the parent
// ImageScreen. The model mode is DRIVEN BY AN EXPLICIT TAB BINDING — no
// regex or string matching on model names, per feedback_no_regex_explicit
// _settings.md.

import SwiftUI
import UniformTypeIdentifiers
import vMLXTheme
import vMLXEngine

struct ImagePromptBar: View {
    @Environment(\.appLocale) private var appLocale: AppLocale
    @Binding var prompt: String
    @Binding var sourceImage: Data?
    @Binding var maskImage: Data?
    @Binding var strength: Double
    let mode: ImageScreen.Tab
    let canSubmit: Bool
    let onSubmit: () -> Void
    let downloadState: ModelInstallViewState?
    let onDownloadNeeded: (() -> Void)?  // nil when selected model is downloaded
    let onCancelDownload: (() -> Void)?
    let submitLabel: String
    let downloadSubmitLabel: String
    @State private var showMaskPainter = false
    @State private var showFileImporter = false
    @State private var isDropTargeted = false

    private struct PromptStarter: Identifiable {
        let id: String
        let title: String
        let caption: String
        let value: String
        let systemImage: String
        let tint: Color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if mode == .edit {
                editControls
            } else if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                promptStarters
            }

            HStack(alignment: .bottom, spacing: Theme.Spacing.sm) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(mode == .edit ? "Edit brief" : "Prompt brief", systemImage: mode == .edit ? "paintbrush.pointed" : "text.alignleft")
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.textLow)
                    TextField(
                        mode == .edit
                            ? "Describe the edit..."
                            : "Describe the frame, subject, light, and mood...",
                        text: $prompt,
                        axis: .vertical
                    )
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1...3)
                    .accessibilityIdentifier(mode == .edit ? "Image edit brief" : "Image prompt brief")
                    .accessibilityLabel(mode == .edit ? "Image edit brief" : "Image prompt brief")
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(Theme.Colors.background.opacity(0.42))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.md)
                                .stroke(Theme.Colors.border.opacity(0.76), lineWidth: 1)
                        )
                )

                if let downloadState, downloadState.isActive {
                    HStack(spacing: Theme.Spacing.xs) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(downloadState.label)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textMid)
                                .lineLimit(1)
                            ProgressView(value: downloadState.progress ?? 0)
                                .frame(width: 110)
                                .controlSize(.small)
                        }
                        if let onCancelDownload {
                            Button(action: onCancelDownload) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.Colors.textMid)
                                    .frame(width: 26, height: 26)
                            }
                            .buttonStyle(.plain)
                            .help("Cancel download")
                        }
                    }
                } else if let onDownloadNeeded {
                    Button {
                        onDownloadNeeded()
                    } label: {
                        Label(
                            downloadSubmitLabel,
                            systemImage: "arrow.down.circle"
                        )
                            .font(Theme.Typography.bodyHi)
                            .foregroundStyle(Theme.Colors.textHigh)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.sm)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.md)
                                    .fill(Theme.Colors.warning)
                            )
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: onSubmit) {
                        Text(submitLabel)
                            .font(Theme.Typography.bodyHi)
                            .foregroundStyle(Theme.Colors.textHigh)
                            .padding(.horizontal, Theme.Spacing.md)
                            .padding(.vertical, Theme.Spacing.sm)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.Radius.md)
                                    .fill(canSubmit
                                          ? Theme.Colors.accent
                                          : Theme.Colors.surfaceHi)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(Theme.Colors.surface.opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .stroke(
                            isDropTargeted ? Theme.Colors.accent : Theme.Colors.border,
                            lineWidth: isDropTargeted ? 2 : 1
                        )
                )
        )
        .padding(Theme.Spacing.lg)
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            guard mode == .edit, let p = providers.first else { return false }
            _ = p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                if let data {
                    DispatchQueue.main.async { sourceImage = data }
                }
            }
            return true
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first,
               let data = try? Data(contentsOf: url) {
                sourceImage = data
            }
        }
        .sheet(isPresented: $showMaskPainter) {
            if let src = sourceImage {
                MaskPainter(
                    sourceImage: src,
                    onSave: { maskImage = $0; showMaskPainter = false },
                    onCancel: { showMaskPainter = false }
                )
            }
        }
    }

    @ViewBuilder
    private var promptStarters: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Label("Creative brief", systemImage: "sparkles")
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                Text("Start from a visual direction")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .lineLimit(1)
            }
            .frame(width: 154, alignment: .topLeading)

            HStack(spacing: Theme.Spacing.sm) {
                ForEach(promptStarterOptions) { starter in
                    promptStarter(starter)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var promptStarterOptions: [PromptStarter] {
        [
            PromptStarter(
                id: "product",
                title: "Product shot",
                caption: "Graphite desk",
                value: "cinematic product photo of a translucent local AI workstation on a graphite desk",
                systemImage: "cube.transparent",
                tint: Theme.Colors.success
            ),
            PromptStarter(
                id: "portrait",
                title: "Portrait light",
                caption: "Rim-lit studio",
                value: "soft studio portrait, reflective black background, precise rim light",
                systemImage: "person.crop.square",
                tint: Theme.Colors.accent
            ),
            PromptStarter(
                id: "concept",
                title: "Concept frame",
                caption: "Noir workspace",
                value: "quiet futuristic Mac studio, local model cards floating as glass panels",
                systemImage: "rectangle.3.group",
                tint: Theme.Colors.creative
            )
        ]
    }

    private func promptStarter(_ starter: PromptStarter) -> some View {
        Button {
            prompt = starter.value
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: starter.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(starter.tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(starter.title)
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(1)
                    Text(starter.caption)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, 5)
            .frame(width: 150, alignment: .topLeading)
            .frame(minHeight: 40, alignment: .topLeading)
            .background(starter.tint.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(starter.tint.opacity(0.24), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Image starter \(starter.title)")
        .accessibilityLabel("Image starter \(starter.title)")
        .accessibilityHint(starter.caption)
    }

    @ViewBuilder
    private var editControls: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Source image preview / pick
            Button {
                showFileImporter = true
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    if let data = sourceImage {
                        #if canImport(AppKit)
                        if let img = NSImage(data: data) {
                            Image(nsImage: img)
                                .resizable().scaledToFill()
                                .frame(width: 36, height: 36)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                        }
                        #endif
                        Text(L10n.ImageUI.change.render(appLocale)).font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textMid)
                    } else {
                        Image(systemName: "photo.badge.plus")
                            .foregroundStyle(Theme.Colors.textMid)
                        Text(L10n.ImageUI.sourceImage.render(appLocale)).font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textMid)
                    }
                }
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.sm)
                        .fill(Theme.Colors.surfaceHi)
                )
            }
            .buttonStyle(.plain)

            Button {
                showMaskPainter = true
            } label: {
                Label(maskImage == nil ? "Paint mask" : "Edit mask",
                      systemImage: "paintbrush.pointed")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(sourceImage == nil
                                     ? Theme.Colors.textLow
                                     : Theme.Colors.textMid)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .fill(Theme.Colors.surfaceHi)
                    )
            }
            .buttonStyle(.plain)
            .disabled(sourceImage == nil)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.ImageUI.strengthFormat.format(locale: appLocale, String(format: "%.2f", strength) as NSString))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                Slider(value: $strength, in: 0...1)
                    .controlSize(.small)
                    .frame(width: 180)
            }

            Spacer()
        }
    }
}
