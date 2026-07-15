import SwiftUI
import vMLXEngine
import vMLXTheme

#if canImport(AppKit)
import AppKit
#endif

struct ModelInstallViewState: Equatable {
    enum Phase: Equatable {
        case queued
        case downloading
        case verifying
        case installed
        case loading
        case ready
        case failed
    }

    var phase: Phase
    var label: String
    var progress: Double?
    var localPath: String?
    var jobID: JobID? = nil

    var isActive: Bool {
        switch phase {
        case .queued, .downloading, .verifying, .loading:
            return true
        case .installed, .ready, .failed:
            return false
        }
    }

    static func from(
        _ event: ModelInstallEvent,
        target: ModelInstallTarget = .chat
    ) -> ModelInstallViewState {
        switch event {
        case .queued(let jobID):
            return .init(phase: .queued, label: "Queued", progress: 0, localPath: nil, jobID: jobID)
        case .downloading(let progress):
            return .init(
                phase: .downloading,
                label: progress.label,
                progress: progress.fraction,
                localPath: nil,
                jobID: progress.jobID
            )
        case .verifying(let progress):
            return .init(
                phase: .verifying,
                label: "Verifying files",
                progress: 1,
                localPath: nil,
                jobID: progress.jobID
            )
        case .installed(let model):
            return .init(
                phase: .installed,
                label: "Installed \(model.ref.displayName)",
                progress: 1,
                localPath: model.ref.localURL?.path
            )
        case .loading(let model):
            return .init(
                phase: .loading,
                label: "Loading \(model.ref.displayName)",
                progress: nil,
                localPath: model.ref.localURL?.path
            )
        case .ready(let model):
            let label: String
            switch target {
            case .chat:
                label = "Ready in Chat: \(model.ref.displayName)"
            case .image:
                label = "Ready to Generate: \(model.ref.displayName)"
            }
            return .init(
                phase: .ready,
                label: label,
                progress: 1,
                localPath: model.ref.localURL?.path
            )
        case .failed(let message):
            return .init(phase: .failed, label: message, progress: nil, localPath: nil)
        }
    }
}

struct StudioCreateScreen: View {
    var body: some View {
        ImageScreen()
    }
}

struct StudioModelsScreen: View {
    @Environment(AppState.self) private var app
    @ObservedObject private var hfAuth = HuggingFaceAuth.shared
    @State private var localModels: [ModelSummary] = []
    @State private var recommended: [RecommendedModel] = []
    @State private var hubQuery = "qwen"
    @State private var hubModels: [HubModelCandidate] = []
    @State private var installStates: [String: ModelInstallViewState] = [:]
    @State private var isSearchingHub = false
    @State private var selectedID: String?
    @State private var pendingDeleteModel: ModelSummary?
    @State private var isModelToolsPresented = false
    @State private var status = "Ready"

    private var selectedModel: ModelSummary? {
        localModels.first { $0.id == selectedID }
    }

    private var gateStatus: HuggingFaceGateStatus {
        HuggingFaceGateStatus.evaluate(
            hasToken: hfAuth.hasToken,
            validation: hfAuth.validation
        )
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                StudioToolbar(title: "Models", subtitle: status) {
                    Button {
                        isModelToolsPresented = true
                    } label: {
                        Label("Model Tools", systemImage: "wrench.and.screwdriver")
                    }
                    Button {
                        addDirectory()
                    } label: {
                        Label(L10n.Studio.addFolder.render(AppLocalePreference.current), systemImage: "folder.badge.plus")
                    }
                    Button {
                        Task { await refresh(force: true) }
                    } label: {
                        Label(L10n.Studio.refresh.render(AppLocalePreference.current), systemImage: "arrow.clockwise")
                    }
                }
                Divider().background(Theme.Colors.border)
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        modelCommandCenter

                        sectionHeader(
                            "Ready Now",
                            subtitle: "Installed local models grouped by what you can do without leaving this Mac."
                        )
                        if localModels.isEmpty {
                            EmptyStateView(
                                systemImage: "square.stack.3d.up",
                                title: "No local models",
                                caption: "Add a model folder or download a starter model.",
                                cta: ("Add Folder", addDirectory)
                            )
                            .frame(minHeight: 220)
                        } else {
                            VStack(spacing: Theme.Spacing.sm) {
                                ForEach(localModels) { model in
                                    ModelRow(model: model, selected: selectedID == model.id) {
                                        selectLocalModel(model)
                                    } load: {
                                        Task { await load(model) }
                                    } chat: {
                                        Task { await chat(model) }
                                    } create: {
                                        selectLocalModel(model)
                                        app.mode = .create
                                    } delete: {
                                        pendingDeleteModel = model
                                    }
                                }
                            }
                        }

                        sectionHeader(
                            "Recommended Starters",
                            subtitle: "Small, proven downloads for getting a first local result without model hunting."
                        )
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: Theme.Spacing.md)], spacing: Theme.Spacing.md) {
                            ForEach(recommended) { model in
                                ModelRecommendationCard(
                                    model: model,
                                    installState: installState(for: model.ref),
                                    queue: { install(model.ref, source: .recommended, openChat: false) },
                                    downloadAndChat: { install(model.ref, source: .recommended, openChat: true) }
                                )
                            }
                        }

                        hubSelector
                    }
                    .padding(Theme.Spacing.xl)
                }
            }

            if let pendingDeleteModel {
                deleteConfirmationPanel(for: pendingDeleteModel)
            }
        }
        .tint(Theme.Colors.accent)
        .background(Theme.ProNoirBackground())
        .task { await refresh(force: false) }
        .sheet(isPresented: $isModelToolsPresented) {
            StudioModelToolsScreen()
                .environment(app)
                .frame(minWidth: 980, minHeight: 680)
        }
        .onChange(of: app.selectedModelPath) { _, _ in
            Task { await refresh(force: false) }
        }
    }

    private func deleteConfirmationPanel(for model: ModelSummary) -> some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
                .onTapGesture {
                    pendingDeleteModel = nil
                }

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Label(StudioModelDeleteCopy.confirmationTitle, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.danger)

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(StudioModelDeleteCopy.diskRemovalMessage(for: model))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textMid)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(StudioModelDeleteCopy.recordWarning)
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.warning)
                }

                HStack(spacing: Theme.Spacing.sm) {
                    Spacer()
                    Button("Cancel") {
                        pendingDeleteModel = nil
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(role: .destructive) {
                        pendingDeleteModel = nil
                        Task { await delete(model) }
                    } label: {
                        Label(StudioModelDeleteCopy.confirmationButtonTitle(for: model), systemImage: "trash")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Colors.danger)
                    .accessibilityIdentifier(StudioModelDeleteCopy.confirmationButtonTitle(for: model))
                    .accessibilityLabel(StudioModelDeleteCopy.confirmationButtonTitle(for: model))
                }
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 520, alignment: .leading)
            .background(Theme.ProNoirPanelBackground(active: true))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .stroke(Theme.Colors.danger.opacity(0.42), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.34), radius: 22, y: 16)
            .accessibilityElement(children: .contain)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(Theme.Typography.title)
            .foregroundStyle(Theme.Colors.textHigh)
    }

    private func sectionHeader(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            sectionTitle(title)
            Text(subtitle)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textMid)
        }
    }

    private var modelCommandCenter: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            modelDecisionPanel
                .frame(minWidth: 360, maxWidth: .infinity, alignment: .topLeading)

            modelOverview
                .frame(minWidth: 420, maxWidth: 560, alignment: .topTrailing)
        }
    }

    private var modelDecisionPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Label(L10n.Studio.bestReadyAction.render(AppLocalePreference.current), systemImage: "scope")
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.accent)
                    Text(modelDecisionTitle)
                        .font(.system(size: 24, weight: .semibold, design: .default))
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(2)
                    Text(modelDecisionCaption)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textMid)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.md)
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .fill(Theme.Colors.surfaceHi.opacity(0.72))
                    Image(systemName: decisionModel.map(modelIcon) ?? "square.stack.3d.up")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(decisionModel.map(modelTint) ?? Theme.Colors.textMid)
                }
                .frame(width: 64, height: 64)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .stroke(Theme.Colors.borderHi, lineWidth: 1)
                )
            }

            if let model = decisionModel {
                let routeReadiness = StudioModelRouteReadiness.summary(for: model)
                let modelIsImage = isImageModel(model)
                let selectActionTitle = StudioModelActionCopy.selectAccessibilityTitle(for: model, selected: selectedID == model.id)
                let loadActionTitle = StudioModelActionCopy.loadAccessibilityTitle(for: model, readiness: routeReadiness)
                let routeActionTitle = StudioModelActionCopy.routeAccessibilityTitle(
                    for: model,
                    readiness: routeReadiness,
                    isImage: modelIsImage
                )
                HStack(spacing: Theme.Spacing.sm) {
                    modelFactPill("Mode", model.modality.capitalized, systemImage: modelIcon(model), tint: modelTint(model))
                    modelFactPill("Size", formattedBytes(model.sizeBytes), systemImage: "internaldrive", tint: Theme.Colors.success)
                    modelFactPill(
                        "State",
                        model.isLoaded ? "Loaded" : selectedID == model.id ? "Selected" : "Ready",
                        systemImage: model.isLoaded ? "bolt.fill" : "checkmark.circle",
                        tint: model.isLoaded ? Theme.Colors.success : Theme.Colors.accent
                    )
                }

                HStack(spacing: Theme.Spacing.sm) {
                    Button {
                        selectLocalModel(model)
                    } label: {
                        Label(selectedID == model.id ? "Selected" : "Select", systemImage: selectedID == model.id ? "checkmark.circle.fill" : "target")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(selectActionTitle)
                    .accessibilityIdentifier(selectActionTitle)

                    Button {
                        Task { await load(model) }
                    } label: {
                        Label(routeReadiness.loadTitle, systemImage: "bolt")
                    }
                    .buttonStyle(.bordered)
                    .disabled(routeReadiness.loadDisabledReason != nil)
                    .accessibilityLabel(loadActionTitle)
                    .accessibilityIdentifier(loadActionTitle)
                    .help(routeReadiness.loadDisabledReason ?? "Load this chat model into memory.")

                    if modelIsImage {
                        Button {
                            selectLocalModel(model)
                            app.mode = .create
                        } label: {
                            Label(routeReadiness.actionTitle, systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel(routeActionTitle)
                        .accessibilityIdentifier(routeActionTitle)
                    } else {
                        Button {
                            Task { await chat(model) }
                        } label: {
                            Label(L10n.Studio.chat.render(AppLocalePreference.current), systemImage: "bubble.left.and.bubble.right")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel(routeActionTitle)
                        .accessibilityIdentifier(routeActionTitle)
                    }
                }
            } else {
                HStack(spacing: Theme.Spacing.sm) {
                    Button {
                        addDirectory()
                    } label: {
                        Label(L10n.Studio.addFolder.render(AppLocalePreference.current), systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)

                    Text(L10n.Studio.orChooseStarterBelow.render(AppLocalePreference.current))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background(Theme.ProNoirPanelBackground(active: true))
    }

    private var modelOverview: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 168), spacing: Theme.Spacing.md)],
            spacing: Theme.Spacing.md
        ) {
            modelOverviewTile(
                "Ready Now",
                value: "\(localModels.count)",
                caption: localModels.isEmpty ? "Scan a folder or download a starter" : "Installed local model\(localModels.count == 1 ? "" : "s")",
                systemImage: "checkmark.seal",
                tint: Theme.Colors.success
            )
            modelOverviewTile(
                "Recommended Starters",
                value: recommended.isEmpty ? "Load" : "\(recommended.count)",
                caption: "Small downloads for a first local result",
                systemImage: "sparkles",
                tint: Theme.Colors.accent
            )
            modelOverviewTile(
                "Compatible Hub",
                value: hubModels.isEmpty ? "Search" : "\(hubModels.count)",
                caption: "HF auth: \(gateStatus.value)",
                systemImage: "sparkle.magnifyingglass",
                tint: Theme.Colors.creative,
                action: hubQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : searchHub
            )
            modelOverviewTile(
                "Local folders",
                value: "Add",
                caption: "Bring your own model directory",
                systemImage: "folder.badge.plus",
                tint: Theme.Colors.textMid,
                action: addDirectory
            )
        }
    }

    private var decisionModel: ModelSummary? {
        selectedModel
            ?? localModels.first { $0.isLoaded }
            ?? localModels.first
    }

    private var modelDecisionTitle: String {
        guard let model = decisionModel else {
            return "Bring one model into the studio"
        }
        if model.isLoaded {
            return "\(model.ref.displayName) is live"
        }
        if selectedID == model.id {
            return "\(model.ref.displayName) is selected"
        }
        return model.ref.displayName
    }

    private var modelDecisionCaption: String {
        guard let model = decisionModel else {
            return "Add a local folder or download a starter. The app should always make the next useful move obvious."
        }
        return StudioModelRouteReadiness.summary(for: model).decisionCaption
    }

    private func modelFactPill(_ title: String, _ value: String, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                Text(value)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(Theme.Colors.surfaceHi.opacity(0.54))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func modelOverviewTile(
        _ title: String,
        value: String,
        caption: String,
        systemImage: String,
        tint: Color,
        action: (() -> Void)? = nil
    ) -> some View {
        if let action {
            Button(action: action) {
                modelOverviewTileBody(
                    title,
                    value: value,
                    caption: caption,
                    systemImage: systemImage,
                    tint: tint,
                    active: true
                )
            }
            .buttonStyle(.plain)
        } else {
            modelOverviewTileBody(
                title,
                value: value,
                caption: caption,
                systemImage: systemImage,
                tint: tint,
                active: false
            )
            .accessibilityElement(children: .combine)
        }
    }

    private func modelOverviewTileBody(
        _ title: String,
        value: String,
        caption: String,
        systemImage: String,
        tint: Color,
        active: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textLow)
                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .default))
                    .foregroundStyle(Theme.Colors.textHigh)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(Theme.ProNoirPanelBackground(active: active))
    }

    private var hubSelector: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(spacing: Theme.Spacing.sm) {
                        sectionTitle("Compatible Hub")
                        Label(L10n.Studio.vmlxRuntime.render(AppLocalePreference.current), systemImage: "checkmark.seal")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textMid)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.Colors.surfaceHi)
                            .clipShape(Capsule())
                        Text(L10n.Studio.mlxJangHf.render(AppLocalePreference.current))
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textLow)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.Colors.surfaceHi)
                            .clipShape(Capsule())
                        Spacer()
                    }

                    hubAuthStatusRow

                    HStack(spacing: Theme.Spacing.sm) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(Theme.Colors.textMid)
                            TextField("Search Hugging Face", text: $hubQuery)
                                .textFieldStyle(.plain)
                                .font(Theme.Typography.body)
                                .accessibilityLabel(L10n.Studio.searchHuggingFace.render(AppLocalePreference.current))
                                .onSubmit { searchHub() }
                            if !hubQuery.isEmpty {
                                Button {
                                    hubQuery = ""
                                    hubModels = []
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.Colors.textLow)
                            }
                        }
                        .padding(.horizontal, Theme.Spacing.md)
                        .padding(.vertical, 9)
                        .background(Theme.Colors.surface.opacity(0.84))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                                .stroke(Theme.Colors.borderHi, lineWidth: 1)
                        )

                        Button {
                            searchHub()
                        } label: {
                            if isSearchingHub {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Label(L10n.Studio.search.render(AppLocalePreference.current), systemImage: "sparkle.magnifyingglass")
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityLabel(L10n.Studio.runHubSearch.render(AppLocalePreference.current))
                        .disabled(isSearchingHub || hubQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }

                DeAlignMascotMark()
                    .frame(width: 54, height: 60)
                    .opacity(0.86)
                    .accessibilityHidden(true)
            }
            .padding(Theme.Spacing.lg)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .fill(Theme.Colors.surface.opacity(0.90))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.lg)
                            .stroke(Theme.Colors.borderHi, lineWidth: 1)
                    )
            )

            if !hubModels.isEmpty {
                HStack(spacing: Theme.Spacing.sm) {
                    Label(L10n.Studio.compatibleResultsFormat.render(AppLocalePreference.current, hubModels.count), systemImage: "list.bullet.rectangle")
                    Spacer()
                    Text(hubModels.first?.updatedHint ?? "")
                }
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
            }

            if isSearchingHub {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.Studio.checkingRuntimeCompat.render(AppLocalePreference.current))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMid)
                    Spacer()
                }
                .padding(.vertical, Theme.Spacing.sm)
            } else if hubModels.isEmpty {
                EmptyStateView(
                    systemImage: "sparkle.magnifyingglass",
                    title: "No compatible Hub results"
                )
                .frame(minHeight: 160)
                .background(Theme.Colors.surface.opacity(0.88))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .stroke(Theme.Colors.border, lineWidth: 1)
                )
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: Theme.Spacing.md)], spacing: Theme.Spacing.md) {
                    ForEach(hubModels) { model in
                        HubModelCandidateCard(
                            model: model,
                            gateStatus: gateStatus,
                            installState: installState(for: model.ref),
                            queue: { install(model.ref, source: .huggingFace, openChat: false) },
                            downloadAndChat: { install(model.ref, source: .huggingFace, openChat: true) }
                        )
                    }
                }
            }
        }
    }

    private var hubAuthStatusRow: some View {
        let status = gateStatus
        return HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Label(L10n.Studio.hfAuth.render(AppLocalePreference.current), systemImage: hubAuthIcon(for: status.level))
                .font(Theme.Typography.captionHi)
                .foregroundStyle(hubAuthTint(for: status.level))
                .lineLimit(1)
            Text(status.value)
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textHigh)
                .lineLimit(1)
            Text(status.detail)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 8)
        .background(Theme.Colors.surfaceHi.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(hubAuthTint(for: status.level).opacity(0.28), lineWidth: 1)
        )
    }

    private func hubAuthIcon(for level: HuggingFaceGateStatus.Level) -> String {
        switch level {
        case .open:
            return "lock.open"
        case .stored:
            return "lock.shield"
        case .validating:
            return "arrow.triangle.2.circlepath"
        case .verified:
            return "checkmark.seal"
        case .invalid:
            return "exclamationmark.triangle"
        }
    }

    private func hubAuthTint(for level: HuggingFaceGateStatus.Level) -> Color {
        switch level {
        case .verified:
            return Theme.Colors.success
        case .invalid:
            return Theme.Colors.danger
        case .open, .stored, .validating:
            return Theme.Colors.warning
        }
    }

    private func refresh(force: Bool) async {
        let service = StudioModelService(app: app)
        do {
            if force {
                let library = await app.engine.modelLibrary
                _ = await library.scan(force: true)
            }
            localModels = try await service.listLocalModels()
            recommended = try await service.listRecommendedModels()
            if let selectedPath = app.selectedModelPath {
                selectedID = localModels.first(where: { $0.ref.localURL == selectedPath })?.id
            } else if let current = selectedID,
                      localModels.contains(where: { $0.id == current }) {
                selectedID = current
            } else {
                selectedID = nil
            }
            status = "\(localModels.count) local model\(localModels.count == 1 ? "" : "s")"
        } catch {
            status = error.localizedDescription
            StudioDiagnosticIssueStore.record(
                source: .modelInstall,
                title: "Model library refresh failed",
                message: error.localizedDescription,
                context: "Models"
            )
        }
    }

    private func searchHub() {
        Task { await performHubSearch() }
    }

    private func performHubSearch() async {
        let query = hubQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        isSearchingHub = true
        do {
            let service = StudioModelService(app: app)
            hubModels = try await service.searchCompatibleHubModels(query: query)
            status = hubModels.isEmpty
                ? "No compatible Hub models found"
                : "\(hubModels.count) compatible Hub model\(hubModels.count == 1 ? "" : "s")"
        } catch {
            status = error.localizedDescription
            hubModels = []
            StudioDiagnosticIssueStore.record(
                source: .modelInstall,
                title: "Hub model search failed",
                message: error.localizedDescription,
                context: query
            )
        }
        isSearchingHub = false
    }

    private func load(_ model: ModelSummary) async {
        do {
            selectedID = model.id
            try await StudioModelLoadService(app: app).loadModel(model.ref)
            status = "Loaded \(model.ref.displayName)"
            await refresh(force: true)
        } catch {
            status = error.localizedDescription
            StudioDiagnosticIssueStore.record(
                source: .chatLoad,
                title: "Model load failed",
                message: error.localizedDescription,
                context: model.ref.displayName
            )
        }
    }

    private func selectLocalModel(_ model: ModelSummary) {
        selectedID = model.id
        app.selectedModelPath = model.ref.localURL
        status = "Selected \(model.ref.displayName)"
    }

    private func isImageModel(_ model: ModelSummary) -> Bool {
        model.modality.localizedCaseInsensitiveContains("image")
    }

    private func modelIcon(_ model: ModelSummary) -> String {
        isImageModel(model) ? "wand.and.stars" : "bubble.left.and.bubble.right"
    }

    private func modelTint(_ model: ModelSummary) -> Color {
        isImageModel(model) ? Theme.Colors.creative : Theme.Colors.accent
    }

    private func chat(_ model: ModelSummary) async {
        selectLocalModel(model)
        app.mode = .chat
    }

    private func installState(for ref: ModelRef) -> ModelInstallViewState? {
        let key = ref.repo ?? ref.id
        return installStates[key]
    }

    private func install(_ ref: ModelRef, source: ModelInstallSource, openChat: Bool) {
        guard let repo = ref.repo else {
            status = StudioServiceError.modelNotLocal.localizedDescription
            return
        }
        if installStates[repo]?.isActive == true { return }

        let request = ModelInstallRequest(
            repo: repo,
            displayName: ref.displayName,
            source: source,
            openChatWhenReady: openChat
        )

        installStates[repo] = .init(
            phase: .queued,
            label: openChat ? "Preparing chat install" : "Queued",
            progress: 0,
            localPath: nil
        )
        status = installStates[repo]?.label ?? "Queued"

        Task {
            do {
                let stream = StudioModelInstallService(app: app).install(request)
                for try await event in stream {
                    let viewState = ModelInstallViewState.from(event)
                    installStates[repo] = viewState
                    status = viewState.label
                    switch event {
                    case .installed, .ready:
                        await refresh(force: true)
                        status = viewState.label
                    default:
                        break
                    }
                }
            } catch {
                installStates[repo] = .init(
                    phase: .failed,
                    label: error.localizedDescription,
                    progress: nil,
                    localPath: nil
                )
                status = error.localizedDescription
                StudioDiagnosticIssueStore.record(
                    source: .modelInstall,
                    title: "Model install failed",
                    message: error.localizedDescription,
                    context: ref.displayName
                )
            }
        }
    }

    private func delete(_ model: ModelSummary) async {
        do {
            let deletedSelection = selectedID == model.id || app.selectedModelPath == model.ref.localURL
            try await StudioModelService(app: app).deleteModel(model.ref)
            if deletedSelection {
                selectedID = nil
                app.selectedModelPath = nil
            }
            await refresh(force: true)
            status = StudioModelDeleteCopy.successStatus(for: model)
        } catch {
            status = error.localizedDescription
            StudioDiagnosticIssueStore.record(
                source: .modelInstall,
                title: "Model delete failed",
                message: error.localizedDescription,
                context: model.ref.displayName
            )
        }
    }

    private func addDirectory() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                await StudioModelService(app: app).addLocalModelDirectory(url)
                await refresh(force: true)
            }
        }
        #endif
    }
}

