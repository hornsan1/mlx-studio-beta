// SPDX-License-Identifier: Apache-2.0
//
// ImageModelPicker — centralizes the image model catalog. Binds to
// `appState.engine.modelLibrary.entries()` and surfaces
// two sections:
//
//   • Generate: FLUX.1 Schnell, FLUX.2 Klein, Z-Image Turbo
//   • Edit:     Qwen Image Edit
//
// Each row shows: display name, size, downloaded dot, JANG/MXTQ badge.
// Rows that aren't downloaded surface a "Download" button routed through
// StudioModelInstallService, so catalog, HF search, and onboarding all share
// the same download → verify → library-rescan path.
//
// Theming: Theme.* tokens only, zero hardcoded colors.

import SwiftUI
import vMLXEngine
import vMLXTheme

struct ImageModelPicker: View {
    @Environment(AppState.self) private var appState
    @Binding var selected: ImageCatalogModel?
    @Binding var mode: ImageScreen.Tab

    @State private var entries: [ModelLibrary.ModelEntry] = []
    @State private var installStates: [String: ModelInstallViewState] = [:]
    @State private var hubQuery = "flux schnell"
    @State private var hubResults: [ImageCatalogModel] = []
    @State private var hubSearchStatus: String?
    @State private var isSearchingHub = false
    @State private var installTasks: [String: Task<Void, Never>] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            if !ImageCatalog.generate.isEmpty {
                section(title: "Generate", models: ImageCatalog.generate)
            }
            // §384 — skip the Edit header when no edit models are ported
            // yet. Stops rendering an empty "EDIT" label with no rows
            // underneath (leftover placeholder look).
            if !ImageCatalog.edit.isEmpty {
                section(title: "Edit", models: ImageCatalog.edit)
            }
            hubSearch
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
        .task { await refresh() }
    }

    private func section(title: String, models: [ImageCatalogModel]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title.uppercased())
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
                .padding(.horizontal, Theme.Spacing.sm)
            ForEach(models) { m in
                ImageModelRow(
                    model: m,
                    isDownloaded: entryFor(m) != nil,
                    isSelected: selected?.id == m.id,
                    size: entryFor(m)?.totalSizeBytes ?? m.approxSizeBytes,
                    readiness: readinessFor(m),
                    badges: badgesFor(m),
                    installState: installStates[m.id],
                    onSelect: {
                        selected = m
                        mode = (m.kind == .edit) ? .edit : .generate
                    },
                    onDownload: {
                        install(m)
                    },
                    onCancel: {
                        cancelInstall(m)
                    }
                )
            }
        }
    }

    private func entryFor(_ m: ImageCatalogModel) -> ModelLibrary.ModelEntry? {
        imageCatalogEntry(for: m, in: entries)
    }

    private func badgesFor(_ m: ImageCatalogModel) -> [String] {
        var out: [String] = []
        // §381 — lead with runnability so users see it before JANG/quant
        // metadata. Scaffolded entries get a muted "Not ready" tag.
        out.append(readinessFor(m).badge)
        if m.runtimeName == "flux2-klein" { out.append("Pro") }
        guard let e = entryFor(m) else { return out }
        if e.isJANG { out.append("JANG") }
        if e.isMXTQ { out.append("MXTQ") }
        if let b = e.quantBits { out.append("\(b)-bit") }
        return out
    }

    private func readinessFor(_ model: ImageCatalogModel) -> ImageModelReadiness {
        if model.gated {
            return .needsToken
        }
        if !model.ready && !model.requiresSmokeVerification {
            return .unsupported
        }
        guard let entry = entryFor(model) else {
            return model.ready || model.requiresSmokeVerification ? .supported : .unsupported
        }
        if model.ready || ImageRuntimeProofStore.isVerified(
            runtimeName: model.runtimeName,
            modelPath: entry.canonicalPath.path
        ) {
            return .ready
        }
        return .supported
    }

    private var hubSearch: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Divider().background(Theme.Colors.border)
            Text("HUGGING FACE IMAGE MODELS")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
                .padding(.horizontal, Theme.Spacing.sm)

            HStack(spacing: Theme.Spacing.xs) {
                TextField("Search MLX image models", text: $hubQuery)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .fill(Theme.Colors.surfaceHi)
                    )
                    .onSubmit { searchHub() }

                Button(action: searchHub) {
                    Image(systemName: isSearchingHub ? "hourglass" : "magnifyingglass")
                        .foregroundStyle(Theme.Colors.textHigh)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .fill(Theme.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .disabled(isSearchingHub)
            }

            if let hubSearchStatus {
                Text(hubSearchStatus)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .padding(.horizontal, Theme.Spacing.sm)
            }

            ForEach(hubResults) { model in
                ImageModelRow(
                    model: model,
                    isDownloaded: entryFor(model) != nil,
                    isSelected: selected?.id == model.id,
                    size: entryFor(model)?.totalSizeBytes ?? model.approxSizeBytes,
                    readiness: readinessFor(model),
                    badges: badgesFor(model),
                    installState: installStates[model.id],
                    onSelect: {
                        selected = model
                        mode = (model.kind == .edit) ? .edit : .generate
                    },
                    onDownload: {
                        install(model)
                    },
                    onCancel: {
                        cancelInstall(model)
                    }
                )
            }
        }
    }

    private func refresh() async {
        entries = await appState.engine.modelLibrary.entries()
            .filter { $0.modality == .image || $0.family.lowercased().contains("flux") }
    }

    private func searchHub() {
        let query = hubQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearchingHub = true
        hubSearchStatus = "Searching compatible MLX image repos..."
        Task {
            do {
                let search = HuggingFaceSearch(token: HuggingFaceAuth.shared.currentToken())
                let rows = try await search.searchRuntimeCompatible(query: query, limit: 12)
                let models = rows.compactMap(Self.catalogModel(from:))
                await MainActor.run {
                    hubResults = models
                    hubSearchStatus = models.isEmpty
                        ? "No vMLX-compatible image repos found for this search."
                        : "\(models.count) compatible image repos"
                    isSearchingHub = false
                }
            } catch {
                await MainActor.run {
                    hubSearchStatus = error.localizedDescription
                    isSearchingHub = false
                }
            }
        }
    }

    private func install(_ model: ImageCatalogModel) {
        guard installStates[model.id]?.isActive != true else { return }
        installStates[model.id] = .init(
            phase: .queued,
            label: "Queued",
            progress: 0,
            localPath: nil
        )
        let task = Task {
            let request = ModelInstallRequest(
                repo: model.repo,
                displayName: model.displayName,
                source: .huggingFace,
                openChatWhenReady: false,
                target: .image(runtimeName: model.runtimeName)
            )
            let stream = StudioModelInstallService(app: appState).install(request)
            do {
                for try await event in stream {
                    let state = ModelInstallViewState.from(event, target: request.target)
                    await MainActor.run {
                        installStates[model.id] = state
                    }
                    switch event {
                    case .installed, .ready:
                        await refresh()
                        await MainActor.run {
                            selected = model
                            mode = (model.kind == .edit) ? .edit : .generate
                        }
                    default:
                        break
                    }
                }
                await MainActor.run {
                    installTasks[model.id] = nil
                }
            } catch {
                await MainActor.run {
                    installStates[model.id] = .init(
                        phase: .failed,
                        label: Task.isCancelled ? "Cancelled" : error.localizedDescription,
                        progress: nil,
                        localPath: nil
                    )
                    installTasks[model.id] = nil
                }
            }
        }
        installTasks[model.id] = task
    }

    private func cancelInstall(_ model: ImageCatalogModel) {
        let jobID = installStates[model.id]?.jobID
        installTasks[model.id]?.cancel()
        installTasks[model.id] = nil
        if let jobID {
            Task {
                await appState.downloadManager.cancel(jobID)
            }
        }
        installStates[model.id] = .init(
            phase: .failed,
            label: "Cancelled",
            progress: nil,
            localPath: nil
        )
    }

    private static func catalogModel(from row: HuggingFaceSearchResult) -> ImageCatalogModel? {
        guard row.runtimeCompatibility.isCompatible,
              row.runtimeCompatibility.modality == .image,
              let runtimeName = row.runtimeCompatibility.modelType
        else { return nil }

        let displayName = row.modelId.split(separator: "/").last.map(String.init) ?? row.modelId
        let size = row.weightBytes ?? row.usedStorageBytes ?? 0
        return ImageCatalogModel(
            id: "hf:\(row.modelId)",
            displayName: displayName,
            repo: row.modelId,
            kind: .generate,
            runtimeName: runtimeName,
            libraryMatchFragment: runtimeName,
            approxSizeBytes: size,
            ready: true,
            requiresSmokeVerification: ImageCatalog.requiresSmokeProof(runtimeName),
            gated: row.gated,
            compatibilityNote: row.runtimeCompatibility.reason
        )
    }
}

