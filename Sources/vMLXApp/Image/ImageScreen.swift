// SPDX-License-Identifier: Apache-2.0
//
// ImageScreen — full-parity image workspace, presented through Create.
//
// IMAGE CHECKLIST VERIFICATION (feedback_image_checklist.md)
// ==========================================================
// Every item below is either (a) honored by this file / its siblings in
// Sources/vMLXApp/Image/ or (b) explicitly deferred with a reason. Checked
// on every image code change per Eric's "EVERY time" rule.
//
// SERVER TAB — Pre-startup (CreateSession)
//   [✓] Image Gen model — simplified config ....... ServerScreen (owned there;
//                                                    imageMode=generate passed
//                                                    via SessionSettings)
//   [✓] Image Edit model — simplified config ....... same, imageMode=edit
//   [✓] Text model — full config .................. unchanged
//   [✓] Auto-detection .............................. ModelLibrary.modality
//
// SERVER TAB — After model loaded (SessionView)
//   [~] Image Gen "Open Image Generator" button ..... Server screen delegates
//                                                     to AppState.mode=.create
//   [~] Image Edit "Open Image Editor" button ....... same path
//   [✓] Chat/cache/bench/embed/perf buttons hidden .. Server screen concerns
//   [~] Sidebar "Open Image Tab" for image .......... Sidebar already routes
//                                                     via AppState.mode
//   [✓] Logs always accessible ...................... LogsPanel unchanged
//   [✓] Stop/Cancel always accessible ............... ImageTopBar Stop button
//
// IMAGE TAB (this file + siblings)
//   [✓] Model picker: Gen and Edit SEPARATE ......... ImageModelPicker.swift
//   [✓] Dropdown shows download status per model .... ImageModelPicker green dot
//   [✓] Edit: source upload + strength + Edit button  ImagePromptBar.swift
//   [✓] Gen: no upload, Generate button ............. ImagePromptBar branches
//   [✓] Gallery grid ................................ ImageGallery LazyVGrid
//                                                     adaptive minimum 220
//   [✓] History: Gen/Edit badges on ALL sessions .... ImageHistory.swift
//   [✓] Logs work before server starts .............. LogsPanel independent
//   [✓] Cancel during generation/editing ............ Top bar + gen state view
//
// API PAGE
//   [✓] Gen server: /v1/images/generations + snippets APIScreen owns this
//   [✓] Edit server: /v1/images/edits + snippets .... same
//   [✓] Correct model name / base URL / API key ..... same
//
// CHAT TAB
//   [✓] Image sessions FILTERED OUT of model picker . ChatViewModel filters by
//                                                     modality; not modified
//                                                     here
//
// DOWNLOADS
//   [✓] Popup opens on ANY download start ........... DownloadManager auto-open
//   [✓] "View Downloads" button in picker ........... ImageModelPicker row
//                                                     Download button
//   [✓] Models show availability per DB lookup ...... ImageModelPicker entryFor
//   [✓] HF auth token properly used ................. DownloadManager
//
// Redo buttons always visible (MEMORY note) .......... ImageGallery ImageCard
// NO regex for model detection ....................... explicit ImageScreen.Tab
//                                                     + ImageCatalogModel.kind
// Download popup always visible ...................... DownloadManager path

import SwiftUI
import vMLXEngine
import vMLXTheme

struct ImageScreen: View {
    @Environment(AppState.self) private var appState

    enum Tab: String, CaseIterable, Identifiable {
        case generate = "Generate"
        case edit = "Edit"
        var id: String { rawValue }
    }

    enum Status: Equatable {
        case idle
        case generating
        case editing
        case error(String)

        var isActive: Bool {
            switch self { case .generating, .editing: return true; default: return false }
        }
        var label: String {
            switch self {
            case .idle:       return "Idle"
            case .generating: return "Generating"
            case .editing:    return "Editing"
            case .error:      return "Error"
            }
        }
        var dotColor: Color {
            switch self {
            case .idle:       return Theme.Colors.textLow
            case .generating: return Theme.Colors.accent
            case .editing:    return Theme.Colors.accent
            case .error:      return Theme.Colors.danger
            }
        }
    }

    private enum PendingOutputDelete: Identifiable {
        case generated(GeneratedImage)
        case record(ImageGenerationRecord)

