import SwiftUI
import vMLXEngine
import vMLXTheme

#if canImport(AppKit)
import AppKit
#endif

enum OnboardingGoalRoute: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case coding = "Coding"
    case images = "Images"
    case research = "Research"

    var id: String { rawValue }

    var landingMode: AppState.Mode {
        switch self {
        case .images:
            return .create
        case .chat, .coding, .research:
            return .chat
        }
    }

    var landingName: String {
        landingMode.rawValue
    }

    var description: String {
        switch self {
        case .images:
            return "Start in Create with proof-gated local image models and reusable settings."
        case .coding:
            return "Start in Chat with a coding prompt ready and keep advanced server controls hidden until needed."
        case .research:
            return "Start in Chat with a research brief prompt, then save useful sessions into Library."
        case .chat:
            return "Start in Chat with a first-message prompt and a starter model option."
        }
    }

    var handoffSuccessText: String {
        switch self {
        case .images:
            return "Canvas ready"
        case .coding:
            return "Coding prompt"
        case .research:
            return "Research prompt"
        case .chat:
            return "Prompt ready"
        }
    }

    var goalPromise: String {
        switch self {
        case .images:
            return "Proof-gated canvas with reusable settings."
        case .coding:
            return "Coding prompt prepared in Chat."
        case .research:
            return "Research prompt prepared for a Library-ready session."
        case .chat:
            return "First message prepared with a starter model option."
        }
    }

    var systemImage: String {
        switch self {
        case .images:
            return "wand.and.stars"
        case .coding:
            return "curlybraces"
        case .research:
            return "doc.text.magnifyingglass"
        case .chat:
            return "bubble.left.and.bubble.right"
        }
    }

    var chatPromptHandoff: StudioChatPromptHandoff? {
        switch self {
        case .images:
            return nil
        case .chat:
            return StudioChatPromptHandoff(
                title: "First local chat",
                prompt: "Give me a concise first local AI reply and suggest one practical next step.",
                status: "Prepared first local chat prompt"
            )
        case .coding:
            return StudioChatPromptHandoff(
                title: "Local coding chat",
                prompt: "Help me review a code change. Ask for the files, then list likely failure modes and tests.",
                status: "Prepared local coding prompt"
            )
        case .research:
            return StudioChatPromptHandoff(
                title: "Research brief",
                prompt: "Help me turn a research question into a local brief with sources to collect, assumptions, and next steps.",
                status: "Prepared research brief prompt"
            )
        }
    }
}

struct OnboardingPreparationState: Equatable {
    var route: OnboardingGoalRoute
    var landingName: String
    var selectedDirectoryName: String?
    var hasRecommendedStarter: Bool
    var starterPhase: ModelInstallViewState.Phase?
    var hfToken: String

    var hasHuggingFaceToken: Bool {
        !hfToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var handoffPrepText: String {
        if selectedDirectoryName != nil {
            return "Local folder"
        }
        if route == .images {
            return "Proof check"
        }
        if let phase = starterPhase {
            return starterPhaseLabel(phase)
        }
        return hasRecommendedStarter ? "Starter offered" : "Scan model"
    }

    var modelStepTitle: String {
        if selectedDirectoryName != nil {
            return "Scan model folder"
        }
        if route == .images {
            return "Check image runtime"
        }
        if starterPhase != nil {
            return "Prepare model"
        }
        return "Choose model source"
    }

    var modelStepCaption: String {
        if selectedDirectoryName != nil {
            return "Folder selected"
        }
        if route == .images {
            return "Proof-gated canvas"
        }
        if let phase = starterPhase {
            return starterPhaseLabel(phase)
        }
        return hasRecommendedStarter ? "Starter available" : "Scan local folder"
    }

    var folderTokenHelpText: String {
        switch (selectedDirectoryName, hasHuggingFaceToken) {
        case (.some(let name), true):
            return "MLX Studio will scan \(name), save the token in Keychain, and land you in \(landingName)."
        case (.some(let name), false):
            return "MLX Studio will scan \(name). No token will be saved; gated repos can be added later."
        case (.none, true):
            return "MLX Studio will save the token in Keychain. Local folders can be scanned later from Models."
        case (.none, false):
            return "No folder or token selected. You can finish now; local folders and gated tokens can be added later from Models."
        }
    }

    private func starterPhaseLabel(_ phase: ModelInstallViewState.Phase) -> String {
        switch phase {
        case .queued:
            return "Queued"
        case .downloading:
            return "Downloading"
        case .verifying:
            return "Verifying"
        case .installed:
            return "Installed"
        case .loading:
            return "Loading"
        case .ready:
            return "Starter ready"
        case .failed:
            return "Retry starter"
        }
    }
}

struct AdvancedOnboardingPreparationState: Equatable {
    var openServerAfterSetup: Bool