struct StudioServerScreen: View {
    @Environment(AppState.self) private var app
    @State private var config = ServerConfig()
    @State private var health = ServerHealth(status: .stopped, label: "Stopped", endpoint: "http://127.0.0.1:8000")
    @State private var routes: [APIRoute] = []
    @State private var serverModels: [ModelSummary] = []
    @State private var selectedRouteFamily = "All"
    @State private var routeSearch = ""
    @State private var status = "Ready"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                StudioToolbar(title: "Server", subtitle: serverSubtitle) {
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label(L10n.Studio.refresh.render(AppLocalePreference.current), systemImage: "arrow.clockwise")
                    }
                    Button {
                        copyEndpoint()
                    } label: {
                        Label(L10n.Studio.copyEndpoint.render(AppLocalePreference.current), systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("Server toolbar Copy Endpoint")
                    .accessibilityLabel(L10n.Studio.serverToolbarCopy.render(AppLocalePreference.current))
                }

                serverOverview

                AdvancedLabCard(
                    title: "Control Plane",
                    subtitle: health.label,
                    systemImage: "server.rack"
                ) {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                            serverControlInputs
                            runtimeContractPanel
                        }
                        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                            serverControlInputs
                            runtimeContractPanel
                        }
                    }
                }

                AdvancedLabCard(
                    title: "Route Inspector",
                    subtitle: routeSummary,
                    systemImage: "point.3.connected.trianglepath.dotted"
                ) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        HStack(spacing: Theme.Spacing.sm) {
                            Menu(selectedRouteFamily) {
                                Button("All") { selectedRouteFamily = "All" }
                                Divider()
                                ForEach(routeFamilies, id: \.self) { family in
                                    Button(family) { selectedRouteFamily = family }
                                }
                            }
                            .menuStyle(.button)

                            TextField("Search routes", text: $routeSearch)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)

                            Spacer(minLength: Theme.Spacing.md)

                            routeCountPill("\(filteredRoutes.count)", "Shown", tint: Theme.Colors.accent)
                            routeCountPill("\(streamingRouteCount)", "Streaming", tint: Theme.Colors.success)
                        }

                        if filteredRoutes.isEmpty {
                            serverEmpty(
                                systemImage: "magnifyingglass",
                                title: "No matching routes",
                                caption: "Adjust the family filter or search field."
                            )
                            .frame(minHeight: 112)
                        } else {
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 360), spacing: Theme.Spacing.md)],
                                spacing: Theme.Spacing.md
                            ) {
                                ForEach(filteredRoutes.prefix(28)) { route in
                                    routeRow(route)
                                }
                            }
                        }
                    }
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .background(Theme.ProNoirBackground())
        .task { await refresh() }
        .onChange(of: app.engineState) { _, _ in Task { await refresh() } }
    }

    private var serverSubtitle: String {
        "\(health.label) - \(operatorEndpoint)"
    }

    private var operatorEndpoint: String {
        StudioServerCommandFormatter.endpoint(config: config, health: health)
    }

    private var operatorBinding: String {
        StudioServerCommandFormatter.binding(config: config, health: health)
    }

    private var effectiveAPIKey: String {
        StudioServerCommandFormatter.clientAPIKey(config: config, health: health)
    }

    private var authModeValue: String {
        effectiveAPIKey.isEmpty ? "Open loopback" : "Bearer token"
    }

    private var authModeCaption: String {
        effectiveAPIKey.isEmpty ? "No API key required" : "API key required"
    }

    private var authModeSystemImage: String {
        effectiveAPIKey.isEmpty ? "lock.open" : "lock.fill"
    }

    private var authModeTint: Color {
        effectiveAPIKey.isEmpty ? Theme.Colors.warning : Theme.Colors.success
    }

    private var operationStatusTint: Color {
        switch status {
        case "Ready", "Stopped":
            return Theme.Colors.textLow
        case "Server running":
            return Theme.Colors.success
        default:
            return health.status == .failed ? Theme.Colors.danger : Theme.Colors.warning
        }
    }

    private var routeFamilies: [String] {
        Array(Set(routes.map(\.family))).sorted()
    }

    private var routeSummary: String {
        "\(routes.count) routes - \(routeFamilies.count) families - \(streamingRouteCount) streaming"
    }

    private var streamingRouteCount: Int {
        routes.filter(\.streams).count
    }

    private var filteredRoutes: [APIRoute] {
        let query = routeSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return routes.filter { route in
            let matchesFamily = selectedRouteFamily == "All" || route.family == selectedRouteFamily
            let matchesSearch = query.isEmpty
                || route.path.lowercased().contains(query)
                || route.method.lowercased().contains(query)
                || route.family.lowercased().contains(query)
                || route.summary.lowercased().contains(query)
            return matchesFamily && matchesSearch
        }
    }

    private var selectedModelLabel: String {
        guard let path = app.selectedModelPath else { return "No model" }
        return displayModelName(for: path)
    }

    private var selectedModelCaption: String {
        guard let path = app.selectedModelPath else { return "No explicit selection" }
        let components = path.pathComponents
        if let snapshotsIndex = components.lastIndex(of: "snapshots"),
           snapshotsIndex + 1 < components.count {
            return "snapshot \(String(path.lastPathComponent.prefix(12)))"
        }
        return path.deletingLastPathComponent().lastPathComponent
    }

    private var selectedServerModel: ModelSummary? {
        guard let selectedPath = app.selectedModelPath else { return nil }
        return serverModels.first { $0.ref.localURL == selectedPath }
    }

    private var effectiveServerModel: ModelSummary? {
        if let selected = selectedServerModel {
            return StudioServerModelCompatibility.isChatCapable(selected) ? selected : nil
        }
        guard app.selectedModelPath == nil else { return nil }
        return serverModels.first(where: StudioServerModelCompatibility.isChatCapable)
    }

    private var incompatibleServerModel: ModelSummary? {
        guard let selected = selectedServerModel,
              !StudioServerModelCompatibility.isChatCapable(selected)
        else { return nil }
        return selected
    }

    private var serverModelLabel: String {
        if let model = effectiveServerModel {
            return model.ref.displayName
        }
        if incompatibleServerModel != nil {
            return "No chat model selected"
        }
        return selectedModelLabel
    }

    private var serverModelCaption: String {
        if let model = effectiveServerModel {
            return model.ref.localURL == app.selectedModelPath
                ? "Chat-capable server model"
                : "First local chat model"
        }
        if let model = incompatibleServerModel {
            return "\(model.ref.displayName) is image-only; select Chat route in Models"
        }
        if app.selectedModelPath != nil {
            return selectedModelCaption
        }
        return "Select a Chat route model in Models"
    }

    private var serverModelTint: Color {
        if effectiveServerModel != nil { return Theme.Colors.accent }
        if incompatibleServerModel != nil { return Theme.Colors.warning }
        return Theme.Colors.textLow
    }

    private var serverClientModelName: String {
        effectiveServerModel?.ref.displayName ?? "local-model"
    }

    private var clientProbeDisabledReason: String? {
        effectiveServerModel == nil
            ? "Select a local chat-capable model before copying a chat-completions cURL."
            : nil
    }

    private var chatHandshakeTitle: String {
        effectiveServerModel == nil ? "Chat model needed" : "Chat completion"
    }

    private var chatHandshakeValue: String {
        effectiveServerModel == nil ? "Select Chat route" : "POST /v1/chat/completions"
    }

    private var chatHandshakeCaption: String {
        effectiveServerModel == nil
            ? "Copy cURL waits for a chat model"
            : "Uses \(serverClientModelName)"
    }

    private var clientProbeAccessibilityTitle: String {
        if let reason = clientProbeDisabledReason {
            return "Server Copy cURL unavailable: \(reason)"
        }
        return "Server Copy cURL for \(serverClientModelName) at \(operatorEndpoint)"
    }

    private var healthProbeAccessibilityTitle: String {
        "Server Copy Health Probe at \(operatorEndpoint)"
    }

    private var chatHandshakeTint: Color {
        effectiveServerModel == nil ? Theme.Colors.warning : Theme.Colors.success
    }

    private var serverStartDisabledReason: String? {
        if let model = incompatibleServerModel {
            return "\(model.ref.displayName) is image-only; select a Chat route model in Models."
        }
        if effectiveServerModel == nil {
            return "Select a local chat-capable model before starting Server."
        }
        if health.status == .loading {
            return "Server is already loading."
        }
        if health.status == .running {
            return "Server is already running."
        }
        if health.status == .sleeping {
            return "Server listener is already available; stop it before starting again."
        }
        return nil
    }

    private var serverStartAccessibilityLabel: String {
        guard let reason = serverStartDisabledReason else { return "Start Server" }
        return "Start Server unavailable: \(reason)"
    }

    private var serverStopDisabledReason: String? {
        health.status == .stopped ? "Server is already stopped." : nil
    }

    private var serverStopAccessibilityLabel: String {
        guard let reason = serverStopDisabledReason else { return "Stop" }
        return "Stop unavailable: \(reason)"
    }

    private var healthTint: Color {
        switch health.status {
        case .stopped: return Theme.Colors.textLow
        case .loading: return Theme.Colors.accent
        case .running: return Theme.Colors.success
        case .sleeping: return Theme.Colors.warning
        case .failed: return Theme.Colors.danger
        }
    }

    private var serverOverview: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 214), spacing: Theme.Spacing.md)],
            spacing: Theme.Spacing.md
        ) {
            serverStatusTile(
                title: "API State",
                value: health.label,
                caption: operatorEndpoint,
                systemImage: "power.circle",
                tint: healthTint
            )
            serverStatusTile(
                title: "Binding",
                value: operatorBinding,
                caption: authModeCaption,
                systemImage: authModeSystemImage,
                tint: authModeTint
            )
            serverStatusTile(
                title: "Route Surface",
                value: "\(routes.count) routes",
                caption: "\(routeFamilies.count) families - \(streamingRouteCount) streaming",
                systemImage: "point.3.connected.trianglepath.dotted",
                tint: Theme.Colors.creative
            )
            serverStatusTile(
                title: "Model Context",
                value: serverModelLabel,
                caption: serverModelCaption,
                systemImage: "cpu",
                tint: serverModelTint
            )
        }
    }

    private var endpointStrip: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Label(L10n.Studio.endpoint.render(AppLocalePreference.current), systemImage: "link")
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textLow)
            Text(operatorEndpoint)
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.textMid)
                .lineLimit(1)
                .textSelection(.enabled)
            Button {
                copyEndpoint()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy endpoint")
            .accessibilityIdentifier("Server endpoint strip Copy Endpoint")
            .accessibilityLabel(L10n.Studio.serverEndpointStripCopy.render(AppLocalePreference.current))
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 8)
        .background(Theme.Colors.surfaceHi.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private var serverControlInputs: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 156), spacing: Theme.Spacing.md)],
                spacing: Theme.Spacing.md
            ) {
                serverField("Host", systemImage: "network") {
                    TextField("127.0.0.1", text: $config.host)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Typography.monoCaption)
                }
                serverField("Port", systemImage: "number") {
                    Stepper(value: $config.port, in: 1024...65535) {
                        Text(verbatim: String(config.port))
                            .font(Theme.Typography.monoCaption)
                    }
                    .accessibilityLabel(L10n.Studio.serverPort.render(AppLocalePreference.current))
                }
                serverField("API Key", systemImage: config.apiKey.isEmpty ? "lock.open" : "lock.fill") {
                    SecureField("Optional", text: $config.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .font(Theme.Typography.monoCaption)
                }
            }

            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    Task { await start() }
                } label: {
                    Label(L10n.Studio.startServer.render(AppLocalePreference.current), systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(serverStartDisabledReason != nil)
                .accessibilityIdentifier("Server Start")
                .accessibilityLabel(serverStartAccessibilityLabel)
                .help(serverStartDisabledReason ?? "Start local OpenAI-compatible server")

                Button {
                    Task { await stop() }
                } label: {
                    Label(L10n.Studio.stop.render(AppLocalePreference.current), systemImage: "stop.fill")
                }
                .disabled(serverStopDisabledReason != nil)
                .accessibilityIdentifier("Server Stop")
                .accessibilityLabel(serverStopAccessibilityLabel)

                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Spacing.sm) {
                    Label(L10n.Studio.operatorChecklist.render(AppLocalePreference.current), systemImage: "checkmark.seal")
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                    Spacer(minLength: 0)
                    Text(health.label)
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(healthTint)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, 9)

                serverChecklistRow(
                    "Bind",
                    value: operatorBinding,
                    caption: "Loopback listener",
                    systemImage: "network",
                    tint: Theme.Colors.warning,
                    monospaced: true
                )
                serverChecklistRow(
                    "Traffic",
                    value: health.status == .running ? "Accepting requests" : "Standby",
                    caption: "\(routes.count) OpenAI-compatible routes",
                    systemImage: "arrow.left.arrow.right",
                    tint: health.status == .running ? Theme.Colors.success : Theme.Colors.textLow
                )
                serverChecklistRow(
                    "Last operation",
                    value: status,
                    caption: "Start/stop result",
                    systemImage: "waveform.path.ecg",
                    tint: operationStatusTint
                )
                serverChecklistRow(
                    "Next check",
                    value: "Route Inspector",
                    caption: "Filter families, streaming routes, and health probes",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    tint: Theme.Colors.creative
                )
            }
            .background(Theme.Colors.surfaceHi.opacity(0.54))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.border, lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var runtimeContractPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.Studio.runtimeContract.render(AppLocalePreference.current), systemImage: "checklist.checked")
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.accent)
                    Text(L10n.Studio.openAILoopbackService.render(AppLocalePreference.current))
                        .font(Theme.Typography.bodyHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                    Text(L10n.Studio.valuesClientsNeed.render(AppLocalePreference.current))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMid)
                        .lineLimit(2)
                }
                Spacer(minLength: Theme.Spacing.md)
                Button {
                    copyEndpoint()
                } label: {
                    Label(L10n.Studio.copyEndpoint.render(AppLocalePreference.current), systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("Server runtime Copy Endpoint")
                .accessibilityLabel(L10n.Studio.serverRuntimeCopy.render(AppLocalePreference.current))
            }

            clientHandshakePanel

            VStack(spacing: 0) {
                serverContractRow(
                    "Endpoint",
                    value: operatorEndpoint,
                    caption: "Base URL for local clients",
                    systemImage: "link",
                    tint: healthTint,
                    monospaced: true
                )
                serverContractRow(
                    "Auth Mode",
                    value: authModeValue,
                    caption: authModeCaption,
                    systemImage: authModeSystemImage,
                    tint: authModeTint
                )
                serverContractRow(
                    "Model Context",
                    value: serverModelLabel,
                    caption: serverModelCaption,
                    systemImage: "cpu",
                    tint: serverModelTint
                )
                serverContractRow(
                    "Route Coverage",
                    value: "\(routes.count) routes",
                    caption: "\(routeFamilies.count) families, \(streamingRouteCount) streaming",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    tint: Theme.Colors.creative
                )
            }
            .background(Theme.Colors.surfaceHi.opacity(0.54))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.border, lineWidth: 1)
            )
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Theme.Colors.surface.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private var clientHandshakePanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                Label(L10n.Studio.clientHandshake.render(AppLocalePreference.current), systemImage: "bolt.horizontal.circle")
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                Spacer(minLength: Theme.Spacing.sm)
                Button {
                    copyHealthProbe()
                } label: {
                    Label(L10n.Studio.copyHealth.render(AppLocalePreference.current), systemImage: "heart.text.square")
                        .font(Theme.Typography.captionHi)
                }
                .buttonStyle(.borderless)
                .help("Copy health probe cURL")
                .accessibilityIdentifier("Server Copy Health Probe")
                .accessibilityLabel(healthProbeAccessibilityTitle)
                .foregroundStyle(Theme.Colors.textHigh)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 5)
                .background(Theme.Colors.surfaceHi.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                Button {
                    copyClientProbe()
                } label: {
                    Label(L10n.Studio.copyCurl.render(AppLocalePreference.current), systemImage: "terminal")
                        .font(Theme.Typography.captionHi)
                }
                .buttonStyle(.borderless)
                .disabled(clientProbeDisabledReason != nil)
                .help(clientProbeDisabledReason ?? "Copy chat-completions cURL")
                .accessibilityIdentifier("Server Copy cURL")
                .accessibilityLabel(clientProbeAccessibilityTitle)
                .foregroundStyle(clientProbeDisabledReason == nil ? Theme.Colors.textHigh : Theme.Colors.textLow)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 5)
                .background(Theme.Colors.surfaceHi.opacity(clientProbeDisabledReason == nil ? 0.72 : 0.36))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 154), spacing: Theme.Spacing.sm)],
                spacing: Theme.Spacing.sm
            ) {
                clientHandshakeStep(
                    "1",
                    title: "Base URL",
                    value: operatorEndpoint,
                    caption: "Point clients here",
                    systemImage: "link",
                    tint: healthTint,
                    monospaced: true
                )
                clientHandshakeStep(
                    "2",
                    title: "Health probe",
                    value: "GET /health",
                    caption: "Confirm \(operatorBinding)",
                    systemImage: "heart.text.square",
                    tint: Theme.Colors.accent,
                    monospaced: true
                )
                clientHandshakeStep(
                    "3",
                    title: chatHandshakeTitle,
                    value: chatHandshakeValue,
                    caption: chatHandshakeCaption,
                    systemImage: "bubble.left.and.text.bubble.right",
                    tint: chatHandshakeTint,
                    monospaced: true
                )
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.background.opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border.opacity(0.72), lineWidth: 1)
        )
    }

    private func clientHandshakeStep(
        _ number: String,
        title: String,
        value: String,
        caption: String,
        systemImage: String,
        tint: Color,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(tint.opacity(0.13))
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 24, height: 24)
            .overlay(alignment: .topTrailing) {
                Text(number)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.Colors.textHigh)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Theme.Colors.surfaceHi)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .offset(x: 5, y: -5)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                Text(value)
                    .font(monospaced ? Theme.Typography.monoCaption : Theme.Typography.bodyHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.75)
                    .textSelection(.enabled)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
        .background(Theme.Colors.surfaceHi.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private func serverContractRow(
        _ title: String,
        value: String,
        caption: String,
        systemImage: String,
        tint: Color,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                Text(value)
                    .font(monospaced ? Theme.Typography.monoCaption : Theme.Typography.bodyHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Colors.border.opacity(0.72))
                .frame(height: 1)
        }
    }

    private func serverChecklistRow(
        _ title: String,
        value: String,
        caption: String,
        systemImage: String,
        tint: Color,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                Text(value)
                    .font(monospaced ? Theme.Typography.monoCaption : Theme.Typography.bodyHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .textSelection(.enabled)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Colors.border.opacity(0.72))
                .frame(height: 1)
        }
    }

    private func serverStatusTile(
        title: String,
        value: String,
        caption: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textLow)
                Text(value)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Theme.ProNoirPanelBackground())
    }

    private func serverField<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(title, systemImage: systemImage)
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textLow)
            content()
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(Theme.Colors.surfaceHi.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func routeCountPill(_ value: String, _ label: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text(value)
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textHigh)
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textMid)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.Colors.surfaceHi.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private func routeRow(_ route: APIRoute) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Text(route.method.uppercased())
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(methodColor(route.method))
                .frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(route.path)
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(route.summary.isEmpty ? route.family : route.summary)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(2)
                HStack(spacing: Theme.Spacing.xs) {
                    Text(route.family)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Theme.Colors.surface.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    if route.streams {
                        Label(L10n.Studio.streaming.render(AppLocalePreference.current), systemImage: "dot.radiowaves.left.and.right")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.success)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .background(Theme.Colors.surfaceHi.opacity(0.56))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func serverEmpty(systemImage: String, title: String, caption: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.Colors.textLow)
                .frame(width: 34, height: 34)
                .background(Theme.Colors.surfaceHi.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.Typography.bodyHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surface.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func methodColor(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": return Theme.Colors.accent
        case "POST": return Theme.Colors.success
        case "DELETE": return Theme.Colors.danger
        case "PUT", "PATCH": return Theme.Colors.warning
        default: return Theme.Colors.textMid
        }
    }

    private func displayModelName(for url: URL) -> String {
        let components = url.pathComponents
        if let snapshotsIndex = components.lastIndex(of: "snapshots"),
           snapshotsIndex > 0 {
            return cleanModelDirectoryName(components[snapshotsIndex - 1])
        }
        return cleanModelDirectoryName(url.lastPathComponent)
    }

    private func cleanModelDirectoryName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "models--", with: "")
            .replacingOccurrences(of: "--", with: "/")
        return cleaned.isEmpty ? name : cleaned
    }

    private func refresh() async {
        let service = StudioServerService(app: app)
        routes = service.routeCatalog()
        serverModels = (try? await StudioModelService(app: app).listLocalModels()) ?? serverModels
        health = (try? await service.health()) ?? health
        if selectedRouteFamily != "All", !routeFamilies.contains(selectedRouteFamily) {
            selectedRouteFamily = "All"
        }
    }

    private func start() async {
        do {
            status = "Starting server"
            try await StudioServerService(app: app).startServer(config: config)
            status = "Server running"
            await refresh()
        } catch {
            status = error.localizedDescription
            await refresh()
            StudioDiagnosticIssueStore.record(
                source: .server,
                title: "Server start failed",
                message: error.localizedDescription,
                context: "\(config.host):\(config.port)"
            )
        }
    }

    private func stop() async {
        do {
            try await StudioServerService(app: app).stopServer()
            status = "Stopped"
            await refresh()
        } catch {
            status = error.localizedDescription
            StudioDiagnosticIssueStore.record(
                source: .server,
                title: "Server stop failed",
                message: error.localizedDescription,
                context: operatorEndpoint
            )
        }
    }

    private var clientProbeCommand: String {
        return StudioServerCommandFormatter.clientProbeCommand(
            endpoint: operatorEndpoint,
            model: serverClientModelName,
            apiKey: effectiveAPIKey
        )
    }

    private var healthProbeCommand: String {
        StudioServerCommandFormatter.healthProbeCommand(endpoint: operatorEndpoint)
    }

    private func copyEndpoint() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(operatorEndpoint, forType: .string)
        #endif
    }

    private func copyClientProbe() {
        guard clientProbeDisabledReason == nil else { return }
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(clientProbeCommand, forType: .string)
        #endif
    }

    private func copyHealthProbe() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(healthProbeCommand, forType: .string)
        #endif
    }
}