// MARK: - Row

private struct ImageModelRow: View {
    let model: ImageCatalogModel
    let isDownloaded: Bool
    let isSelected: Bool
    let size: Int64
    let readiness: ImageModelReadiness
    let badges: [String]
    let installState: ModelInstallViewState?
    let onSelect: () -> Void
    let onDownload: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Circle()
                .fill(readiness.dotColor(isDownloaded: isDownloaded))
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Spacing.xs) {
                    Text(model.displayName)
                        .font(Theme.Typography.bodyHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                    ForEach(badges, id: \.self) { b in
                        Text(b)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textMid)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Theme.Colors.surfaceHi)
                            )
                    }
                }
                Text(secondaryLabel)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .lineLimit(2)
            }
            Spacer()
            if let installState, installState.isActive {
                HStack(spacing: Theme.Spacing.xs) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(installState.label)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textMid)
                            .lineLimit(1)
                        ProgressView(value: installState.progress ?? 0)
                            .frame(width: 76)
                            .controlSize(.small)
                    }
                    Button(action: onCancel) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.Colors.textMid)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel download")
                }
            } else if readiness == .unsupported {
                Text("Blocked")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .fill(Theme.Colors.surfaceHi)
                    )
            } else if isDownloaded {
                Button(action: onSelect) {
                    Text(actionLabel)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(isSelected ? Theme.Colors.textHigh : Theme.Colors.textMid)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .fill(isSelected ? Theme.Colors.accent : Theme.Colors.surfaceHi)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(modelActionTitle(actionLabel))
                .accessibilityLabel(modelActionTitle(actionLabel))
            } else {
                Button(action: onDownload) {
                    Label("Download", systemImage: "arrow.down.circle")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .padding(.horizontal, Theme.Spacing.sm)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .fill(Theme.Colors.accent)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(modelActionTitle("Download"))
                .accessibilityLabel(modelActionTitle("Download"))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isDownloaded && (model.ready || model.requiresSmokeVerification) {
                onSelect()
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .fill(isSelected ? Theme.Colors.surfaceHi : Color.clear)
        )
    }

    private var sizeLabel: String {
        if size <= 0 { return "—" }
        let gb = Double(size) / 1_073_741_824.0
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(size) / 1_048_576.0
        return String(format: "%.0f MB", mb)
    }

    private var secondaryLabel: String {
        let readinessNote = readiness.note(isDownloaded: isDownloaded)
        if !model.compatibilityNote.isEmpty {
            return "\(sizeLabel) - \(readinessNote) - \(model.compatibilityNote)"
        }
        return "\(sizeLabel) - \(readinessNote)"
    }

    private var actionLabel: String {
        if isSelected { return "Selected" }
        return "Select"
    }

    private func modelActionTitle(_ action: String) -> String {
        "\(action) \(model.displayName)"
    }
}

private enum ImageModelReadiness: Equatable {
    case ready
    case supported
    case needsToken
    case unsupported

    var badge: String {
        switch self {
        case .ready: return "Ready"
        case .supported: return "Ready"
        case .needsToken: return "Needs token"
        case .unsupported: return "Unsupported"
        }
    }

    func note(isDownloaded: Bool) -> String {
        switch self {
        case .ready:
            return "Ready for Create"
        case .supported:
            return isDownloaded ? "Ready for Create" : "Download to run"
        case .needsToken:
            return "HF token required before download"
        case .unsupported:
            return "Not runnable by this beta runtime"
        }
    }

    func dotColor(isDownloaded: Bool) -> Color {
        switch self {
        case .ready:
            return Theme.Colors.success
        case .supported:
            return isDownloaded ? Theme.Colors.success : Theme.Colors.textLow
        case .needsToken, .unsupported:
            return Theme.Colors.textLow
        }
    }
}

// MARK: - Catalog (single source of truth for known image models)

struct ImageCatalogModel: Identifiable, Hashable {
    enum Kind { case generate, edit }
    let id: String
    let displayName: String
    let repo: String
    let kind: Kind
    let runtimeName: String
    /// Substring used to match this model against a `ModelLibrary.ModelEntry`.
    let libraryMatchFragment: String
    /// Fallback size shown when the model hasn't been downloaded yet.
    let approxSizeBytes: Int64
    /// `true` when this row should expose download/select/generate.
    /// Rows may still request a smoke pass in automation, but the Create
    /// picker presents the built-in Generate catalog as ready to use.
    let ready: Bool
    let requiresSmokeVerification: Bool
    let gated: Bool
    let compatibilityNote: String
}

enum ImageCatalog {
    static func requiresSmokeProof(_ runtimeName: String) -> Bool {
        false
    }

    static var generate: [ImageCatalogModel] {
        return [
            ImageCatalogModel(
                id: "flux1-schnell",
                displayName: "FLUX.1 Schnell",
                repo: "AITRADER/FLUX1-schnell-mlx-4bit",
                kind: .generate,
                runtimeName: "flux1-schnell",
                libraryMatchFragment: "flux1-schnell",
                approxSizeBytes: 9_606_737_902,
                ready: true,
                requiresSmokeVerification: false,
                gated: false,
                compatibilityNote: "Ready image generation path"
            ),
            ImageCatalogModel(
                id: "krea-2-turbo",
                displayName: "Krea 2 Turbo",
                repo: "krea/Krea-2-Turbo",
                kind: .generate,
                runtimeName: "krea-2-turbo",
                libraryMatchFragment: "krea-2",
                approxSizeBytes: 32_000_000_000,
                ready: true,
                requiresSmokeVerification: false,
                gated: false,
                compatibilityNote: "Turbo image generation path"
            ),
            ImageCatalogModel(
                id: "flux2-klein",
                displayName: "FLUX.2 Klein 4B",
                repo: "mlx-community/flux2-klein-4b-4bit",
                kind: .generate,
                runtimeName: "flux2-klein",
                libraryMatchFragment: "flux2-klein",
                approxSizeBytes: 4_619_599_348,
                ready: true,
                requiresSmokeVerification: false,
                gated: false,
                compatibilityNote: "Pro/latest image generation path"
            ),
            ImageCatalogModel(
                id: "z-image-turbo",
                displayName: "Z-Image Turbo 6-bit",
                repo: "carsenk/z-image-turbo-mflux-6bit",
                kind: .generate,
                runtimeName: "z-image-turbo",
                libraryMatchFragment: "z-image-turbo",
                approxSizeBytes: 8_447_545_588,
                ready: true,
                requiresSmokeVerification: false,
                gated: false,
                compatibilityNote: "Turbo image generation path"
            ),
        ]
    }
    // No image-edit models ship working yet. Qwen-Image-Edit lands back
    // here once vMLXFluxModels/QwenImage has a real generate() body.
    static let edit: [ImageCatalogModel] = []
    static let all: [ImageCatalogModel] = generate + edit
}

func imageCatalogEntry(
    for model: ImageCatalogModel,
    in entries: [ModelLibrary.ModelEntry]
) -> ModelLibrary.ModelEntry? {
    // Loose match: display name or repo contains the model's search
    // fragment. Avoids regex and lives in the explicit catalog, per
    // feedback_no_regex_explicit_settings.md.
    entries.first { entry in
        let needle = model.libraryMatchFragment.lowercased()
        let runtime = model.runtimeName.lowercased()
        let repoLeaf = model.repo.split(separator: "/").last.map(String.init)?.lowercased()
            ?? model.repo.lowercased()
        let display = entry.displayName.lowercased()
        let path = entry.canonicalPath.path.lowercased()
        return display.contains(needle)
            || path.contains(needle)
            || display.contains(runtime)
            || path.contains(runtime)
            || display.contains(repoLeaf)
            || path.contains(repoLeaf)
    }
}