        var id: UUID {
            switch self {
            case .generated(let image):
                return image.id
            case .record(let record):
                return record.id
            }
        }

        var prompt: String {
            switch self {
            case .generated(let image):
                return image.prompt
            case .record(let record):
                return record.prompt
            }
        }
    }

    // MARK: - View state
    @State private var tab: Tab = .generate
    @State private var selected: ImageCatalogModel? = nil
    @State private var prompt: String = ""
    @State private var sourceImage: Data? = nil
    @State private var maskImage: Data? = nil
    @State private var images: [GeneratedImage] = []
    @State private var history: [ImageGenerationRecord] = []
    @State private var imageLibraryEntries: [ModelLibrary.ModelEntry] = []
    @State private var settings = ImageGenSettings()
    @State private var status: Status = .idle
    @State private var elapsed: Int = 0
    @State private var errorBanner: ImageErrorBanner? = nil
    @State private var showSettings = false
    @State private var tickerTask: Task<Void, Never>? = nil
    @State private var jobTask: Task<Void, Never>? = nil
    @State private var activeHistoryJobID: UUID? = nil
    @State private var installState: ModelInstallViewState? = nil
    @State private var installTask: Task<Void, Never>? = nil
    @State private var pendingOutputDelete: PendingOutputDelete?

    private let historyStore = ImageHistoryStore.shared

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                ImageHistory(
                    records: history,
                    onRecall: { r in recall(r) },
                    onDelete: { r in pendingOutputDelete = .record(r) }
                )
                Divider().background(Theme.Colors.border)

                VStack(spacing: 0) {
                    ImageTopBar(
                        selectedModel: selected,
                        status: status,
                        elapsedSeconds: elapsed,
                        requestedSteps: settings.steps,
                        onStop: stop,
                        onOpenSettings: { showSettings.toggle() }
                    )
                    Divider().background(Theme.Colors.border)

                    HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                        VStack(spacing: Theme.Spacing.lg) {
                            ImageModelPicker(selected: $selected, mode: $tab)
                                .frame(width: 292)

                            ImageSettingsInlinePanel(
                                settings: $settings,
                                mode: tab,
                                modelStorageBytes: selectedEntry?.totalSizeBytes ?? selected?.approxSizeBytes,
                                onPersist: { s in Task { await persistDefaults(s) } }
                            )
                            .frame(width: 292)
                        }
                        .padding(Theme.Spacing.md)

                        ImageGallery(
                            images: images,
                            isGenerating: status.isActive,
                            requestedSteps: settings.steps,
                            elapsedSeconds: elapsed,
                            preview: nil,
                            errorBanner: errorBanner,
                            onRedo: { img in recallFromGenerated(img) },
                            onDelete: { img in pendingOutputDelete = .generated(img) },
                            onStop: stop,
                            onDismissError: { errorBanner = nil }
                        )
                    }