struct StudioModelToolsScreen: View {
    @Environment(AppState.self) private var app
    @State private var models: [ModelSummary] = []
    @State private var selectedID: String?
    @State private var inspection: ModelInspection?
    @State private var jobs: [ModelJob] = []
    @State private var status = "Ready"
    @State private var jobService: StudioModelToolJobStore?
    @State private var latestActionJobID: JobID?
    @State private var modelCardModel: ModelSummary?
    @State private var publishModel: ModelSummary?

    private var selected: ModelSummary? {
        models.first { $0.id == selectedID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                StudioToolbar(title: "Model Tools", subtitle: status) {
                    Menu(selected?.ref.displayName ?? "Select Model") {
                        ForEach(models) { model in
                            Button(model.ref.displayName) {
                                selectedID = model.id
                                inspection = nil
                            }
                        }
                    }
                    Button {
                        Task { await refresh() }
                    } label: {
                        Label(L10n.Studio.refresh.render(AppLocalePreference.current), systemImage: "arrow.clockwise")
                    }
                }

                advancedModelOverview

                AdvancedLabCard(title: "Model Inspector", subtitle: selectedPathSummary, systemImage: "doc.text.magnifyingglass") {
                    inspectorActions
                    selectedModelSummary
                    modelOperatorSequence
                    modelReadinessInspector
                    inspectionDetails
                }

                AdvancedLabCard(title: "Job Queue", subtitle: "\(jobs.count) recent", systemImage: "list.bullet.rectangle") {
                    if jobs.isEmpty {
                        advancedEmpty(
                            systemImage: "tray",
                            title: "No model jobs yet",
                            caption: "Validation, benchmark, and report exports will appear here with progress and output paths."
                        )
                        .frame(minHeight: 112)
                    } else {
                        VStack(spacing: Theme.Spacing.sm) {
                            ForEach(jobs) { job in
                                jobRow(job)
                            }
                        }
                    }
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .background(Theme.ProNoirBackground())
        .task {
            do {
                jobService = try StudioModelToolJobStore()
                await refresh()
            } catch {
                status = "Canonical jobs unavailable: \(error.localizedDescription)"
            }
        }
        .sheet(item: $modelCardModel) { model in
            StudioModelCardSheet(model: model)
        }
        .sheet(item: $publishModel) { model in
            StudioPublishSheet(model: model)
        }
    }

    private var selectedPathSummary: String {
        guard let selected else { return "Select a local model to inspect" }
        return selected.ref.localURL?.lastPathComponent ?? selected.ref.displayName
    }

    private var selectedSizeText: String {
        if let inspection {
            return formattedBytes(inspection.sizeBytes)
        }
        guard let selected, selected.sizeBytes > 0 else { return "Unknown" }
        return formattedBytes(selected.sizeBytes)
    }

    private var selectedFamilyText: String {
        inspection?.family ?? selected?.family ?? "Unknown"
    }

    private var selectedModalityText: String {
        inspection?.modality ?? selected?.modality ?? "Unknown"
    }

    private var selectedModelURL: URL? {
        selected?.ref.localURL
    }

    private var benchmarkUnavailableReason: String? {
        guard let selected else { return "Select a local model" }
        return StudioModelToolsBenchmarkGate.unavailableReason(
            displayName: selected.ref.displayName,
            modality: selectedModalityText,
            isLoaded: selected.isLoaded
        )
    }

    private var validationUnavailableReason: String? {
        StudioModelToolsValidationGate.unavailableReason(
            hasSelectedModel: selected != nil,
            hasTokenizer: selectedHasTokenizer
        )
    }

    private var benchmarkStepValue: String {
        if selectedWeightSummary == "No weights found" {
            return "No weights"
        }
        if benchmarkUnavailableReason == "Benchmark requires a loaded text model" {
            return "Needs loaded text model"
        }
        return benchmarkUnavailableReason ?? "Runtime ready"
    }

    private var validationStepValue: String {
        validationUnavailableReason ?? "Tokenizer ready"
    }

    private var reportUnavailableReason: String? {
        StudioModelToolsReportGate.unavailableReason(
            hasSelectedModel: selected != nil,
            hasInspection: inspection != nil
        )
    }

    private var reportStepValue: String {
        reportUnavailableReason ?? "Ready to export"
    }

    private var benchmarkActionTitle: String {
        if let reason = benchmarkUnavailableReason {
            return "Model Tools Benchmark unavailable: \(reason)"
        }
        return "Model Tools Benchmark \(selected?.ref.displayName ?? "selected model")"
    }

    private var validationActionTitle: String {
        if let reason = validationUnavailableReason {
            return "Model Tools Validate unavailable: \(reason)"
        }
        return "Model Tools Validate \(selected?.ref.displayName ?? "selected model")"
    }

    private var reportActionTitle: String {
        if let reason = reportUnavailableReason {
            return "Model Tools Export Report unavailable: \(reason)"
        }
        return "Model Tools Export Report for \(selected?.ref.displayName ?? "selected model")"
    }

    private var selectedHasConfig: Bool {
        guard let url = selectedModelURL else { return false }
        return Self.containsFile(named: ["config.json", "model_index.json"], under: url)
    }

    private var selectedHasTokenizer: Bool {
        guard let url = selectedModelURL else { return false }
        let candidates = ["tokenizer.json", "tokenizer.model", "vocab.json", "tokenizer_config.json"]
        return Self.containsFile(named: candidates, under: url)
    }

    private var selectedWeightSummary: String {
        guard let url = selectedModelURL else { return "No local path" }
        let result = Self.weightFileSummary(for: url)
        if result.count == 0 { return "No weights found" }
        return "\(result.count) file\(result.count == 1 ? "" : "s") - \(formattedBytes(result.bytes))"
    }

    private var selectedSnapshotText: String {
        guard let url = selectedModelURL else { return "No local path" }
        let components = url.pathComponents
        if let snapshotsIndex = components.lastIndex(of: "snapshots"),
           snapshotsIndex + 1 < components.count {
            return String(components[snapshotsIndex + 1].prefix(12))
        }
        return url.lastPathComponent
    }

    private var advancedModelOverview: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 214), spacing: Theme.Spacing.md)],
            spacing: Theme.Spacing.md
        ) {
            advancedStatusTile(
                title: "Selected Model",
                value: selected?.ref.displayName ?? "No model",
                caption: selectedPathSummary,
                systemImage: "cpu",
                tint: selected == nil ? Theme.Colors.textLow : Theme.Colors.accent
            )
            advancedStatusTile(
                title: "Local Size",
                value: selectedSizeText,
                caption: "\(selectedFamilyText) - \(selectedModalityText)",
                systemImage: "externaldrive",
                tint: Theme.Colors.success
            )
            advancedStatusTile(
                title: "Inspection",
                value: inspection == nil ? "Not run" : "Ready",
                caption: inspection.map { "\($0.safetensorShardCount) shards - tokenizer \($0.tokenizerPresent ? "present" : "missing")" } ?? "Reads config and tokenizer files",
                systemImage: "checklist",
                tint: inspection == nil ? Theme.Colors.warning : Theme.Colors.success
            )
            advancedStatusTile(
                title: "Job Queue",
                value: "\(jobs.count) jobs",
                caption: "\(jobs.filter { $0.status == .running }.count) running - \(jobs.filter { $0.status == .failed }.count) failed",
                systemImage: "list.bullet.rectangle",
                tint: jobs.contains { $0.status == .failed } ? Theme.Colors.danger : Theme.Colors.creative
            )
        }
    }

    private var inspectorActions: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Button {
                Task { await inspect() }
            } label: {
                Label(L10n.Studio.runInspect.render(AppLocalePreference.current), systemImage: "doc.text.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .disabled(selected == nil)
            .accessibilityIdentifier("Model Tools Run Inspect")
            .accessibilityLabel(L10n.Studio.advModelsRunInspect.render(AppLocalePreference.current))

            Button {
                Task { await validate() }
            } label: {
                Label(L10n.Studio.validate.render(AppLocalePreference.current), systemImage: "checkmark.shield")
            }
            .disabled(validationUnavailableReason != nil)
            .help(validationUnavailableReason ?? "Run tokenizer-backed validation for the selected model")
            .accessibilityIdentifier(validationActionTitle)
            .accessibilityLabel(validationActionTitle)

            Button {
                Task { await benchmark() }
            } label: {
                Label(L10n.Studio.benchmark.render(AppLocalePreference.current), systemImage: "speedometer")
            }
            .disabled(benchmarkUnavailableReason != nil)
            .help(benchmarkUnavailableReason ?? "Run a local benchmark for the selected loaded text model")
            .accessibilityIdentifier(benchmarkActionTitle)
            .accessibilityLabel(benchmarkActionTitle)

            Button {
                Task { await package() }
            } label: {
                Label(L10n.Studio.exportReport.render(AppLocalePreference.current), systemImage: "square.and.arrow.down")
            }
            .disabled(reportUnavailableReason != nil)
            .help(reportUnavailableReason ?? "Export inspection report")
            .accessibilityIdentifier(reportActionTitle)
            .accessibilityLabel(reportActionTitle)

            Button {
                modelCardModel = selected
            } label: {
                Label("Model Card", systemImage: "doc.richtext")
            }
            .disabled(selected?.ref.localURL == nil)
            .accessibilityIdentifier("Model Tools Generate Model Card")

            Button {
                publishModel = selected
            } label: {
                Label("Publish", systemImage: "arrow.up.circle")
            }
            .disabled(selected?.ref.localURL == nil)
            .accessibilityIdentifier("Model Tools Publish to Hugging Face")

            Spacer(minLength: Theme.Spacing.md)

            Button {
                copySelectedPath()
            } label: {
                Label(L10n.Studio.copyPath.render(AppLocalePreference.current), systemImage: "doc.on.doc")
            }
            .disabled(selected?.ref.localURL == nil)
            .accessibilityIdentifier("Model Tools Copy Path")
            .accessibilityLabel(L10n.Studio.advModelsCopyPath.render(AppLocalePreference.current))
        }
    }

    private var selectedModelSummary: some View {
        Group {
            if let selected {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(selected.ref.displayName)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(1)
                    HStack(spacing: Theme.Spacing.sm) {
                        modelInfoPill(selected.family, systemImage: "tag")
                        modelInfoPill(selected.modality, systemImage: "sparkles")
                        modelInfoPill(selected.isLoaded ? "Loaded" : "Not loaded", systemImage: selected.isLoaded ? "bolt.fill" : "power")
                    }
                    Text(selected.ref.localURL?.path ?? "No local path recorded")
                        .font(Theme.Typography.monoCaption)
                        .foregroundStyle(Theme.Colors.textLow)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.surfaceHi.opacity(0.48))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            } else {
                advancedEmpty(
                    systemImage: "externaldrive.badge.questionmark",
                    title: "No local model selected",
                    caption: "Install or scan a model first, then return here for validation, benchmark, and report tools."
                )
            }
        }
    }

    private var modelOperatorSequence: some View {
        Group {
            if selected == nil {
                EmptyView()
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Label(L10n.Studio.operatorSequence.render(AppLocalePreference.current), systemImage: "arrow.triangle.branch")
                            .font(Theme.Typography.captionHi)
                            .foregroundStyle(Theme.Colors.textHigh)
                        Spacer(minLength: Theme.Spacing.sm)
                        Text(inspection == nil ? "Next: Run Inspect" : "Next: Export Report")
                            .font(Theme.Typography.captionHi)
                            .foregroundStyle(inspection == nil ? Theme.Colors.accent : Theme.Colors.success)
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.sm)],
                        spacing: Theme.Spacing.sm
                    ) {
                        modelOperatorStep(
                            "1",
                            title: "Inspect files",
                            value: selectedHasConfig ? "Manifest ready" : "Needs manifest",
                            tint: selectedHasConfig ? Theme.Colors.success : Theme.Colors.warning
                        )
                        modelOperatorStep(
                            "2",
                            title: "Validation gate",
                            value: validationStepValue,
                            tint: validationUnavailableReason == nil ? Theme.Colors.success : Theme.Colors.warning
                        )
                        modelOperatorStep(
                            "3",
                            title: "Benchmark path",
                            value: benchmarkStepValue,
                            tint: benchmarkUnavailableReason == nil ? Theme.Colors.accent : Theme.Colors.warning
                        )
                        modelOperatorStep(
                            "4",
                            title: "Report handoff",
                            value: reportStepValue,
                            tint: reportUnavailableReason == nil ? Theme.Colors.success : Theme.Colors.textMid
                        )
                    }
                }
                .padding(Theme.Spacing.md)
                .background(Theme.Colors.background.opacity(0.34))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Theme.Colors.border.opacity(0.72), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
        }
    }

    private func modelOperatorStep(
        _ number: String,
        title: String,
        value: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Text(number)
                .font(Theme.Typography.captionHi)
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .lineLimit(1)
                Text(value)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .topLeading)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private var modelReadinessInspector: some View {
        Group {
            if selected == nil {
                EmptyView()
            } else {
                let weightSummary = selectedWeightSummary
                let hasWeights = weightSummary != "No weights found"
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    HStack(alignment: .top, spacing: Theme.Spacing.md) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            Label(L10n.Studio.preflightInspector.render(AppLocalePreference.current), systemImage: "checklist.checked")
                                .font(Theme.Typography.captionHi)
                                .foregroundStyle(Theme.Colors.accent)
                            Text(L10n.Studio.localArtifactsBeforeInspect.render(AppLocalePreference.current))
                                .font(Theme.Typography.bodyHi)
                                .foregroundStyle(Theme.Colors.textHigh)
                            Text(L10n.Studio.checksReadFolderHint.render(AppLocalePreference.current))
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textMid)
                                .lineLimit(2)
                        }
                        Spacer(minLength: Theme.Spacing.md)
                        modelInfoPill("Snapshot \(selectedSnapshotText)", systemImage: "point.3.connected.trianglepath.dotted")
                    }

                    readinessArtifactLedger(weightSummary: weightSummary, hasWeights: hasWeights)
                }
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.Colors.surface.opacity(0.42))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            }
        }
    }

    private func readinessArtifactLedger(weightSummary: String, hasWeights: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.md) {
                Label(L10n.Studio.artifactLedger.render(AppLocalePreference.current), systemImage: "tablecells")
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .frame(width: 174, alignment: .leading)
                Text(L10n.Studio.evidence.render(AppLocalePreference.current))
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textLow)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L10n.Studio.operatorSignal.render(AppLocalePreference.current))
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textLow)
                    .frame(width: 164, alignment: .leading)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 9)

            readinessArtifactRow(
                "Manifest",
                state: selectedHasConfig ? "Present" : "Missing",
                evidence: "config.json or model_index.json",
                signal: selectedHasConfig ? "Inspection input" : "Add manifest",
                systemImage: "doc.text",
                tint: selectedHasConfig ? Theme.Colors.success : Theme.Colors.warning
            )
            readinessArtifactRow(
                "Tokenizer",
                state: selectedHasTokenizer ? "Present" : "Missing",
                evidence: "tokenizer.json, tokenizer.model, vocab, or tokenizer_config",
                signal: selectedHasTokenizer ? "Can encode prompts" : "Needs tokenizer",
                systemImage: "textformat.abc",
                tint: selectedHasTokenizer ? Theme.Colors.success : Theme.Colors.warning
            )
            readinessArtifactRow(
                "Weights",
                state: weightSummary,
                evidence: "safetensors, bin, or gguf payloads",
                signal: hasWeights ? (benchmarkUnavailableReason ?? "Benchmark candidate") : "No weights",
                systemImage: "shippingbox",
                tint: benchmarkUnavailableReason == nil ? Theme.Colors.success : Theme.Colors.warning
            )
            readinessArtifactRow(
                "Next operation",
                state: inspection == nil ? "Run Inspect" : "Export Report",
                evidence: "Snapshot \(selectedSnapshotText)",
                signal: reportUnavailableReason ?? "Inspection ready",
                systemImage: inspection == nil ? "doc.text.magnifyingglass" : "square.and.arrow.down",
                tint: inspection == nil ? Theme.Colors.accent : Theme.Colors.success
            )
        }
        .background(Theme.Colors.surfaceHi.opacity(0.54))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    private func readinessArtifactRow(
        _ artifact: String,
        state: String,
        evidence: String,
        signal: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(artifact)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                    Text(state)
                        .font(Theme.Typography.bodyHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(width: 174, alignment: .leading)

            Text(evidence)
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.textMid)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(signal)
                .font(Theme.Typography.captionHi)
                .foregroundStyle(tint)
                .lineLimit(2)
                .frame(width: 164, alignment: .leading)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 8)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Colors.border.opacity(0.72))
                .frame(height: 1)
        }
    }

    private var inspectionDetails: some View {
        Group {
            if let inspection {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 150), spacing: Theme.Spacing.md)],
                        spacing: Theme.Spacing.md
                    ) {
                        inspectionMetric("Family", inspection.family, tint: Theme.Colors.accent)
                        inspectionMetric("Modality", inspection.modality, tint: Theme.Colors.creative)
                        inspectionMetric("Size", formattedBytes(inspection.sizeBytes), tint: Theme.Colors.success)
                        inspectionMetric("Shards", "\(inspection.safetensorShardCount)", tint: Theme.Colors.warning)
                        inspectionMetric("Tokenizer", inspection.tokenizerPresent ? "Present" : "Missing", tint: inspection.tokenizerPresent ? Theme.Colors.success : Theme.Colors.danger)
                    }

                    if !inspection.configKeys.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text(L10n.Studio.configKeys.render(AppLocalePreference.current))
                                .font(Theme.Typography.captionHi)
                                .foregroundStyle(Theme.Colors.textLow)
                            LazyVGrid(
                                columns: [GridItem(.adaptive(minimum: 104), spacing: Theme.Spacing.xs)],
                                alignment: .leading,
                                spacing: Theme.Spacing.xs
                            ) {
                                ForEach(Array(inspection.configKeys.prefix(12)), id: \.self) { key in
                                    Text(key)
                                        .font(Theme.Typography.monoCaption)
                                        .foregroundStyle(Theme.Colors.textMid)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 4)
                                        .background(Theme.Colors.surfaceHi.opacity(0.74))
                                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                                }
                            }
                        }
                    }

                    if !inspection.notes.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                            ForEach(inspection.notes, id: \.self) { note in
                                Label(note, systemImage: "info.circle")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.textMid)
                            }
                        }
                    }
                }
            } else {
                advancedEmpty(
                    systemImage: "doc.text.magnifyingglass",
                    title: "Inspection has not run",
                    caption: "Run Inspect to read config.json, tokenizer files, shard count, and local size."
                )
                .frame(minHeight: 104)
            }
        }
    }

    private func advancedStatusTile(
        title: String,
        value: String,
        caption: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textLow)
                Text(value)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Theme.ProNoirPanelBackground())
    }

    private func modelInfoPill(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(Theme.Typography.captionHi)
            .foregroundStyle(Theme.Colors.textMid)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Theme.Colors.surface.opacity(0.64))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private func readinessCheck(
        _ title: String,
        value: String,
        caption: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                Text(value)
                    .font(Theme.Typography.bodyHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 84, alignment: .topLeading)
        .background(Theme.Colors.surfaceHi.opacity(0.54))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    private func inspectionMetric(_ label: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
                Text(label)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textLow)
            }
            Text(value)
                .font(Theme.Typography.bodyHi)
                .foregroundStyle(Theme.Colors.textHigh)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .background(Theme.Colors.surfaceHi.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func advancedEmpty(systemImage: String, title: String, caption: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.Colors.textLow)
                .frame(width: 34, height: 34)
                .background(Theme.Colors.surfaceHi.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.Typography.bodyHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surface.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func jobRow(_ job: ModelJob) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: icon(for: job.status))
                .foregroundStyle(color(for: job.status))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text("\(job.kind.rawValue.capitalized): \(job.inputModel.displayName)")
                        .font(Theme.Typography.bodyHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(1)
                    Text(job.status.rawValue.capitalized)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(color(for: job.status))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.Colors.surface.opacity(0.64))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    Spacer()
                    Text(Self.relativeFormatter.localizedString(for: job.updatedAt, relativeTo: Date()))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                    if let output = job.outputPath {
                        Button {
                            copyJobOutputPath(output, for: job)
                        } label: {
                            Label(L10n.Studio.copyOutput.render(AppLocalePreference.current), systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityIdentifier(jobOutputActionIdentifier(for: job))
                        .accessibilityLabel(jobOutputActionTitle(for: job))
                    }
                }
                Text(job.message)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(2)
                    .textSelection(.enabled)
                if let progress = job.progress, job.status == .running {
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .frame(maxWidth: 240)
                }
                if let output = job.outputPath {
                    Text(output.path)
                        .font(Theme.Typography.monoCaption)
                        .foregroundStyle(Theme.Colors.textLow)
                        .lineLimit(1)
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.surfaceHi.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func service() -> StudioModelToolsService? {
        jobService.map { StudioModelToolsService(app: app, jobs: $0) }
    }

    private func refresh() async {
        models = (try? await StudioModelService(app: app).listLocalModels()) ?? []
        selectedID = selectedID ?? models.first(where: { $0.ref.localURL == app.selectedModelPath })?.id ?? models.first?.id
        jobs = (try? await jobService?.listJobs()) ?? []
    }

    private func inspect() async {
        guard let selected, let jobService, let service = service() else { return }
        let jobID: JobID
        do {
            jobID = try jobService.start(
            kind: .inspect,
            model: selected.ref,
            message: "Queued inspection"
            )
        } catch {
            status = error.localizedDescription
            return
        }
        latestActionJobID = jobID
        jobs = (try? await jobService.listJobs()) ?? jobs
        status = "Inspecting \(selected.ref.displayName)"
        try? jobService.update(
            jobID,
            status: .running,
            progress: 0.2,
            message: "Reading config, tokenizer, and weight files"
        )
        do {
            inspection = try await service.inspect(selected.ref)
            try jobService.update(
                jobID,
                status: .completed,
                progress: 1.0,
                message: "Inspection completed"
            )
            updateStatus("Inspection ready", for: jobID)
        } catch {
            try? jobService.update(
                jobID,
                status: .failed,
                progress: 1.0,
                message: error.localizedDescription
            )
            updateStatus(error.localizedDescription, for: jobID)
            StudioModelToolsDiagnostic.recordFailure(
                kind: .inspect,
                model: selected.ref,
                message: error.localizedDescription
            )
        }
        jobs = (try? await jobService.listJobs()) ?? jobs
    }

    private func validate() async {
        guard let selected, let service = service() else { return }
        if let reason = validationUnavailableReason {
            status = reason
            return
        }
        status = "Validation queued"
        let jobID = try? await service.validate(selected.ref, suite: .loadAndShortChat)
        latestActionJobID = jobID
        await refreshJobsUntilTerminal(jobID)
        if let jobID, let job = jobs.first(where: { $0.id == jobID }) {
            updateStatus(job.message, for: jobID)
        }
    }

    private func benchmark() async {
        guard let selected, let service = service() else { return }
        if let reason = benchmarkUnavailableReason {
            status = reason
            return
        }
        status = "Benchmark queued"
        let jobID = try? await service.benchmark(selected.ref, config: BenchmarkConfig())
        latestActionJobID = jobID
        await refreshJobsUntilTerminal(jobID)
        if let jobID, let job = jobs.first(where: { $0.id == jobID }) {
            updateStatus(job.message, for: jobID)
        }
    }

    private func package() async {
        guard let selected, let service = service() else { return }
        if let reason = reportUnavailableReason {
            status = reason
            return
        }
        status = "Exporting report"
        let jobID = try? await service.package(selected.ref, options: PackageOptions())
        latestActionJobID = jobID
        jobs = (try? await jobService?.listJobs()) ?? jobs
        if let jobID, let job = jobs.first(where: { $0.id == jobID }) {
            updateStatus(job.message, for: jobID)
        }
    }

    private func updateStatus(_ message: String, for jobID: JobID) {
        guard latestActionJobID == jobID else { return }
        status = message
    }

    private func refreshJobsUntilTerminal(_ jobID: JobID?) async {
        guard let jobService else { return }
        guard let jobID else {
            jobs = (try? await jobService.listJobs()) ?? []
            return
        }

        for _ in 0..<120 {
            jobs = (try? await jobService.listJobs()) ?? []
            if let job = jobs.first(where: { $0.id == jobID }) {
                updateStatus(job.message, for: jobID)
                if job.status == .completed || job.status == .failed || job.status == .cancelled {
                    return
                }
            }
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
    }

    private static func weightFileSummary(for url: URL) -> (count: Int, bytes: Int64) {
        var count = 0
        var bytes: Int64 = 0
        if let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let item as URL in enumerator {
                let ext = item.pathExtension.lowercased()
                guard ext == "safetensors" || ext == "bin" || ext == "gguf" else { continue }
                count += 1
                let resolved = item.resolvingSymlinksInPath()
                let size = (try? resolved.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    ?? (try? item.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    ?? 0
                bytes += Int64(size)
            }
        }
        return (count, bytes)
    }

    private static func containsFile(named names: [String], under url: URL) -> Bool {
        let targets = Set(names)
        if let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let item as URL in enumerator where targets.contains(item.lastPathComponent) {
                return true
            }
        }
        return false
    }

    private func icon(for status: JobStatus) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        }
    }

    private func color(for status: JobStatus) -> Color {
        switch status {
        case .queued: return Theme.Colors.textLow
        case .running: return Theme.Colors.accent
        case .completed: return Theme.Colors.success
        case .failed: return Theme.Colors.danger
        case .cancelled: return Theme.Colors.warning
        }
    }

    private func copySelectedPath() {
        #if canImport(AppKit)
        guard let path = selected?.ref.localURL?.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        status = "Copied model path"
        #endif
    }

    private func copyJobOutputPath(_ output: URL, for job: ModelJob) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(output.path, forType: .string)
        status = "Copied \(job.kind.rawValue) output path"
        #endif
    }

    private func jobOutputActionTitle(for job: ModelJob) -> String {
        let outputKind: String
        switch job.kind {
        case .benchmark:
            outputKind = "Benchmark Output"
        case .package:
            outputKind = "Report Output"
        default:
            outputKind = "\(job.kind.rawValue.capitalized) Output"
        }
        return "Model Tools Copy \(outputKind) for \(job.inputModel.displayName)"
    }

    private func jobOutputActionIdentifier(for job: ModelJob) -> String {
        let outputKind: String
        switch job.kind {
        case .benchmark:
            outputKind = "Benchmark Output"
        case .package:
            outputKind = "Report Output"
        default:
            outputKind = "\(job.kind.rawValue.capitalized) Output"
        }
        return "Model Tools Copy \(outputKind)"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}

struct StudioDiagnosticsScreen: View {
    @Environment(AppState.self) private var app
    @State private var logs: [LogStore.Line] = []
    @State private var metrics: MetricsCollector.Snapshot?
    @State private var issues: [StudioDiagnosticIssue] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                StudioToolbar(title: "Diagnostics", subtitle: diagnosticsSubtitle) {
                    Button {
                        Task { await refreshDiagnosticsSnapshot() }
                    } label: {
                        Label(L10n.Studio.refresh.render(AppLocalePreference.current), systemImage: "arrow.clockwise")
                    }
                    Button {
                        clearIssues()
                    } label: {
                        Label(L10n.Studio.clearIssues.render(AppLocalePreference.current), systemImage: "checkmark.circle")
                    }
                    .disabled(issues.isEmpty)
                    .help(issues.isEmpty ? "No diagnostic issues to clear" : "Clear \(issues.count) open diagnostic issue\(issues.count == 1 ? "" : "s")")
                    .accessibilityIdentifier(diagnosticsClearIssuesActionTitle)
                    .accessibilityLabel(diagnosticsClearIssuesActionTitle)
                }

                diagnosticOverview

                AdvancedLabCard(title: "Runtime Pulse", subtitle: "Metal memory, queue, and throughput", systemImage: "waveform.path.ecg") {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 126), spacing: Theme.Spacing.md)],
                        spacing: Theme.Spacing.md
                    ) {
                        metricCell(
                            "GPU",
                            metrics.map { formattedBytes($0.gpuMemBytesUsed) } ?? "-",
                            "active",
                            tint: Theme.Colors.accent
                        )
                        metricCell(
                            "Peak",
                            metrics.map { formattedBytes($0.gpuMemBytesPeak) } ?? "-",
                            "session high",
                            tint: Theme.Colors.creative
                        )
                        metricCell(
                            "RAM",
                            metrics.map { formattedBytes($0.ramBytesUsed) } ?? "-",
                            metrics.map { "of \(formattedBytes($0.ramBytesTotal))" } ?? "system",
                            tint: Theme.Colors.success
                        )
                        metricCell(
                            "CPU",
                            metrics.map { String(format: "%.0f%%", $0.cpuPercent) } ?? "-",
                            "process",
                            tint: Theme.Colors.warning
                        )
                        metricCell(
                            "Decode",
                            metrics.map { String(format: "%.1f tok/s", $0.tokensPerSecondRolling) } ?? "-",
                            "rolling",
                            tint: Theme.Colors.accent
                        )
                        metricCell(
                            "Prompt",
                            metrics.map { String(format: "%.1f tok/s", $0.promptTokensPerSecondRolling) } ?? "-",
                            "prefill",
                            tint: Theme.Colors.accentHi
                        )
                        metricCell(
                            "Queue",
                            metrics.map { "\($0.queueDepth)" } ?? "-",
                            "waiting",
                            tint: Theme.Colors.textMid
                        )
                        metricCell(
                            "Latency",
                            latestLatencyText,
                            "recent",
                            tint: Theme.Colors.textMid
                        )
                    }
                }

                AdvancedLabCard(title: "Recent Errors", subtitle: recentIssuesSubtitle, systemImage: "exclamationmark.triangle") {
                    issueTriageBar
                    if issues.isEmpty {
                        diagnosticEmpty(
                            systemImage: "checkmark.seal",
                            title: "No recent issues",
                            caption: "Chat, model load, download, server, and image failures will appear here."
                        )
                        .frame(minHeight: 112)
                    } else {
                        if let newest = issues.first {
                            incidentBrief(newest)
                        }
                        VStack(spacing: Theme.Spacing.sm) {
                            ForEach(issues.prefix(8)) { issue in
                                diagnosticIssueRow(issue)
                            }
                        }
                    }
                }

                AdvancedLabCard(title: "Inspector Logs", subtitle: "\(logs.count) lines captured", systemImage: "doc.plaintext") {
                    VStack(spacing: Theme.Spacing.sm) {
                        logTableHeader
                        if logs.isEmpty {
                            diagnosticEmpty(
                                systemImage: "doc.text.magnifyingglass",
                                title: "No live logs yet",
                                caption: "Info, warning, and error lines stream here while the engine runs."
                            )
                            .frame(minHeight: 104)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(logs.suffix(60)) { line in
                                    logLineRow(line)
                                }
                            }
                            .background(Theme.Colors.background.opacity(0.42))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                        }
                    }
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .background(Theme.ProNoirBackground())
        .task { await bindDiagnostics() }
    }

    private var diagnosticsSubtitle: String {
        "\(engineStatusLabel) - \(metricsSummary) - \(issues.count) issue\(issues.count == 1 ? "" : "s")"
    }

    private var diagnosticsClearIssuesActionTitle: String {
        issues.isEmpty
            ? "Diagnostics Clear Issues unavailable: No open issues"
            : "Diagnostics Clear \(issues.count) Issue\(issues.count == 1 ? "" : "s")"
    }

    private var recentIssuesSubtitle: String {
        guard let newest = issues.first else { return "No recent failures" }
        return "\(newest.source.label) - \(Self.relativeFormatter.localizedString(for: newest.createdAt, relativeTo: Date()))"
    }

    private var metricsSummary: String {
        guard let metrics else { return "Waiting for metrics" }
        return "\(formattedBytes(metrics.gpuMemBytesUsed)) GPU"
    }

    private var latestLatencyText: String {
        guard let ms = metrics?.recentLatenciesMs.last else { return "None" }
        if ms >= 1_000 {
            return String(format: "%.1f s", ms / 1_000)
        }
        return String(format: "%.0f ms", ms)
    }

    private var issueErrorCount: Int {
        issues.filter { $0.severity == .error }.count
    }

    private var issueWarningCount: Int {
        issues.filter { $0.severity == .warning }.count
    }

    private var issueInfoCount: Int {
        issues.filter { $0.severity == .info }.count
    }

    private var engineStatusLabel: String {
        switch app.engineState {
        case .stopped: return "Stopped"
        case .loading(let progress): return "Loading \(Self.phaseLabel(progress.phase))"
        case .running: return "Running"
        case .standby(.soft): return "Light sleep"
        case .standby(.deep): return "Deep sleep"
        case .error: return "Error"
        }
    }

    private var engineStatusDetail: String {
        switch app.engineState {
        case .stopped: return "No active model"
        case .loading(let progress):
            if let fraction = progress.fraction {
                return "\(Int(fraction * 100))% - \(progress.label)"
            }
            return progress.label.isEmpty ? "Preparing model" : progress.label
        case .running: return "Serving requests"
        case .standby(.soft): return "Weights retained"
        case .standby(.deep): return "Weights unloaded"
        case .error(let message): return message
        }
    }

    private var engineStatusTint: Color {
        switch app.engineState {
        case .stopped: return Theme.Colors.textLow
        case .loading: return Theme.Colors.accent
        case .running: return Theme.Colors.success
        case .standby: return Theme.Colors.warning
        case .error: return Theme.Colors.danger
        }
    }

    private var diagnosticOverview: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 214), spacing: Theme.Spacing.md)],
            spacing: Theme.Spacing.md
        ) {
            diagnosticStatusTile(
                title: "Engine State",
                value: engineStatusLabel,
                caption: engineStatusDetail,
                systemImage: "power.circle",
                tint: engineStatusTint
            )
            diagnosticStatusTile(
                title: "Issue Triage",
                value: "\(issues.count) open",
                caption: "\(issueErrorCount) errors - \(issueWarningCount) warnings - \(issueInfoCount) info",
                systemImage: "cross.case",
                tint: issues.isEmpty ? Theme.Colors.success : Theme.Colors.danger
            )
            diagnosticStatusTile(
                title: "Requests",
                value: metrics.map { "\($0.activeRequests) active" } ?? "-",
                caption: metrics.map { "\($0.queueDepth) queued" } ?? "Waiting for metrics",
                systemImage: "arrow.triangle.2.circlepath",
                tint: Theme.Colors.accent
            )
            diagnosticStatusTile(
                title: "Log Tail",
                value: "\(logs.count) lines",
                caption: "Info and above",
                systemImage: "list.bullet.rectangle",
                tint: Theme.Colors.creative
            )
        }
    }

    private func diagnosticStatusTile(
        title: String,
        value: String,
        caption: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textLow)
                Text(value)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                Text(caption.isEmpty ? "-" : caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
        .background(Theme.ProNoirPanelBackground())
    }

    private func metricCell(_ label: String, _ value: String, _ caption: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 5, height: 5)
                Text(label)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textLow)
                    .lineLimit(1)
            }
            Text(value)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.textHigh)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
            Text(caption)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
                .lineLimit(1)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .background(Theme.Colors.surfaceHi.opacity(0.52))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private var issueTriageBar: some View {
        HStack(spacing: Theme.Spacing.sm) {
            issueCountPill("Errors", issueErrorCount, tint: Theme.Colors.danger)
            issueCountPill("Warnings", issueWarningCount, tint: Theme.Colors.warning)
            issueCountPill("Info", issueInfoCount, tint: Theme.Colors.accent)
            Spacer(minLength: Theme.Spacing.md)
            Text(L10n.Studio.newestFirst.render(AppLocalePreference.current))
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
        }
    }

    private func issueCountPill(_ label: String, _ count: Int, tint: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
            Text("\(count)")
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textHigh)
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textMid)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.Colors.surfaceHi.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private func incidentBrief(_ issue: StudioDiagnosticIssue) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: icon(for: issue.severity))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color(for: issue.severity))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Label(L10n.Studio.incidentBrief.render(AppLocalePreference.current), systemImage: "cross.case")
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.accent)
                    Text(issue.redactedTitle)
                        .font(Theme.Typography.bodyHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(1)
                    Text(issue.redactedMessage)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMid)
                        .lineLimit(2)
                }
                Spacer(minLength: Theme.Spacing.md)
                VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
                    Button {
                        copyIncidentBrief(issue)
                    } label: {
                        Label(L10n.Studio.copyBrief.render(AppLocalePreference.current), systemImage: "doc.on.doc")
                            .font(Theme.Typography.captionHi)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 5)
                    .background(Theme.Colors.surfaceHi.opacity(0.74))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .accessibilityIdentifier(diagnosticsBriefActionTitle(for: issue))
                    .accessibilityLabel(diagnosticsBriefActionTitle(for: issue))

                    Text(Self.relativeFormatter.localizedString(for: issue.createdAt, relativeTo: Date()))
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.textLow)
                }
            }

            incidentRecoveryPath(issue)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 178), spacing: Theme.Spacing.md)],
                spacing: Theme.Spacing.md
            ) {
                incidentFact(
                    "Impact",
                    value: impactText(for: issue),
                    caption: issue.severity.rawValue.capitalized,
                    systemImage: "scope",
                    tint: color(for: issue.severity)
                )
                incidentFact(
                    "Source",
                    value: issue.source.label,
                    caption: "Recorded subsystem",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    tint: Theme.Colors.accent
                )
                incidentFact(
                    "Freshness",
                    value: freshnessText(for: issue),
                    caption: "Recorded \(Self.relativeFormatter.localizedString(for: issue.createdAt, relativeTo: Date()))",
                    systemImage: "clock.badge.exclamationmark",
                    tint: freshnessTint(for: issue)
                )
                incidentFact(
                    "Evidence",
                    value: issue.redactedCompactContext,
                    caption: "Attached context",
                    systemImage: "doc.text.magnifyingglass",
                    tint: Theme.Colors.creative,
                    monospaced: true
                )
                incidentFact(
                    "Next Move",
                    value: nextMove(for: issue.source),
                    caption: "Then refresh diagnostics",
                    systemImage: "arrow.forward.circle",
                    tint: Theme.Colors.success
                )
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.surface.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    private func incidentRecoveryPath(_ issue: StudioDiagnosticIssue) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack {
                Label(L10n.Studio.recoveryPath.render(AppLocalePreference.current), systemImage: "arrow.triangle.branch")
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                Spacer(minLength: Theme.Spacing.sm)
                Text(L10n.Studio.operatorLane.render(AppLocalePreference.current))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                Button {
                    copyRecoveryPath(issue)
                } label: {
                    Label(L10n.Studio.copyPath.render(AppLocalePreference.current), systemImage: "doc.on.doc")
                        .font(Theme.Typography.captionHi)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.Colors.textHigh)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, 5)
                .background(Theme.Colors.surfaceHi.opacity(0.74))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                .accessibilityIdentifier(diagnosticsRecoveryActionTitle(for: issue))
                .accessibilityLabel(diagnosticsRecoveryActionTitle(for: issue))
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: Theme.Spacing.sm)],
                spacing: Theme.Spacing.sm
            ) {
                ForEach(StudioDiagnosticBriefFormatter.recoverySteps(for: issue)) { step in
                    recoveryStep(
                        number: step.number,
                        title: step.title,
                        value: step.value,
                        caption: step.caption,
                        tint: recoveryStepTint(step, for: issue),
                        monospaced: step.isEvidence
                    )
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.background.opacity(0.34))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border.opacity(0.72), lineWidth: 1)
        )
    }

    private func recoveryStep(
        number: String,
        title: String,
        value: String,
        caption: String,
        tint: Color,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Text(number)
                .font(Theme.Typography.captionHi)
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.13))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                Text(value)
                    .font(monospaced ? Theme.Typography.monoCaption : Theme.Typography.bodyHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.78)
                    .textSelection(.enabled)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
        .background(Theme.Colors.surfaceHi.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private func incidentFact(
        _ title: String,
        value: String,
        caption: String,
        systemImage: String,
        tint: Color,
        monospaced: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                Text(value)
                    .font(monospaced ? Theme.Typography.monoCaption : Theme.Typography.bodyHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.75)
                    .textSelection(.enabled)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .background(Theme.Colors.surfaceHi.opacity(0.56))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func diagnosticEmpty(systemImage: String, title: String, caption: String) -> some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(Theme.Colors.textLow)
                .frame(width: 34, height: 34)
                .background(Theme.Colors.surfaceHi.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.Typography.bodyHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surface.opacity(0.42))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func diagnosticIssueRow(_ issue: StudioDiagnosticIssue) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: icon(for: issue.severity))
                .foregroundStyle(color(for: issue.severity))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(issue.redactedTitle)
                        .font(Theme.Typography.bodyHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(1)
                    Text(issue.source.label)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.Colors.surfaceHi)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    Text(freshnessLabel(for: issue))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(freshnessTint(for: issue))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(freshnessTint(for: issue).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    Spacer()
                    Text(Self.relativeFormatter.localizedString(for: issue.createdAt, relativeTo: Date()))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                }
                Text(issue.redactedMessage)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(3)
                Text(issue.redactedCompactContext)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .lineLimit(1)
                HStack(spacing: Theme.Spacing.sm) {
                    Button {
                        copyIncidentBrief(issue)
                    } label: {
                        Label(L10n.Studio.copyBrief.render(AppLocalePreference.current), systemImage: "doc.on.doc")
                            .font(Theme.Typography.captionHi)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 5)
                    .background(Theme.Colors.surface.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .accessibilityIdentifier(diagnosticsBriefActionTitle(for: issue))
                    .accessibilityLabel(diagnosticsBriefActionTitle(for: issue))

                    Button {
                        copyRecoveryPath(issue)
                    } label: {
                        Label(L10n.Studio.copyPath.render(AppLocalePreference.current), systemImage: "arrow.triangle.branch")
                            .font(Theme.Typography.captionHi)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 5)
                    .background(Theme.Colors.surface.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .accessibilityIdentifier(diagnosticsRecoveryActionTitle(for: issue))
                    .accessibilityLabel(diagnosticsRecoveryActionTitle(for: issue))
                }
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.surfaceHi.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func copyIncidentBrief(_ issue: StudioDiagnosticIssue) {
        let text = StudioDiagnosticBriefFormatter.incidentBrief(
            for: issue,
            openIssueCount: issues.count
        )

        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private func copyRecoveryPath(_ issue: StudioDiagnosticIssue) {
        let text = StudioDiagnosticBriefFormatter.recoveryPath(for: issue)

        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private func diagnosticsBriefActionTitle(for issue: StudioDiagnosticIssue) -> String {
        "Diagnostics Copy Brief for \(issue.source.label) \(issue.redactedTitle)"
    }

    private func diagnosticsRecoveryActionTitle(for issue: StudioDiagnosticIssue) -> String {
        "Diagnostics Copy Recovery Path for \(issue.source.label) \(issue.redactedTitle)"
    }

    private func recoveryStepTint(
        _ step: StudioDiagnosticRecoveryStep,
        for issue: StudioDiagnosticIssue
    ) -> Color {
        switch step.number {
        case "1": return color(for: issue.severity)
        case "2": return Theme.Colors.creative
        default: return Theme.Colors.success
        }
    }

    private func impactText(for issue: StudioDiagnosticIssue) -> String {
        StudioDiagnosticBriefFormatter.impactText(for: issue)
    }

    private func nextMove(for source: StudioDiagnosticSource) -> String {
        StudioDiagnosticBriefFormatter.nextMove(for: source)
    }

    private func freshnessLabel(for issue: StudioDiagnosticIssue) -> String {
        StudioDiagnosticBriefFormatter.freshnessLabel(for: issue)
    }

    private func freshnessText(for issue: StudioDiagnosticIssue) -> String {
        StudioDiagnosticBriefFormatter.freshnessText(for: issue)
    }

    private func freshnessTint(for issue: StudioDiagnosticIssue) -> Color {
        StudioDiagnosticBriefFormatter.isFresh(issue)
            ? Theme.Colors.success
            : Theme.Colors.warning
    }

    private var logTableHeader: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(L10n.Studio.time.render(AppLocalePreference.current))
                .frame(width: 60, alignment: .leading)
            Text(L10n.Studio.level.render(AppLocalePreference.current))
                .frame(width: 48, alignment: .leading)
            Text(L10n.Studio.category.render(AppLocalePreference.current))
                .frame(width: 112, alignment: .leading)
            Text(L10n.Studio.message.render(AppLocalePreference.current))
            Spacer(minLength: 0)
        }
        .font(Theme.Typography.captionHi)
        .foregroundStyle(Theme.Colors.textLow)
        .padding(.horizontal, Theme.Spacing.md)
    }

    private func logLineRow(_ line: LogStore.Line) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Text(Self.timeFormatter.string(from: line.timestamp))
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.textLow)
                .frame(width: 60, alignment: .leading)
            Text(line.level.rawValue.uppercased())
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(color(for: line.level))
                .frame(width: 48, alignment: .leading)
            Text(line.category)
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.textLow)
                .frame(width: 112, alignment: .leading)
                .lineLimit(1)
            Text(line.message)
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.textMid)
                .lineLimit(2)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.Colors.border.opacity(0.45))
                .frame(height: 1)
        }
    }

    private func bindDiagnostics() async {
        let service = StudioDiagnosticsService(app: app)
        issues = service.recentIssues()
        logs = await service.logSnapshot()
        let metricStream = await service.metricsStream()
        let logStream = await service.logStream()
        Task {
            for await snapshot in metricStream {
                await MainActor.run { metrics = snapshot }
            }
        }
        Task {
            for await line in logStream {
                await MainActor.run {
                    logs.append(line)
                    logs = Array(logs.suffix(200))
                }
            }
        }
    }

    private func refreshDiagnosticsSnapshot() async {
        let service = StudioDiagnosticsService(app: app)
        issues = service.recentIssues()
        logs = await service.logSnapshot()
    }

    private func clearIssues() {
        StudioDiagnosticsService(app: app).clearIssues()
        issues = []
    }

    private static func phaseLabel(_ phase: LoadProgress.Phase) -> String {
        switch phase {
        case .downloading: return "Downloading"
        case .reading: return "Reading"
        case .quantizing: return "Quantizing"
        case .applying: return "Applying"
        case .warmup: return "Warming"
        case .finalizing: return "Finalizing"
        }
    }

    private func icon(for severity: StudioDiagnosticSeverity) -> String {
        switch severity {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.circle"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for severity: StudioDiagnosticSeverity) -> Color {
        switch severity {
        case .info: return Theme.Colors.accent
        case .warning: return Theme.Colors.warning
        case .error: return Theme.Colors.danger
        }
    }

    private func color(for level: LogStore.Level) -> Color {
        switch level {
        case .trace, .debug: return Theme.Colors.textLow
        case .info: return Theme.Colors.accent
        case .warn: return Theme.Colors.warning
        case .error: return Theme.Colors.danger
        }
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

private struct StudioToolbar<Trailing: View>: View {
    var title: String
    var subtitle: String
    var trailing: () -> Trailing

    init(title: String, subtitle: String = "", @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.textHigh)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                        .lineLimit(1)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.lg)
        .background(Theme.ProNoirBackground())
    }
}