    var landingName: String {
        openServerAfterSetup ? "Server" : "Models"
    }

    var handoffText: String {
        "Finish opens \(landingName)"
    }

    var toggleTitle: String {
        "Open Server after setup"
    }

    var helpText: String {
        if openServerAfterSetup {
            return "Finish opens Server with manual Start/Stop controls. API stays off until started."
        }
        return "Finish opens Models so you can pick or scan a model before opening Server."
    }
}

struct SetupScreen: View {
    @Environment(AppState.self) private var app
    @State private var step = 0
    @State private var selectedMode: ExperienceMode = .beginner
    @State private var selectedUse: OnboardingGoalRoute = .chat
    @State private var hfToken = ""
    @State private var openServerAfterSetup = true
    @State private var selectedDirectory: URL?
    @State private var recommended: [RecommendedModel] = []
    @State private var status = ""
    @State private var starterInstallState: ModelInstallViewState?

    private let uses = OnboardingGoalRoute.allCases

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.Colors.border)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Theme.Spacing.xl)
            Divider().background(Theme.Colors.border)
            footer
        }
        .tint(Theme.Colors.accent)
        .background(Theme.ProNoirBackground())
        .task {
            recommended = (try? await StudioModelService(app: app).listRecommendedModels()) ?? []
        }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            DeAlignMascotMark()
                .frame(width: 34, height: 34)
                .foregroundStyle(Theme.Colors.textHigh)
            VStack(alignment: .leading, spacing: 2) {
                Text(AppCopy.productName)
                    .font(.system(size: 17, weight: .semibold, design: .default))
                    .foregroundStyle(Theme.Colors.textHigh)
                Text(L10n.Onboarding.firstRunStepFormat.render(AppLocalePreference.current, step + 1))
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textLow)
            }
            Spacer()
        }
        .padding(Theme.Spacing.lg)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0:
            welcome
        case 1:
            modeChoice
        default:
            selectedMode == .beginner ? AnyView(beginnerSetup) : AnyView(advancedSetup)
        }
    }

    private var welcome: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.xxl) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                DeAlignMascotMark()
                    .frame(width: 78, height: 78)
                    .foregroundStyle(Theme.Colors.accent)

                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text(L10n.Onboarding.welcomeTitle.render(AppLocalePreference.current))
                        .font(Theme.Typography.display)
                        .foregroundStyle(Theme.Colors.textHigh)
                    Text(L10n.Onboarding.welcomeBody.render(AppLocalePreference.current))
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textMid)
                        .lineSpacing(4)
                        .frame(maxWidth: 440, alignment: .leading)
                }
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                onboardingPill("Chat locally", "Download a starter model or use one already on disk.", "bubble.left.and.bubble.right", Theme.Colors.success)
                onboardingPill("Create images", "Use proof-gated image models when the runtime can really produce PNGs.", "wand.and.stars", Theme.Colors.creative)
                onboardingPill("Keep control", "Models, prompts, history, and server state stay inspectable on this Mac.", "internaldrive", Theme.Colors.accent)
            }
            .frame(width: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var modeChoice: some View {
        VStack(spacing: Theme.Spacing.xl) {
            VStack(spacing: Theme.Spacing.sm) {
                Text(L10n.Onboarding.modeChoiceTitle.render(AppLocalePreference.current))
                    .font(Theme.Typography.display)
                    .foregroundStyle(Theme.Colors.textHigh)
                Text(L10n.Onboarding.modeChoiceBody.render(AppLocalePreference.current))
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textMid)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }

            HStack(spacing: Theme.Spacing.lg) {
                modeCard(.beginner, systemImage: "sparkles")
                modeCard(.advanced, systemImage: "atom")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var beginnerSetup: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(L10n.Onboarding.pickResultTitle.render(AppLocalePreference.current))
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textHigh)
                    Text(useDescription)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textMid)
                }
                Spacer(minLength: Theme.Spacing.md)
                readyHandoffCard
            }

            goalRouteGrid

            firstResultRunway

            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                if let starter = recommended.first {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text(L10n.Onboarding.recommendedStarter.render(AppLocalePreference.current))
                            .font(Theme.Typography.captionHi)
                            .foregroundStyle(Theme.Colors.textLow)
                        ModelRecommendationCard(
                            model: starter,
                            installState: starterInstallState,
                            queue: { installStarter(starter, openChat: false) },
                            downloadAndChat: { installStarter(starter, openChat: true) }
                        )
                    }
                    .frame(maxWidth: 380)
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    Text(L10n.Onboarding.alreadyHaveModels.render(AppLocalePreference.current))
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.textLow)

                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Button {
                            chooseDirectory()
                        } label: {
                            Label(selectedDirectory?.lastPathComponent ?? "Scan local model folder", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(.bordered)

                        SecureField("Hugging Face token (optional)", text: $hfToken)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 340)
                            .accessibilityLabel(L10n.Onboarding.a11yHFToken.render(AppLocalePreference.current))

                        Text(preparationState.folderTokenHelpText)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textLow)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Theme.Spacing.lg)
                    .background(Theme.ProNoirPanelBackground())
                }
                .frame(maxWidth: 360)
            }

            if !status.isEmpty {
                Text(status)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .textSelection(.enabled)
            }
            Spacer()
        }
    }

    private var readyHandoffCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Label(L10n.Onboarding.a11yReadyHandoff.render(AppLocalePreference.current), systemImage: "arrow.right.circle")
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.success)
                Spacer(minLength: 0)
                Text(L10n.Onboarding.finishOpensFormat.render(AppLocalePreference.current, landingName))
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
            }

            HStack(spacing: Theme.Spacing.sm) {
                handoffFact("Prepare", handoffPrepText, tint: Theme.Colors.accent)
                handoffFact("Success", handoffSuccessText, tint: goalTint(for: selectedUse))
            }
        }
        .padding(Theme.Spacing.sm)
        .frame(width: 256, alignment: .leading)
        .background(Theme.Colors.surfaceHi.opacity(0.54))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.success.opacity(0.24), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func handoffFact(_ title: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
            Text(value)
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textHigh)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private var firstResultRunway: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label(L10n.Onboarding.a11yFirstResultPath.render(AppLocalePreference.current), systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textLow)
            HStack(spacing: Theme.Spacing.md) {
                resultPathTile(
                    "1",
                    "Choose goal",
                    selectedUse.rawValue,
                    systemImage: selectedUse.systemImage,
                    tint: Theme.Colors.accent
                )
                resultPathTile(
                    "2",
                    preparationState.modelStepTitle,
                    preparationState.modelStepCaption,
                    systemImage: "externaldrive.badge.plus",
                    tint: Theme.Colors.success
                )
                resultPathTile(
                    "3",
                    "Land ready",
                    "Finish lands in \(landingName)",
                    systemImage: "arrow.right.circle",
                    tint: Theme.Colors.creative
                )
            }
        }
    }

    private var goalRouteGrid: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label(L10n.Onboarding.a11yGoalRoutes.render(AppLocalePreference.current), systemImage: "sparkles")
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textLow)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 158), spacing: Theme.Spacing.sm)],
                spacing: Theme.Spacing.sm
            ) {
                ForEach(uses, id: \.self) { use in
                    goalRouteCard(use)
                }
            }
        }
    }

    private func goalRouteCard(_ use: OnboardingGoalRoute) -> some View {
        let selected = selectedUse == use
        return Button {
            selectedUse = use
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: use.systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(goalTint(for: use))
                        .frame(width: 18)
                    Text(use.rawValue)
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Colors.success)
                    }
                }
                Text(use.goalPromise)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(2)
                Text(L10n.Onboarding.opensFormat.render(AppLocalePreference.current, use.landingName))
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(selected ? Theme.Colors.success : Theme.Colors.textLow)
            }
            .padding(Theme.Spacing.sm)
            .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
            .background(Theme.ProNoirPanelBackground(active: selected))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Onboarding \(use.rawValue) route")
        .accessibilityLabel(L10n.Onboarding.a11yOnboardingRouteFormat.render(AppLocalePreference.current, use.rawValue))
    }

    private func resultPathTile(
        _ number: String,
        _ title: String,
        _ caption: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Text(number)
                .font(Theme.Typography.monoCaption)
                .foregroundStyle(Theme.Colors.background)
                .frame(width: 22, height: 22)
                .background(tint)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            VStack(alignment: .leading, spacing: 2) {
                Label(title, systemImage: systemImage)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .background(tint.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private var advancedSetup: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            Text(L10n.Onboarding.advancedSetupTitle.render(AppLocalePreference.current))
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Colors.textHigh)
            Text(L10n.Onboarding.advancedSetupBody.render(AppLocalePreference.current))
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textMid)
                .frame(maxWidth: 560, alignment: .leading)
            HStack(spacing: Theme.Spacing.md) {
                Button {
                    chooseDirectory()
                } label: {
                    Label(selectedDirectory?.lastPathComponent ?? "Model Directory", systemImage: "folder")
                }
                Toggle(advancedPreparationState.toggleTitle, isOn: $openServerAfterSetup)
                    .toggleStyle(.switch)
            }
            SecureField("Hugging Face token", text: $hfToken)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                .accessibilityLabel(L10n.Onboarding.a11yHFToken.render(AppLocalePreference.current))
            Text(advancedPreparationState.handoffText)
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textHigh)
            Text(advancedPreparationState.helpText)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
            Spacer()
        }
    }

    private func modeCard(_ mode: ExperienceMode, systemImage: String) -> some View {
        Button {
            selectedMode = mode
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                    Image(systemName: systemImage)
                        .font(.system(size: 28))
                        .foregroundStyle(mode == .advanced ? Theme.Colors.accent : Theme.Colors.success)
                    Spacer()
                    if selectedMode == mode {
                        Label(L10n.Onboarding.selected.render(AppLocalePreference.current), systemImage: "checkmark.circle.fill")
                            .font(Theme.Typography.captionHi)
                            .foregroundStyle(Theme.Colors.success)
                    }
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(mode.label)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textHigh)
                    Text(mode.onboardingTitle)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textMid)
                        .multilineTextAlignment(.leading)
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    ForEach(modeHighlights(for: mode), id: \.self) { highlight in
                        Label(highlight, systemImage: mode == .advanced ? "slider.horizontal.3" : "checkmark")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textMid)
                            .lineLimit(2)
                    }
                }
                .padding(.top, Theme.Spacing.xs)

                Text(modeFooter(for: mode))
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(mode == .advanced ? Theme.Colors.accent : Theme.Colors.success)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background((mode == .advanced ? Theme.Colors.accent : Theme.Colors.success).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
            .frame(width: 260, height: 250, alignment: .topLeading)
            .padding(Theme.Spacing.lg)
            .background(
                Theme.ProNoirPanelBackground(active: selectedMode == mode)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Onboarding \(mode.label) mode")
    }

    private func modeHighlights(for mode: ExperienceMode) -> [String] {
        switch mode {
        case .beginner:
            return [
                "Chat, Create, Models, Library",
                "Advanced controls stay tucked away",
                "Best for first local result"
            ]
        case .advanced:
            return [
                "Server, Diagnostics, Model lab",
                "Copyable routes and runtime inspectors",
                "Best for operators and builders"
            ]
        }
    }

    private func modeFooter(for mode: ExperienceMode) -> String {
        switch mode {
        case .beginner:
            return "Recommended first"
        case .advanced:
            return "Full control"
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { step -= 1 }
            }
            Spacer()
            if step < 2 {
                Button("Next") { step += 1 }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Finish") { finish() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Spacing.lg)
    }

    private func chooseDirectory() {
        if let automatedURL = automatedOnboardingModelDirectory() {
            selectDirectory(automatedURL)
            return
        }

        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            selectDirectory(url)
        }
        #endif
    }

    private func selectDirectory(_ url: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            status = "Model folder not found: \(url.lastPathComponent)"
            return
        }

        selectedDirectory = url
        status = "Scanning local model folder: \(url.lastPathComponent)"
        Task {
            await StudioModelService(app: app).addLocalModelDirectory(url)
            status = "Scanned local model folder: \(url.lastPathComponent)"
        }
    }

    private func automatedOnboardingModelDirectory() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["MLX_STUDIO_ONBOARDING_MODEL_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func installStarter(_ model: RecommendedModel, openChat: Bool) {
        guard starterInstallState?.isActive != true else { return }
        Task {
            do {
                guard let repo = model.ref.repo else { throw StudioServiceError.modelNotLocal }
                let request = ModelInstallRequest(
                    repo: repo,
                    displayName: model.ref.displayName,
                    source: .onboarding,
                    openChatWhenReady: openChat
                )
                let stream = StudioModelInstallService(app: app).install(request)
                for try await event in stream {
                    let viewState = ModelInstallViewState.from(event)
                    starterInstallState = viewState
                    status = viewState.label
                    if case .ready = event, openChat {
                        app.markFirstLaunchComplete(mode: .beginner)
                    }
                }
            } catch {
                status = error.localizedDescription
                starterInstallState = .init(
                    phase: .failed,
                    label: error.localizedDescription,
                    progress: nil,
                    localPath: nil
                )
            }
        }
    }

    private func finish() {
        Task {
            if !hfToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                _ = await HuggingFaceAuth.shared.save(token: hfToken, validate: false)
            }
            await MainActor.run {
                if selectedMode == .beginner {
                    app.pendingStudioChatPrompt = selectedUse.chatPromptHandoff
                } else {
                    app.pendingStudioChatPrompt = nil
                }
                app.markFirstLaunchComplete(mode: selectedMode)
                app.mode = selectedMode == .advanced ? (openServerAfterSetup ? .server : .models) : selectedUse.landingMode
            }
        }
    }

    private var landingMode: AppState.Mode {
        selectedUse.landingMode
    }

    private var landingName: String {
        selectedUse.landingName
    }

    private var useDescription: String {
        selectedUse.description
    }

    private var preparationState: OnboardingPreparationState {
        OnboardingPreparationState(
            route: selectedUse,
            landingName: landingName,
            selectedDirectoryName: selectedDirectory?.lastPathComponent,
            hasRecommendedStarter: recommended.first != nil,
            starterPhase: starterInstallState?.phase,
            hfToken: hfToken
        )
    }

    private var advancedPreparationState: AdvancedOnboardingPreparationState {
        AdvancedOnboardingPreparationState(openServerAfterSetup: openServerAfterSetup)
    }

    private var handoffPrepText: String {
        preparationState.handoffPrepText
    }

    private var handoffSuccessText: String {
        selectedUse.handoffSuccessText
    }

    private func goalTint(for use: OnboardingGoalRoute) -> Color {
        switch use {
        case .images: return Theme.Colors.creative
        case .coding: return Theme.Colors.accent
        case .research: return Theme.Colors.warning
        case .chat: return Theme.Colors.success
        }
    }

    private func onboardingPill(
        _ title: String,
        _ caption: String,
        _ systemImage: String,
        _ color: Color
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.Typography.bodyHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.ProNoirPanelBackground())
    }
}