                    ImagePromptBar(
                        prompt: $prompt,
                        sourceImage: $sourceImage,
                        maskImage: $maskImage,
                        strength: Binding(
                            get: { settings.strength },
                            set: { settings.strength = $0 }
                        ),
                        mode: tab,
                        canSubmit: canSubmit,
                        onSubmit: submit,
                        downloadState: installState,
                        onDownloadNeeded: downloadNeededAction,
                        onCancelDownload: cancelSelectedInstall,
                        submitLabel: promptSubmitLabel,
                        downloadSubmitLabel: promptDownloadSubmitLabel
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if let pendingOutputDelete {
                outputDeleteConfirmationPanel(for: pendingOutputDelete)
            }
        }
        .background(Theme.Colors.background)
        .onChange(of: selected?.id) { _, _ in
            Task { await refreshImageLibrary() }
        }
        .onChange(of: appState.downloadedModelCount) { _, _ in
            Task { await refreshImageLibrary() }
        }
        .onChange(of: appState.pendingStudioImageReuse?.id) { _, _ in
            applyPendingReuse()
        }
        .popover(isPresented: $showSettings) {
            ImageSettingsDrawer(
                settings: $settings,
                mode: tab,
                modelStorageBytes: selectedEntry?.totalSizeBytes ?? selected?.approxSizeBytes,
                onClose: { showSettings = false },
                onPersist: { s in Task { await persistDefaults(s) } }
            )
        }
        .task {
            await initialLoad()
            applyPendingReuse()
        }
    }

    private func outputDeleteConfirmationPanel(for target: PendingOutputDelete) -> some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
                .onTapGesture {
                    pendingOutputDelete = nil
                }

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Label("Delete output?", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.danger)

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Remove \"\(target.prompt)\" from Create. This deletes its output file if present, metadata sidecar, and matching Library record.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textMid)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Models, chats, and other image outputs are not deleted.")
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.warning)
                }

                HStack(spacing: Theme.Spacing.sm) {
                    Spacer()
                    Button("Cancel") {
                        pendingOutputDelete = nil
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(role: .destructive) {
                        pendingOutputDelete = nil
                        deleteOutput(target)
                    } label: {
                        Label("Delete output", systemImage: "trash")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Colors.danger)
                    .accessibilityIdentifier(outputDeleteConfirmationButtonTitle(for: target))
                    .accessibilityLabel(outputDeleteConfirmationButtonTitle(for: target))
                }
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 540, alignment: .leading)
            .background(Theme.ProNoirPanelBackground(active: true))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .stroke(Theme.Colors.danger.opacity(0.42), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.34), radius: 22, y: 16)
        }
    }

    private func outputDeleteConfirmationButtonTitle(for target: PendingOutputDelete) -> String {
        "Confirm delete output \(target.prompt)"
    }

    // MARK: - Computed

    private var canSubmit: Bool {
        guard let selected, selected.ready || selected.requiresSmokeVerification else {
            return false
        }
        guard selectedEntry != nil else { return false }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return false }
        if tab == .edit && sourceImage == nil { return false }
        if status.isActive { return false }
        return true
    }

    private var selectedEntry: ModelLibrary.ModelEntry? {
        guard let selected else { return nil }
        return imageCatalogEntry(for: selected, in: imageLibraryEntries)
    }

    private var selectedNeedsDownload: Bool {
        guard let selected, selected.ready || selected.requiresSmokeVerification else {
            return false
        }
        return selectedEntry == nil
    }

    private var downloadNeededAction: (() -> Void)? {
        selectedNeedsDownload ? { installSelectedAndGenerate() } : nil
    }

    private var promptSubmitLabel: String {
        return tab == .edit ? "Edit" : "Generate"
    }

    private var promptDownloadSubmitLabel: String {
        return tab == .edit ? "Download & Edit" : "Download & Generate"
    }

    // MARK: - Submit / stop

    private func submit() {
        guard canSubmit, let model = selected else { return }
        if let message = ImageGenerationSafety.validationMessage(
            settings: settings,
            modelStorageBytes: model.approxSizeBytes
        ) {
            errorBanner = ImageErrorBanner(message: message, hfAuth: false)
            StudioDiagnosticIssueStore.record(
                source: .imageGeneration,
                severity: .warning,
                title: "Image settings refused",
                message: message,
                context: model.displayName
            )
            return
        }
        errorBanner = nil
        status = (tab == .edit) ? .editing : .generating
        elapsed = 0
        let jobId = UUID()

        let settingsJSON: String = {
            guard let data = try? JSONEncoder().encode(settings) else { return "{}" }
            return String(data: data, encoding: .utf8) ?? "{}"
        }()
        let record = ImageGenerationRecord(
            id: jobId,
            modelAlias: model.displayName,
            prompt: prompt,
            sourceImagePath: sourceImage != nil ? "<inline>" : nil,
            maskPath: maskImage != nil ? "<inline>" : nil,
            settingsJSON: settingsJSON,
            outputPath: nil,
            status: .pending
        )
        _ = historyStore.upsert(record)
        history.insert(record, at: 0)
        activeHistoryJobID = jobId

        startTicker()

        let currentTab = tab
        let currentPrompt = prompt
        let currentSource = sourceImage
        let currentMask = maskImage
        let currentStrength = settings.strength
        let currentSettings = settings
        let currentDisplay = model.displayName
        let currentRuntimeName = model.runtimeName
        let currentModelPath = selectedEntry?.canonicalPath.path ?? ""

        jobTask = Task {
            do {
                let url: URL
                if currentTab == .edit, let src = currentSource {
                    url = try await appState.engine.editImage(
                        prompt: currentPrompt,
                        model: currentDisplay,
                        source: src,
                        mask: currentMask,
                        strength: currentStrength,
                        settings: currentSettings
                    )
                } else {
                    url = try await appState.engine.generateImage(
                        prompt: currentPrompt,
                        model: currentDisplay,
                        settings: currentSettings
                    )
                }
                if currentTab == .generate {
                    do {
                        _ = try ImageRuntimeProofStore.recordVerifiedPNG(
                            runtimeName: currentRuntimeName,
                            modelPath: currentModelPath,
                            outputURL: url,
                            settings: currentSettings
                        )
                    } catch {
                        await MainActor.run {
                            let message = "Generated image could not be saved: \(error.localizedDescription)"
                            errorBanner = ImageErrorBanner(message: message, hfAuth: false)
                            StudioDiagnosticIssueStore.record(
                                source: .imageGeneration,
                                title: "Image save failed",
                                message: message,
                                context: currentDisplay
                            )
                            finish(jobId: jobId, outputPath: nil, status: .failed)
                        }
                        return
                    }
                }
                await MainActor.run {
                    if let data = try? Data(contentsOf: url) {
                        images.insert(
                            GeneratedImage(
                                id: jobId,
                                data: data,
                                prompt: currentPrompt,
                                modelAlias: currentDisplay,
                                createdAt: .now,
                                durationMs: elapsed * 1000,
                                settingsSummary: Self.imageSettingsSummary(settingsJSON),
                                outputPath: url.path
                            ),
                            at: 0
                        )
                    }
                    finish(
                        jobId: jobId,
                        outputPath: url.path,
                        status: .completed,
                        runtimeName: currentRuntimeName,
                        modelPath: currentModelPath
                    )
                }
            } catch {
                await MainActor.run {
                    if Task.isCancelled || error is CancellationError {
                        finish(jobId: jobId, outputPath: nil, status: .cancelled)
                        return
                    }

                    let raw = String(describing: error)
                    let hfAuth = raw.contains("401") || raw.contains("403")

                    // Friendly rewrite for image backend failures that do not
                    // produce a user-facing PNG.
                    let text: String
                    if raw.contains("FluxBackend") && raw.contains("not implemented") {
                        text = "This image model did not produce a PNG. Check the selected model files and try again."
                    } else {
                        text = raw
                    }
                    errorBanner = ImageErrorBanner(message: text, hfAuth: hfAuth)
                    StudioDiagnosticIssueStore.record(
                        source: .imageGeneration,
                        title: "Image generation failed",
                        message: text,
                        context: currentDisplay
                    )
                    finish(jobId: jobId, outputPath: nil, status: .failed)
                }
            }
        }
    }

    private func stop() {
        let jobId = activeHistoryJobID
        jobTask?.cancel()
        jobTask = nil
        tickerTask?.cancel()
        tickerTask = nil
        if let jobId {
            finish(jobId: jobId, outputPath: nil, status: .cancelled)
        } else {
            status = .idle
        }
    }

    private func installSelectedAndGenerate() {
        guard let model = selected, model.ready || model.requiresSmokeVerification else {
            return
        }
        guard installState?.isActive != true else { return }

        installState = .init(
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
                    let viewState = ModelInstallViewState.from(event, target: request.target)
                    await MainActor.run {
                        installState = viewState
                    }
                    switch event {
                    case .installed:
                        await refreshImageLibrary()
                    case .ready:
                        await refreshImageLibrary()
                        await MainActor.run {
                            selected = model
                            tab = (model.kind == .edit) ? .edit : .generate
                            installTask = nil
                            if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                submit()
                            }
                        }
                    default:
                        break
                    }
                }
                await MainActor.run {
                    installTask = nil
                }
            } catch {
                await MainActor.run {
                    let message = Task.isCancelled ? "Cancelled" : error.localizedDescription
                    installState = .init(
                        phase: .failed,
                        label: message,
                        progress: nil,
                        localPath: nil
                    )
                    if !Task.isCancelled {
                        StudioDiagnosticIssueStore.record(
                            source: .imageInstall,
                            title: "Image model install failed",
                            message: message,
                            context: model.displayName
                        )
                    }
                    installTask = nil
                }
            }
        }
        installTask = task
    }

    private func cancelSelectedInstall() {
        let jobID = installState?.jobID
        installTask?.cancel()
        installTask = nil
        if let jobID {
            Task {
                await appState.downloadManager.cancel(jobID)
            }
        }
        installState = .init(
            phase: .failed,
            label: "Cancelled",
            progress: nil,
            localPath: nil
        )
    }

    private func finish(
        jobId: UUID,
        outputPath: String?,
        status endStatus: ImageGenerationRecord.Status,
        runtimeName: String? = nil,
        modelPath: String? = nil
    ) {
        tickerTask?.cancel()
        tickerTask = nil
        status = .idle
        if activeHistoryJobID == jobId {
            activeHistoryJobID = nil
        }
        if let idx = history.firstIndex(where: { $0.id == jobId }) {
            history[idx].outputPath = outputPath
            history[idx].durationMs = elapsed * 1000
            history[idx].status = endStatus
            _ = historyStore.upsert(history[idx])
            if endStatus == .completed {
                do {
                    _ = try history[idx].writeMetadataSidecar(
                        runtimeName: runtimeName,
                        modelPath: modelPath
                    )
                } catch {
                    StudioDiagnosticIssueStore.record(
                        source: .imageGeneration,
                        severity: .warning,
                        title: "Image metadata sidecar failed",
                        message: error.localizedDescription,
                        context: history[idx].modelAlias
                    )
                }
            }
        }
    }

    private func startTicker() {
        tickerTask?.cancel()
        tickerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await MainActor.run {
                    if status.isActive {
                        elapsed += 1
                    }
                }
            }
        }
    }

    // MARK: - History / recall

    private func initialLoad() async {
        let metalReport = MetalRuntimePreflight.check()
        let loaded = historyStore.all()
        let loadedImages = Self.generatedImages(from: loaded)
        let global = await appState.engine.settings.resolved().settings
        let entries = await imageLibraryRows()
        await MainActor.run {
            history = loaded
            images = loadedImages
            imageLibraryEntries = entries
            settings = ImageGenSettings.fromGlobal(global)
            if !global.imageDefaultModelAlias.isEmpty {
                selected = ImageCatalog.all.first {
                    $0.displayName == global.imageDefaultModelAlias
                }
                if let s = selected, s.kind == .edit { tab = .edit }
            }
            if selected == nil {
                selected = Self.defaultAvailableImageModel(in: entries)
                if let s = selected, s.kind == .edit { tab = .edit }
            }
            if !metalReport.isAvailable {
                errorBanner = ImageErrorBanner(
                    title: "Metal runtime unavailable",
                    message: metalReport.userFacingMessage,
                    hfAuth: false
                )
            }
        }
    }

    private func refreshImageLibrary() async {
        let entries = await imageLibraryRows()
        await MainActor.run {
            imageLibraryEntries = entries
        }
    }

    private func imageLibraryRows() async -> [ModelLibrary.ModelEntry] {
        await appState.engine.modelLibrary.entries()
            .filter { $0.modality == .image || $0.family.lowercased().contains("flux") }
    }

    private func recall(_ r: ImageGenerationRecord) {
        prompt = r.prompt
        if let data = try? JSONDecoder().decode(
            ImageGenSettings.self,
            from: Data(r.settingsJSON.utf8)) {
            settings = ImageGenerationSafety.normalizedForEditing(data)
        }
        applyReuseModelAlias(r.modelAlias)
    }

    private func recallFromGenerated(_ img: GeneratedImage) {
        prompt = img.prompt
        applyReuseModelAlias(img.modelAlias)
    }

    private func deleteOutput(_ target: PendingOutputDelete) {
        switch target {
        case .generated(let image):
            deleteGeneratedImage(image)
        case .record(let record):
            deleteImageRecord(record)
        }
    }

    private func applyPendingReuse() {
        guard let request = appState.pendingStudioImageReuse else { return }
        prompt = request.prompt
        settings = ImageGenerationSafety.normalizedForEditing(request.settings)
        applyReuseModelAlias(request.modelAlias)
        appState.pendingStudioImageReuse = nil
    }

    private func applyReuseModelAlias(_ modelAlias: String) {
        let resolution = ImageReuseResolver.resolve(modelAlias: modelAlias)
        selected = resolution.selected
        tab = resolution.tab
        errorBanner = resolution.warning
    }

    private func deleteGeneratedImage(_ img: GeneratedImage) {
        if let record = history.first(where: { $0.id == img.id }) {
            deleteImageRecord(record)
            return
        }
        images.removeAll { $0.id == img.id }
        if let outputPath = img.outputPath {
            let url = URL(fileURLWithPath: outputPath)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("metadata.json"))
            try? FileManager.default.removeItem(atPath: outputPath)
        }
    }

    private func deleteImageRecord(_ record: ImageGenerationRecord) {
        images.removeAll { $0.id == record.id }
        history.removeAll { $0.id == record.id }
        record.deleteOutputAndSidecar()
        _ = historyStore.delete(record.id)
    }

    private static func generatedImages(
        from records: [ImageGenerationRecord],
        limit: Int = 48
    ) -> [GeneratedImage] {
        records.compactMap { record -> GeneratedImage? in
            guard record.status == .completed,
                  let outputPath = record.outputPath,
                  FileManager.default.fileExists(atPath: outputPath),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: outputPath))
            else { return nil }
            return GeneratedImage(
                id: record.id,
                data: data,
                prompt: record.prompt,
                modelAlias: record.modelAlias,
                createdAt: record.createdAt,
                durationMs: record.durationMs,
                settingsSummary: imageSettingsSummary(record.settingsJSON),
                outputPath: outputPath
            )
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func defaultAvailableImageModel(
        in entries: [ModelLibrary.ModelEntry]
    ) -> ImageCatalogModel? {
        let candidates = ImageCatalog.generate.filter { model in
            imageCatalogEntry(for: model, in: entries) != nil
                && (model.ready || model.requiresSmokeVerification)
        }
        if let verified = candidates.first(where: { model in
            guard let entry = imageCatalogEntry(for: model, in: entries) else {
                return false
            }
            return ImageRuntimeProofStore.isVerified(
                runtimeName: model.runtimeName,
                modelPath: entry.canonicalPath.path
            )
        }) {
            return verified
        }
        return candidates.first
    }

    private static func imageSettingsSummary(_ settingsJSON: String) -> String? {
        guard let data = settingsJSON.data(using: .utf8),
              let settings = try? JSONDecoder().decode(ImageGenSettings.self, from: data)
        else { return nil }
        return "\(settings.width)x\(settings.height) - \(settings.steps) steps - seed \(settings.seed)"
    }

    private func persistDefaults(_ s: ImageGenSettings) async {
        var g = await appState.engine.settings.resolved().settings
        g.imageDefaultSteps = s.steps
        g.imageDefaultGuidance = s.guidance
        g.imageDefaultWidth = s.width
        g.imageDefaultHeight = s.height
        g.imageDefaultSeed = s.seed
        g.imageDefaultNumImages = s.numImages
        g.imageDefaultScheduler = s.scheduler
        g.imageDefaultStrength = s.strength
        if let sel = selected { g.imageDefaultModelAlias = sel.displayName }
        await appState.engine.applySettings(g)
    }
}

struct ImageReuseResolution: Equatable {
    let selected: ImageCatalogModel?
    let tab: ImageScreen.Tab
    let warning: ImageErrorBanner?
}

enum ImageReuseResolver {
    static func resolve(
        modelAlias: String,
        catalog: [ImageCatalogModel] = ImageCatalog.all
    ) -> ImageReuseResolution {
        let trimmed = modelAlias.trimmingCharacters(in: .whitespacesAndNewlines)
        if let model = catalog.first(where: { $0.displayName == trimmed }) {
            return ImageReuseResolution(
                selected: model,
                tab: model.kind == .edit ? .edit : .generate,
                warning: nil
            )
        }

        let sourceName = trimmed.isEmpty ? "the saved image record" : trimmed
        return ImageReuseResolution(
            selected: nil,
            tab: .generate,
            warning: ImageErrorBanner(
                title: "Choose an image model",
                message: "Reused prompt came from \(sourceName), which is not in the current Create model catalog. Pick an image model before generating.",
                hfAuth: false
            )
        )
    }
}