struct ModelRecommendationCard: View {
    var model: RecommendedModel
    var installState: ModelInstallViewState? = nil
    var starterResolution: StarterModelResolution? = nil
    var queue: () -> Void
    var downloadAndChat: () -> Void
    var openLocalStarter: (() -> Void)? = nil

    private var active: Bool { installState?.isActive == true }
    private var resolvedLocal: Bool { starterResolution?.resolvedIdentity != nil }

    private var availabilityLabel: String? {
        switch starterResolution {
        case .included: return "Included"
        case .local: return "On this Mac"
        case .incompatible(_, let reason): return reason
        case .unavailable(let reason): return reason
        case .downloadRequired: return nil
        case nil: return "Checking this Mac…"
        }
    }

    private var primaryLabel: String {
        switch starterResolution {
        case .included: return "Included — Open Chat"
        case .local: return "On this Mac — Open Chat"
        case .incompatible, .unavailable: return "Unavailable"
        case .downloadRequired: return "Download & Chat"
        case nil: return "Checking…"
        }
    }

    private var primaryDisabled: Bool {
        if active || starterResolution == nil { return true }
        switch starterResolution {
        case .incompatible, .unavailable: return true
        case .included, .local, .downloadRequired: return false
        case nil: return true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Image(systemName: resolvedLocal ? "internaldrive" : "arrow.down.circle")
                    .foregroundStyle(Theme.Colors.accent)
                Spacer()
                Text(model.sizeHint)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
            }
            Text(model.ref.displayName)
                .font(Theme.Typography.bodyHi)
                .foregroundStyle(Theme.Colors.textHigh)
            Text(model.summary)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textMid)
                .lineLimit(2)
            tagRow(model.labels)
            if let availabilityLabel {
                Label(
                    availabilityLabel,
                    systemImage: resolvedLocal ? "checkmark.circle.fill" : "info.circle"
                )
                .font(Theme.Typography.captionHi)
                .foregroundStyle(resolvedLocal ? Theme.Colors.success : Theme.Colors.textMid)
            }
            if let installState {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(installState.label)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(installState.phase == .failed ? Theme.Colors.danger : Theme.Colors.textMid)
                        .lineLimit(2)
                    if let progress = installState.progress, active {
                        ProgressView(value: progress)
                            .controlSize(.small)
                    }
                }
            }
            HStack {
                Button {
                    if resolvedLocal {
                        openLocalStarter?()
                    } else {
                        downloadAndChat()
                    }
                } label: {
                    Label(
                        active ? "Working" : primaryLabel,
                        systemImage: active ? "arrow.triangle.2.circlepath" : (resolvedLocal ? "arrow.right.circle" : "arrow.down.circle")
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(primaryDisabled)

                if !resolvedLocal {
                    Button {
                        queue()
                    } label: {
                        Label(L10n.Studio.queue.render(AppLocalePreference.current), systemImage: "tray.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(active || starterResolution == nil)
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.ProNoirPanelBackground(active: active))
    }
}

struct HubModelCandidateCard: View {
    var model: HubModelCandidate
    var gateStatus: HuggingFaceGateStatus
    var installState: ModelInstallViewState?
    var queue: () -> Void
    var downloadAndChat: () -> Void

    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var active: Bool { hovered || focused }
    private var installing: Bool { installState?.isActive == true }
    private var gatedDownloadBlocked: Bool {
        model.gated && !gateStatus.canAttemptGatedDownload
    }
    private var accessibilityName: String { model.ref.repo ?? model.ref.displayName }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .fill(Theme.Colors.surfaceHi)
                    Image(systemName: model.format == "JANG" ? "atom" : "cpu")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(active ? Theme.Colors.accentHi : Theme.Colors.accent)
                }
                .frame(width: 38, height: 38)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .stroke(Theme.Colors.borderHi, lineWidth: 1)
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(model.ref.repo ?? model.ref.displayName)
                        .font(Theme.Typography.bodyHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text("\(model.libraryName) - \(model.pipeline)")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                        .lineLimit(1)
                }

                Spacer(minLength: Theme.Spacing.sm)

                VStack(alignment: .trailing, spacing: 3) {
                    Text(model.sizeHint)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(1)
                    Text(model.sizeHint == "Size unknown" ? "size" : "weights")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                }
            }

            HStack(spacing: Theme.Spacing.sm) {
                HubModelMetric(title: "Weights", value: model.weightHint, systemImage: "shippingbox")
                HubModelMetric(title: "Storage", value: model.storageHint, systemImage: "internaldrive")
                HubModelMetric(title: "Modified", value: model.updatedHint.replacingOccurrences(of: "Updated ", with: ""), systemImage: "calendar")
            }
            .font(Theme.Typography.caption)

            HStack(spacing: Theme.Spacing.md) {
                Label(Self.humanCount(model.downloads), systemImage: "arrow.down.circle")
                Label("\(model.likes)", systemImage: "heart")
                if model.gated {
                    Label(L10n.Studio.gated.render(AppLocalePreference.current), systemImage: "lock")
                        .foregroundStyle(Theme.Colors.warning)
                }
                Spacer(minLength: Theme.Spacing.sm)
                Label(model.format, systemImage: "checkmark.seal")
                    .foregroundStyle(Theme.Colors.success)
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textLow)

            tagRow(model.labels)

            Label(model.compatibilityNote, systemImage: "bolt.horizontal.circle")
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textMid)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if model.gated {
                Label(gateStatus.gatedRepoHint, systemImage: gatedDownloadBlocked ? "lock.fill" : "lock.open")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(gatedDownloadBlocked ? Theme.Colors.warning : Theme.Colors.success)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let installState {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: icon(for: installState.phase))
                            .foregroundStyle(color(for: installState.phase))
                        Text(installState.label)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(installState.phase == .failed ? Theme.Colors.danger : Theme.Colors.textMid)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    if let progress = installState.progress, installing {
                        ProgressView(value: progress)
                            .controlSize(.small)
                    }
                    if let path = installState.localPath, !installing {
                        Text(path)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textLow)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
            }

            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    downloadAndChat()
                } label: {
                    Label(installing ? "Working" : "Download & Chat", systemImage: installing ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel(L10n.Studio.a11yDownloadAndChat.render(AppLocalePreference.current, accessibilityName))
                .accessibilityIdentifier("Hub Download and Chat \(accessibilityName)")
                .disabled(installing || gatedDownloadBlocked)

                Button {
                    queue()
                } label: {
                    Label(L10n.Studio.queue.render(AppLocalePreference.current), systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(L10n.Studio.a11yQueueDownload.render(AppLocalePreference.current, accessibilityName))
                .accessibilityIdentifier("Hub Queue Download \(accessibilityName)")
                .disabled(installing || gatedDownloadBlocked)
            }
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.ProNoirPanelBackground(active: active))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .shadow(color: Color.black.opacity(active ? 0.18 : 0), radius: active ? 14 : 0, y: active ? 8 : 0)
        .scaleEffect(active && !reduceMotion ? 1.01 : 1)
        .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.82), value: active)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .focusable()
        .focused($focused)
        .onHover { hovered = $0 }
        .help(model.ref.repo ?? model.ref.displayName)
    }

    private func icon(for phase: ModelInstallViewState.Phase) -> String {
        switch phase {
        case .queued: return "clock"
        case .downloading: return "arrow.down.circle"
        case .verifying: return "checkmark.shield"
        case .installed: return "checkmark.circle"
        case .loading: return "bolt.horizontal.circle"
        case .ready: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }

    private func color(for phase: ModelInstallViewState.Phase) -> Color {
        switch phase {
        case .ready, .installed: return Theme.Colors.success
        case .failed: return Theme.Colors.danger
        case .verifying: return Theme.Colors.warning
        default: return Theme.Colors.accent
        }
    }

    private static func humanCount(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1_000 { return String(format: "%.1fk", Double(count) / 1_000) }
        return "\(count)"
    }
}

private struct HubModelMetric: View {
    var title: String
    var value: String
    var systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.Colors.textLow)
                .frame(width: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                Text(value)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(Theme.Colors.surface.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }
}

private struct ModelRow: View {
    var model: ModelSummary
    var selected: Bool
    var select: () -> Void
    var load: () -> Void
    var chat: () -> Void
    var create: () -> Void
    var delete: () -> Void

    private var isImage: Bool {
        model.modality.localizedCaseInsensitiveContains("image")
    }

    private var routeReadiness: StudioModelRouteReadiness.Summary {
        StudioModelRouteReadiness.summary(for: model)
    }

    private var capabilityTitle: String {
        routeReadiness.badge
    }

    private var stateTitle: String {
        if model.isLoaded { return "Loaded in memory" }
        if selected { return "Selected" }
        return "Ready on disk"
    }

    private var capabilityIcon: String {
        isImage ? "wand.and.stars" : "bubble.left.and.bubble.right"
    }

    private var capabilityTint: Color {
        switch routeReadiness.level {
        case .chatReady:
            return Theme.Colors.accent
        case .imageProvenReady:
            return Theme.Colors.success
        case .imageNeedsProof:
            return Theme.Colors.warning
        }
    }

    private var selectAccessibilityTitle: String {
        StudioModelActionCopy.selectAccessibilityTitle(for: model, selected: selected)
    }

    private var loadAccessibilityTitle: String {
        StudioModelActionCopy.loadAccessibilityTitle(for: model, readiness: routeReadiness)
    }

    private var routeAccessibilityTitle: String {
        StudioModelActionCopy.routeAccessibilityTitle(
            for: model,
            readiness: routeReadiness,
            isImage: isImage
        )
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .fill(Theme.Colors.surfaceHi.opacity(0.70))
                Image(systemName: selected ? "checkmark.circle.fill" : capabilityIcon)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(selected ? Theme.Colors.success : capabilityTint)
            }
            .frame(width: 46, height: 46)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .stroke(selected ? Theme.Colors.accent.opacity(0.85) : Theme.Colors.border, lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(model.ref.displayName)
                        .font(Theme.Typography.bodyHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(capabilityTitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(capabilityTint)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(capabilityTint.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                }

                HStack(spacing: Theme.Spacing.sm) {
                    modelRowFact(model.family, systemImage: "cpu")
                    modelRowFact(model.modality.capitalized, systemImage: capabilityIcon)
                    modelRowFact(formattedBytes(model.sizeBytes), systemImage: "internaldrive")
                    modelRowFact(stateTitle, systemImage: model.isLoaded ? "bolt.fill" : "checkmark.circle")
                }

                tagRow(model.labels)
            }
            .layoutPriority(1)

            rowDecisionSignal
                .frame(width: 218, alignment: .leading)

            Spacer(minLength: Theme.Spacing.md)

            HStack(spacing: Theme.Spacing.sm) {
                Button {
                    select()
                } label: {
                    Label(selected ? "Selected" : "Select", systemImage: selected ? "checkmark.circle.fill" : "target")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(selectAccessibilityTitle)
                .accessibilityIdentifier(selectAccessibilityTitle)

                Button {
                    load()
                } label: {
                    Label(routeReadiness.loadTitle, systemImage: "bolt")
                }
                .buttonStyle(.bordered)
                .disabled(routeReadiness.loadDisabledReason != nil)
                .accessibilityLabel(loadAccessibilityTitle)
                .accessibilityIdentifier(loadAccessibilityTitle)
                .help(routeReadiness.loadDisabledReason ?? "Load this chat model into memory.")

                if isImage {
                    Button {
                        create()
                    } label: {
                        Label(routeReadiness.actionTitle, systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(routeAccessibilityTitle)
                    .accessibilityIdentifier(routeAccessibilityTitle)
                } else {
                    Button {
                        chat()
                    } label: {
                        Label(L10n.Studio.chat.render(AppLocalePreference.current), systemImage: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(routeAccessibilityTitle)
                    .accessibilityIdentifier(routeAccessibilityTitle)
                }

                Button(role: .destructive, action: delete) {
                    Label(StudioModelDeleteCopy.actionTitle, systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .disabled(StudioModelDeleteCopy.disabledReason(for: model) != nil)
                .accessibilityLabel(StudioModelDeleteCopy.accessibilityTitle(for: model))
                .accessibilityIdentifier(StudioModelDeleteCopy.accessibilityTitle(for: model))
                .help(StudioModelDeleteCopy.disabledReason(for: model) ?? "Deletes the model folder from disk.")
            }
            .controlSize(.small)
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.ProNoirPanelBackground(active: selected))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    private var rowDecisionSignal: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(primaryMoveTitle, systemImage: isImage ? "wand.and.stars" : "bubble.left.and.bubble.right")
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textHigh)
                .lineLimit(1)
            Text(primaryMoveCaption)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
                .lineLimit(1)
            HStack(spacing: 6) {
                rowSignalPill(
                    "Memory fit",
                    footprintTitle,
                    systemImage: "memorychip",
                    tint: footprintTint,
                    caption: memoryFitEvidenceSummary,
                    accessibilityLabel: memoryFitEvidenceLabel
                )
                rowSignalPill(routeReadiness.routeName, routeSignalValue, systemImage: capabilityIcon, tint: capabilityTint)
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 7)
        .background(Theme.Colors.surfaceHi.opacity(0.42))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border.opacity(0.72), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private var primaryMoveTitle: String {
        if model.isLoaded { return "Live model" }
        if selected { return routeReadiness.selectedTitle }
        return routeReadiness.readyTitle
    }

    private var primaryMoveCaption: String {
        if model.isLoaded { return "Weights are already in memory" }
        if selected { return routeReadiness.selectedCaption }
        return routeReadiness.readyCaption
    }

    private var routeSignalValue: String {
        switch routeReadiness.level {
        case .chatReady:
            return selected ? "Selected" : routeReadiness.routeValue
        case .imageProvenReady:
            return selected ? "Selected" : routeReadiness.routeValue
        case .imageNeedsProof:
            return routeReadiness.routeValue
        }
    }

    private var memoryFit: StudioModelMemoryFit.Result {
        StudioModelMemoryFit.classify(sizeBytes: model.sizeBytes, modality: model.modality)
    }

    private var footprintTitle: String {
        memoryFit.title
    }

    private var footprintTint: Color {
        switch memoryFit.level {
        case .spacious, .comfort:
            return Theme.Colors.success
        case .tight:
            return Theme.Colors.warning
        case .risky, .over:
            return Theme.Colors.danger
        }
    }

    private var memoryFitEvidenceLabel: String {
        let runtime = formattedBytes(Int64(clamping: memoryFit.estimatedRuntimeBytes))
        let system = formattedBytes(Int64(clamping: memoryFit.systemMemoryBytes))
        return "Memory fit \(memoryFit.title). Estimated runtime \(runtime) against \(system) system memory. Visible estimate \(memoryFitEvidenceSummary)."
    }

    private var memoryFitEvidenceSummary: String {
        "\(compactGigabytes(memoryFit.estimatedRuntimeBytes))/\(compactGigabytes(memoryFit.systemMemoryBytes)) GB est"
    }

    private func rowSignalPill(
        _ title: String,
        _ value: String,
        systemImage: String,
        tint: Color,
        caption: String? = nil,
        accessibilityLabel: String? = nil
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .lineLimit(1)
                Text(value)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(1)
                if let caption {
                    Text(caption)
                        .font(Theme.Typography.monoCaption)
                        .foregroundStyle(Theme.Colors.textLow)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilityLabel ?? "\(title) \(value)"))
    }

    private func compactGigabytes(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / 1_073_741_824
        if gib >= 10 {
            return "\(Int(gib.rounded()))"
        }
        return String(format: "%.1f", gib)
    }

    private func modelRowFact(_ value: String, systemImage: String) -> some View {
        Label(value, systemImage: systemImage)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textLow)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

private struct AdvancedLabCard<Content: View>: View {
    var title: String
    var subtitle: String
    var systemImage: String
    var content: () -> Content

    @State private var hovered = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var active: Bool { hovered || focused }

    init(
        title: String,
        subtitle: String,
        systemImage: String,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: systemImage)
                    .foregroundStyle(Theme.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    glitchTitle
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                }
                Spacer()
                Text(L10n.Studio.advanced.render(AppLocalePreference.current))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 4)
                    .background(Theme.Colors.surfaceHi.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
            content()
        }
        .padding(Theme.Spacing.lg)
        .background(Theme.ProNoirPanelBackground(active: active))
        .overlay(alignment: .trailing) {
            DeAlignMascotMark()
                .frame(width: 78, height: 78)
                .opacity(active ? 0.18 : 0)
                .offset(x: active ? (reduceMotion ? 20 : 12) : 48)
                .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8), value: active)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .focusable()
        .focused($focused)
        .onHover { hovered = $0 }
        .help(title)
    }

    private var glitchTitle: some View {
        ZStack(alignment: .leading) {
            Text(title)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.textHigh)
            if active && !reduceMotion {
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.accent.opacity(0.55))
                    .offset(x: 1, y: -1)
                Text(title)
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.danger.opacity(0.35))
                    .offset(x: -1, y: 1)
            }
        }
    }
}

struct DeAlignMascotMark: View {
    var body: some View {
        #if canImport(AppKit)
        if let mascot = DeAlignBrandAssets.mascotImage {
            Image(nsImage: mascot)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .accessibilityLabel(L10n.Studio.deAlignMascot.render(AppLocalePreference.current))
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        Image(systemName: "sparkles")
            .resizable()
            .scaledToFit()
            .padding(4)
            .foregroundStyle(Theme.Colors.textMid)
    }
}

private enum DeAlignBrandAssets {
    #if canImport(AppKit)
    static let mascotImage: NSImage? = {
        let bundle = Bundle.module
        let rootURL = bundle.url(
            forResource: "dealign-mascot-static",
            withExtension: "svg"
        )
        let nestedURL = bundle.url(
            forResource: "dealign-mascot-static",
            withExtension: "svg",
            subdirectory: "DeAlign"
        )
        guard let url = rootURL ?? nestedURL else { return nil }
        return NSImage(contentsOf: url)
    }()
    #endif
}

private func tagRow(_ labels: [String]) -> some View {
    HStack(spacing: Theme.Spacing.xs) {
        ForEach(labels.prefix(4), id: \.self) { label in
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textMid)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Theme.Colors.surfaceHi.opacity(0.9))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
    }
}

private func formattedBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.allowedUnits = [.useGB, .useMB, .useKB]
    formatter.countStyle = .file
    return formatter.string(fromByteCount: bytes)
}
