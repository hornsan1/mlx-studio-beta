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

struct StudioChatScreen: View {
    @Environment(AppState.self) private var app
    @State private var localModels: [ModelSummary] = []
    @State private var recommended: [RecommendedModel] = []
    @State private var selectedModelID: String?
    @State private var isModelPickerPresented = false
    @State private var prompt = ""
    @State private var sessions: [StudioChatSession] = StudioChatHistoryStore.loadSessions()
    @State private var activeSessionID: UUID?
    @State private var draftHandoffTitle: String?
    @State private var turns: [ChatTurn] = []
    @State private var isLoadingModel = false
    @State private var isStreaming = false
    @State private var status = "Ready"
    @State private var starterInstallState: ModelInstallViewState?
    @State private var streamTask: Task<Void, Never>?
    @State private var streamingAssistantID: UUID?
    @State private var preSessionModelPath: URL?

    private struct ComposerSuggestion: Identifiable {
        let id: String
        let title: String
        let caption: String
        let prompt: String
        let systemImage: String
        let tint: Color
    }

    private var selectedModel: ModelSummary? {
        chatCapableModels.first { $0.id == selectedModelID }
    }

    private var chatCapableModels: [ModelSummary] {
        StudioChatModelSelection.chatCapableModels(in: localModels)
    }

    private var activeSession: StudioChatSession? {
        guard let activeSessionID else { return nil }
        return sessions.first { $0.id == activeSessionID }
    }

    private var sessionMenuTitle: String {
        activeSession?.title ?? draftHandoffTitle ?? "New Chat"
    }

    private var draftSessionTitle: String {
        activeSession?.title ?? draftHandoffTitle ?? "Draft session"
    }

    private var emptyChatTitle: String {
        draftHandoffTitle ?? "Start a local conversation"
    }

    private var emptyChatCaption: String {
        if draftHandoffTitle != nil {
            return "Prepared prompt is ready in the composer. Send it to save this workspace into Library."
        }
        return "Pick a model, load it once, then keep the session in Library with its prompts, model, and history intact."
    }

    private var recordedSessionModelName: String? {
        normalizedModelName(activeSession?.modelName)
    }

    private var selectedReplyModelName: String? {
        normalizedModelName(selectedModel?.ref.displayName)
    }

    private var activeReplyModelName: String? {
        selectedReplyModelName ?? recordedSessionModelName
    }

    private var sessionModelMismatch: (recorded: String, selected: String)? {
        guard let recordedSessionModelName,
              let selectedReplyModelName,
              recordedSessionModelName != selectedReplyModelName
        else { return nil }
        return (recordedSessionModelName, selectedReplyModelName)
    }

    private var loadButtonTitle: String {
        if isLoadingModel { return "Loading" }
        if selectedModel?.isLoaded == true { return "Loaded" }
        return "Load"
    }

    private var loadButtonSystemImage: String {
        if isLoadingModel { return "hourglass" }
        if selectedModel?.isLoaded == true { return "checkmark.circle.fill" }
        return "bolt.horizontal"
    }

    private var loadButtonDisabled: Bool {
        selectedModel == nil || isLoadingModel || selectedModel?.isLoaded == true
    }

    private var loadButtonHelp: String {
        if selectedModel == nil { return "Select a chat-capable model first." }
        if selectedModel?.isLoaded == true { return "Model is already loaded in memory." }
        return "Load the selected chat model into memory."
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioToolbar(title: "Chat", subtitle: status) {
                sessionMenu
                Button {
                    newSession()
                } label: {
                    Label(L10n.Studio.new.render(AppLocalePreference.current), systemImage: "plus.bubble")
                }
                .disabled(isStreaming)
                Button {
                    toggleActiveSessionPinned()
                } label: {
                    Label(
                        activeSession?.isPinned == true ? "Unpin" : "Pin",
                        systemImage: activeSession?.isPinned == true ? "pin.slash" : "pin"
                    )
                }
                .disabled(activeSession == nil || turns.isEmpty || isStreaming)
                modelMenu
                Button {
                    Task { await loadSelectedModel() }
                } label: {
                    Label(loadButtonTitle, systemImage: loadButtonSystemImage)
                }
                .disabled(loadButtonDisabled)
                .help(loadButtonHelp)
            }

            Divider().background(Theme.Colors.border)

            if turns.isEmpty {
                emptyChat
            } else {
                sessionMetadataBar
                Divider().background(Theme.Colors.border.opacity(0.72))
                chatWorkspace
            }

            Divider().background(Theme.Colors.border)
            inputBar
        }
        .tint(Theme.Colors.accent)
        .background(Theme.ProNoirBackground())
        .accessibilityIdentifier("MLX Studio Chat Workspace")
        .task {
            await refreshModels()
            loadSessions(selecting: app.selectedStudioChatSessionID)
            consumePendingPromptHandoff()
            consumeStudioChatCommand()
        }
        .onChange(of: app.selectedModelPath) { _, _ in
            Task { await refreshModels() }
        }
        .onChange(of: app.selectedStudioChatSessionID) { _, sessionID in
            loadSessions(selecting: sessionID, defaultToFirst: sessionID != nil)
        }
        .onChange(of: app.pendingStudioChatPrompt) { _, _ in
            consumePendingPromptHandoff()
        }
        .onChange(of: app.studioChatCommandNonce) { _, _ in
            consumeStudioChatCommand()
        }
        .onDisappear {
            streamTask?.cancel()
            persistCurrentSession()
        }
    }

    private var sessionMenu: some View {
        Menu {
            Button {
                newSession()
            } label: {
                Label(L10n.Studio.newChat.render(AppLocalePreference.current), systemImage: "plus.bubble")
            }
            .disabled(isStreaming)

            if !sessions.isEmpty {
                Divider()
                ForEach(sessions) { session in
                    Button {
                        selectSession(session.id)
                    } label: {
                        Label(
                            session.title,
                            systemImage: session.id == activeSessionID
                                ? "checkmark.circle.fill"
                                : (session.isPinned ? "pin.fill" : "bubble.left.and.bubble.right")
                        )
                    }
                    .disabled(isStreaming)
                }
            }
        } label: {
            Label(sessionMenuTitle, systemImage: "bubble.left.and.bubble.right")
        }
        .menuStyle(.button)
    }

    private var sessionMetadataBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            metadataChip(
                draftSessionTitle,
                systemImage: activeSession?.isPinned == true ? "pin.fill" : "text.bubble"
            )
            metadataChip(
                activeReplyModelName ?? "No model selected",
                systemImage: "cpu"
            )
            if let mismatch = sessionModelMismatch {
                metadataChip("Saved as \(mismatch.recorded)", systemImage: "clock.arrow.circlepath")
            }
            metadataChip("\(turns.count) turns", systemImage: "number")
            if let activeSession {
                metadataChip("Updated \(Self.relativeFormatter.localizedString(for: activeSession.updatedAt, relativeTo: Date()))", systemImage: "clock")
            }
            Spacer(minLength: Theme.Spacing.md)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.sm)
        .background(Theme.Colors.surface.opacity(0.46))
    }

    private var chatWorkspace: some View {
        HStack(spacing: 0) {
            transcriptView
            Divider().background(Theme.Colors.border.opacity(0.72))
            activeSessionPanel
                .frame(width: 304)
        }
    }

    private var transcriptView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    conversationRunway

                    HStack {
                        Label(L10n.Studio.transcript.render(AppLocalePreference.current), systemImage: "bubble.left.and.bubble.right")
                            .font(Theme.Typography.captionHi)
                            .foregroundStyle(Theme.Colors.textLow)
                        Spacer()
                        Text(L10n.Studio.turnsCountFormat.render(AppLocalePreference.current, turns.count))
                            .font(Theme.Typography.monoCaption)
                            .foregroundStyle(Theme.Colors.textLow)
                    }

                    ForEach(turns) { turn in
                        ChatTurnBubble(
                            turn: turn,
                            regenerateDisabledReason: regenerateDisabledReason(for: turn),
                            copy: { copyTurn(turn) },
                            regenerate: { regenerate(from: turn) }
                        )
                        .id(turn.id)
                    }

                    sessionTrail
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: 980, alignment: .top)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .onChange(of: turns.count) { _, _ in
                if let last = turns.last?.id {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }

    private var conversationRunway: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Label(L10n.Studio.conversationRunway.render(AppLocalePreference.current), systemImage: "sparkles")
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.accent)
                    Text(draftSessionTitle)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(2)
                    Text(runwaySubtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMid)
                        .lineLimit(2)
                }
                Spacer(minLength: Theme.Spacing.md)
                VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
                    Label(sessionHealthText, systemImage: failedTurnCount > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(failedTurnCount > 0 ? Theme.Colors.danger : Theme.Colors.success)
                    Text(activeSession.map { "Updated \(Self.relativeFormatter.localizedString(for: $0.updatedAt, relativeTo: Date()))" } ?? "Unsaved draft")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                }
            }

            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                runwayMetric(
                    "Model readiness",
                    modelReadinessText,
                    systemImage: selectedModel?.isLoaded == true ? "bolt.fill" : "cpu",
                    tint: selectedModel?.isLoaded == true ? Theme.Colors.success : Theme.Colors.accent
                )
                runwayMetric(
                    "Session memory",
                    activeSession?.isPinned == true ? "Pinned in Library" : "Saved to Library",
                    systemImage: activeSession?.isPinned == true ? "pin.fill" : "books.vertical",
                    tint: activeSession?.isPinned == true ? Theme.Colors.warning : Theme.Colors.textMid
                )
                runwayMetric(
                    "Next action",
                    failedTurnCount > 0 ? "Explain or retry" : "Continue, summarize, or branch",
                    systemImage: failedTurnCount > 0 ? "arrow.clockwise.circle" : "arrow.turn.down.right",
                    tint: failedTurnCount > 0 ? Theme.Colors.danger : Theme.Colors.creative
                )
            }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text(L10n.Studio.followUpPrompts.render(AppLocalePreference.current))
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textLow)
                HStack(spacing: Theme.Spacing.sm) {
                    if failedTurnCount > 0 {
                        runwayPromptButton("Explain failure", "Explain why the last response failed and suggest the shortest fix.")
                    } else {
                        runwayPromptButton("Branch idea", "Explore a different approach without losing the current thread.")
                    }
                    runwayPromptButton("Continue answer", "Continue from the last useful point, keeping the answer concise.")
                    runwayPromptButton("Summarize decisions", "Summarize this session into decisions, open questions, and next actions.")
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ProNoirPanelBackground(active: failedTurnCount > 0))
    }

    private var sessionTrail: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .center, spacing: Theme.Spacing.sm) {
                Label(L10n.Studio.sessionTrail.render(AppLocalePreference.current), systemImage: "point.3.connected.trianglepath.dotted")
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                Spacer(minLength: Theme.Spacing.sm)
                Text(sessionHealthText)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(failedTurnCount > 0 ? Theme.Colors.danger : Theme.Colors.success)
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 198), spacing: Theme.Spacing.sm)],
                spacing: Theme.Spacing.sm
            ) {
                trailCard(
                    "Prompt",
                    value: lastUserPrompt ?? "No prompt yet",
                    caption: "Last user turn",
                    systemImage: "text.quote",
                    tint: Theme.Colors.accent
                )
                trailCard(
                    "Latest response",
                    value: lastAssistantResponse ?? "No response yet",
                    caption: failedTurnCount > 0 ? "Needs attention" : "Ready to continue",
                    systemImage: failedTurnCount > 0 ? "exclamationmark.triangle" : "sparkles",
                    tint: failedTurnCount > 0 ? Theme.Colors.danger : Theme.Colors.success
                )
                trailCard(
                    "Next move",
                    value: failedTurnCount > 0 ? "Explain failure" : "Continue answer",
                    caption: "Prepared in composer",
                    systemImage: failedTurnCount > 0 ? "arrow.clockwise.circle" : "arrow.turn.down.right",
                    tint: failedTurnCount > 0 ? Theme.Colors.danger : Theme.Colors.creative,
                    action: {
                        prompt = failedTurnCount > 0
                            ? "Explain why the last response failed and suggest the shortest fix."
                            : "Continue from the last useful point, keeping the answer concise."
                    }
                )
            }
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surface.opacity(0.42))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border.opacity(0.72), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    @ViewBuilder
    private func trailCard(
        _ title: String,
        value: String,
        caption: String,
        systemImage: String,
        tint: Color,
        action: (() -> Void)? = nil
    ) -> some View {
        let content = HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                Text(value)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Text(caption)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .background(tint.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

        if let action {
            Button(action: action) {
                content
            }
            .buttonStyle(.plain)
        } else {
            content
        }
    }

    private var runwaySubtitle: String {
        if let mismatch = sessionModelMismatch {
            return "Saved with \(mismatch.recorded) - next replies use \(mismatch.selected)."
        }
        let model = activeReplyModelName ?? "No model selected"
        return "\(model) - prompts, responses, failures, and next moves stay attached to this session."
    }

    private var modelReadinessText: String {
        if let selectedModel {
            return selectedModel.isLoaded ? "Loaded in memory" : "Ready to load"
        }
        return activeSession?.modelName ?? "Select a model"
    }

    private var sessionHealthText: String {
        failedTurnCount > 0 ? "\(failedTurnCount) failed turn\(failedTurnCount == 1 ? "" : "s")" : "Clean session"
    }

    private var handoffStateText: String {
        if activeSession?.hasSummaryExport == true {
            return activeSummaryExportExists ? "Summary saved" : "Summary missing"
        }
        return failedTurnCount > 0 ? "Explain failure next" : "Ready to save"
    }

    private var handoffStateIcon: String {
        if activeSession?.hasSummaryExport == true {
            return activeSummaryExportExists ? "doc.text.fill" : "doc.badge.exclamationmark"
        }
        return failedTurnCount > 0 ? "arrow.clockwise.circle" : "square.and.arrow.down"
    }

    private var handoffStateTint: Color {
        if activeSession?.hasSummaryExport == true {
            return activeSummaryExportExists ? Theme.Colors.success : Theme.Colors.warning
        }
        return failedTurnCount > 0 ? Theme.Colors.danger : Theme.Colors.creative
    }

    private var activeSummaryExportExists: Bool {
        activeSession?.summaryExportFileExists == true
    }

    private func runwayMetric(
        _ title: String,
        _ value: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(title, systemImage: systemImage)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
                .lineLimit(1)
            Text(value)
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textHigh)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .topLeading)
        .background(tint.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func runwayPromptButton(_ title: String, _ text: String) -> some View {
        Button {
            prompt = text
        } label: {
            Label(title, systemImage: "arrow.turn.down.right")
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textMid)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background(Theme.Colors.surfaceHi.opacity(0.46))
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Prompt starter \(title)")
        .accessibilityLabel(title)
        .accessibilityHint(text)
    }

    private var activeSessionPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Label(L10n.Studio.sessionContext.render(AppLocalePreference.current), systemImage: activeSession?.isPinned == true ? "pin.fill" : "sidebar.trailing")
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.accent)
                    Text(draftSessionTitle)
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(2)
                }
                .padding(Theme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.ProNoirPanelBackground(active: activeSession?.isPinned == true))

                sessionBriefPanel

                sessionStatGrid

                if let prompt = lastUserPrompt {
                    sessionSnippet(
                        title: "Last prompt",
                        value: prompt,
                        systemImage: "text.quote"
                    )
                }

                if let response = lastAssistantResponse {
                    sessionSnippet(
                        title: "Latest response",
                        value: response,
                        systemImage: failedTurnCount > 0 ? "exclamationmark.triangle" : "sparkles"
                    )
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Text(L10n.Studio.nextMove.render(AppLocalePreference.current))
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.textLow)
                    if failedTurnCount > 0 {
                        quickPromptButton("Explain failure", "Explain why the last response failed and suggest the shortest fix.")
                    } else {
                        quickPromptButton("Make practical", "Turn the last answer into concrete next steps with tradeoffs.")
                    }
                    quickPromptButton("Continue", "Continue from the last useful point, keeping the answer concise.")
                    quickPromptButton("Summarize", "Summarize this session into decisions, open questions, and next actions.")
                }
            }
            .padding(Theme.Spacing.md)
        }
        .background(Theme.Colors.surface.opacity(0.64))
    }

    private var sessionBriefPanel: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label(L10n.Studio.sessionBrief.render(AppLocalePreference.current), systemImage: "doc.text")
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textMid)

            VStack(spacing: Theme.Spacing.xs) {
                sessionBriefRow(
                    "Purpose",
                    lastUserPrompt == nil ? "Start a local chat" : "Answer the saved prompt",
                    systemImage: "target",
                    tint: Theme.Colors.accent
                )
                sessionBriefRow(
                    "Memory",
                    activeSession?.isPinned == true ? "Pinned in Library" : "Saved in Library",
                    systemImage: activeSession?.isPinned == true ? "pin.fill" : "books.vertical",
                    tint: activeSession?.isPinned == true ? Theme.Colors.warning : Theme.Colors.success
                )
                if let mismatch = sessionModelMismatch {
                    sessionBriefRow(
                        "Reply model",
                        mismatch.selected,
                        systemImage: "cpu",
                        tint: Theme.Colors.warning
                    )
                }
                sessionBriefRow(
                    "Handoff ready",
                    handoffStateText,
                    systemImage: handoffStateIcon,
                    tint: handoffStateTint
                )
            }
        }
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.surfaceHi.opacity(0.42))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border.opacity(0.72), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func sessionBriefRow(_ title: String, _ value: String, systemImage: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .lineLimit(1)
                Text(value)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private var sessionStatGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: Theme.Spacing.sm), GridItem(.flexible(), spacing: Theme.Spacing.sm)],
            spacing: Theme.Spacing.sm
        ) {
            sessionStatTile(
                title: sessionModelMismatch == nil ? "Model" : "Reply model",
                value: activeReplyModelName ?? "No model",
                systemImage: "cpu",
                tint: Theme.Colors.accent
            )
            if let mismatch = sessionModelMismatch {
                sessionStatTile(
                    title: "Saved model",
                    value: mismatch.recorded,
                    systemImage: "clock.arrow.circlepath",
                    tint: Theme.Colors.warning
                )
            }
            sessionStatTile(
                title: "Turns",
                value: "\(turns.count)",
                systemImage: "number",
                tint: Theme.Colors.textMid
            )
            sessionStatTile(
                title: "State",
                value: failedTurnCount > 0 ? "\(failedTurnCount) failed" : "Clean",
                systemImage: failedTurnCount > 0 ? "exclamationmark.triangle" : "checkmark.circle",
                tint: failedTurnCount > 0 ? Theme.Colors.danger : Theme.Colors.success
            )
            sessionStatTile(
                title: "Updated",
                value: activeSession.map { Self.relativeFormatter.localizedString(for: $0.updatedAt, relativeTo: Date()) } ?? "Now",
                systemImage: "clock",
                tint: Theme.Colors.textMid
            )
        }
    }

    private func sessionStatTile(
        title: String,
        value: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(title, systemImage: systemImage)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
                .lineLimit(1)
            Text(value)
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textHigh)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .background(Theme.Colors.surfaceHi.opacity(0.54))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
                .padding(Theme.Spacing.sm)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func sessionSnippet(title: String, value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Label(title, systemImage: systemImage)
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textLow)
            Text(value)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textMid)
                .lineLimit(5)
                .textSelection(.enabled)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surfaceHi.opacity(0.46))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func quickPromptButton(_ title: String, _ text: String) -> some View {
        Button {
            prompt = text
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "arrow.turn.down.right")
                    .foregroundStyle(Theme.Colors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                    Text(text)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Colors.surfaceHi.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Session quick prompt \(title)")
        .accessibilityLabel(title)
        .accessibilityHint(text)
    }

    private var failedTurnCount: Int {
        turns.filter { $0.streamState == .failed }.count
    }

    private var lastUserPrompt: String? {
        turns.reversed()
            .first { $0.role == .user && !StudioChatText.cleanForDisplay($0.content).isEmpty }
            .map { StudioChatText.cleanForDisplay($0.content) }
    }

    private var lastAssistantResponse: String? {
        turns.reversed()
            .first { $0.role == .assistant && !StudioChatText.cleanForDisplay($0.content).isEmpty }
            .map { StudioChatText.cleanForDisplay($0.content) }
    }

    private func metadataChip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textMid)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Theme.Colors.surfaceHi.opacity(0.72))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private func normalizedModelName(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var modelMenu: some View {
        Button {
            isModelPickerPresented.toggle()
        } label: {
            Label(selectedModel?.ref.displayName ?? "Select Chat Model", systemImage: "cpu")
        }
        .buttonStyle(.bordered)
        .popover(isPresented: $isModelPickerPresented, arrowEdge: .bottom) {
            modelPickerPopover
        }
        .accessibilityLabel(L10n.Studio.chatModelPicker.render(AppLocalePreference.current))
        .accessibilityValue(selectedModel?.ref.displayName ?? "No model selected")
        .accessibilityIdentifier("Chat Model Picker")
    }

    private var modelPickerPopover: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(L10n.Studio.chatModel.render(AppLocalePreference.current))
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textMid)

            if chatCapableModels.isEmpty {
                Label(L10n.Studio.noChatCapableModels.render(AppLocalePreference.current), systemImage: "exclamationmark.triangle")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
            } else {
                ScrollView {
                    VStack(spacing: Theme.Spacing.xs) {
                        ForEach(chatCapableModels) { model in
                            Button {
                                selectChatModel(model)
                                isModelPickerPresented = false
                            } label: {
                                HStack(spacing: Theme.Spacing.sm) {
                                    Image(systemName: selectedModelID == model.id ? "checkmark.circle.fill" : "cpu")
                                        .foregroundStyle(selectedModelID == model.id ? Theme.Colors.success : Theme.Colors.accent)
                                        .frame(width: 18)
                                    Text(model.ref.displayName)
                                        .font(Theme.Typography.captionHi)
                                        .foregroundStyle(Theme.Colors.textHigh)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, Theme.Spacing.sm)
                                .padding(.vertical, 7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    selectedModelID == model.id
                                        ? Theme.Colors.accent.opacity(0.14)
                                        : Theme.Colors.surfaceHi.opacity(0.42)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(chatModelSelectionAccessibilityTitle(for: model))
                            .accessibilityIdentifier(chatModelSelectionAccessibilityTitle(for: model))
                        }
                    }
                }
                .frame(maxHeight: 240)
            }
        }
        .padding(Theme.Spacing.md)
        .frame(width: 320)
        .background(Theme.Colors.surface)
    }

    private func chatModelSelectionAccessibilityTitle(for model: ModelSummary) -> String {
        "Chat Select Model \(model.ref.displayName)"
    }

    private func selectChatModel(_ model: ModelSummary) {
        rememberPreSessionModelSelection(beforeSelecting: model)
        selectedModelID = model.id
        app.selectedModelPath = model.ref.localURL
        guard let activeSessionID, !turns.isEmpty else { return }
        StudioChatHistoryStore.updateSessionModelName(activeSessionID, modelName: model.ref.displayName)
        loadSessions(selecting: activeSessionID)
        status = "Session model set: \(model.ref.displayName)"
    }

    private var emptyChat: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        DeAlignMascotMark()
                            .frame(width: 62, height: 62)
                            .foregroundStyle(Theme.Colors.accent)
                        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                            Text(emptyChatTitle)
                                .font(Theme.Typography.display)
                                .foregroundStyle(Theme.Colors.textHigh)
                            Text(emptyChatCaption)
                                .font(Theme.Typography.body)
                                .foregroundStyle(Theme.Colors.textMid)
                                .lineSpacing(3)
                                .frame(maxWidth: 480, alignment: .leading)
                        }
                    }
                    Spacer(minLength: Theme.Spacing.lg)
                    VStack(spacing: Theme.Spacing.md) {
                        studioStatusTile(
                            title: selectedModel?.ref.displayName ?? "No model selected",
                            subtitle: selectedModel?.isLoaded == true ? "Ready in memory" : (selectedModel == nil ? "Install or scan a model to begin" : "Select Load when you are ready"),
                            systemImage: selectedModel?.isLoaded == true ? "checkmark.circle.fill" : "cpu",
                            tint: selectedModel?.isLoaded == true ? Theme.Colors.success : Theme.Colors.accent
                        )
                        studioStatusTile(
                            title: "\(chatCapableModels.count) chat model\(chatCapableModels.count == 1 ? "" : "s")",
                            subtitle: sessions.isEmpty ? "No saved chats yet" : "\(sessions.count) saved chat session\(sessions.count == 1 ? "" : "s")",
                            systemImage: "internaldrive",
                            tint: Theme.Colors.textMid
                        )
                    }
                    .frame(width: 280)
                }

                if chatCapableModels.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text(L10n.Studio.chooseStarterModel.render(AppLocalePreference.current))
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.Colors.textHigh)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Theme.Spacing.md)], spacing: Theme.Spacing.md) {
                            ForEach(recommended.prefix(3)) { model in
                                starterModelButton(model)
                            }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text(L10n.Studio.tryFirstPrompt.render(AppLocalePreference.current))
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.Colors.textHigh)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Theme.Spacing.md)], spacing: Theme.Spacing.md) {
                            suggestionButton("Summarize this model", "What are you good at? Answer with practical examples.")
                            suggestionButton("Draft a plan", "Help me turn an idea into a short implementation plan.")
                            suggestionButton("Stress test", "Give me a concise reasoning test with the answer hidden until I ask.")
                        }
                    }
                }

                if !sessions.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        Text(L10n.Studio.recentSessions.render(AppLocalePreference.current))
                            .font(Theme.Typography.title)
                            .foregroundStyle(Theme.Colors.textHigh)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: Theme.Spacing.md)], spacing: Theme.Spacing.md) {
                            ForEach(sessions.prefix(3)) { session in
                                recentSessionButton(session)
                            }
                        }
                    }
                }
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 980, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func studioStatusTile(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.Typography.bodyHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.Spacing.md)
        .background(Theme.ProNoirPanelBackground())
    }

    private func suggestionButton(_ title: String, _ text: String) -> some View {
        Button {
            prompt = text
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label(title, systemImage: "sparkle")
                    .font(Theme.Typography.bodyHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                Text(text)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .padding(Theme.Spacing.md)
            .background(Theme.ProNoirPanelBackground())
        }
        .buttonStyle(.plain)
    }

    private func starterModelButton(_ model: RecommendedModel) -> some View {
        Button {
            download(model)
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack {
                    Label(model.ref.displayName, systemImage: "arrow.down.circle")
                        .font(Theme.Typography.bodyHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(1)
                    Spacer()
                    Text(model.sizeHint)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                }
                Text(model.summary)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(2)
                Text(starterInstallState?.label ?? "Download and open Chat")
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(starterInstallState?.phase == .failed ? Theme.Colors.danger : Theme.Colors.accent)
            }
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .padding(Theme.Spacing.md)
            .background(Theme.ProNoirPanelBackground(active: starterInstallState?.isActive == true))
        }
        .buttonStyle(.plain)
        .disabled(starterInstallState?.isActive == true)
    }

    private func recentSessionButton(_ session: StudioChatSession) -> some View {
        Button {
            selectSession(session.id)
        } label: {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label(session.title, systemImage: session.isPinned ? "pin.fill" : "text.bubble")
                    .font(Theme.Typography.bodyHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(1)
                Text(session.preview)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(2)
                Text(L10n.Studio.turnsCountFormat.render(AppLocalePreference.current, session.turnCount))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
            }
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .padding(Theme.Spacing.md)
            .background(Theme.ProNoirPanelBackground())
        }
        .buttonStyle(.plain)
    }

    private var inputBar: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if !turns.isEmpty {
                composerPromptDock
            }

            HStack(alignment: .bottom, spacing: Theme.Spacing.md) {
                TextField("Message", text: $prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...5)
                    .font(Theme.Typography.body)
                    .accessibilityIdentifier("Chat composer")
                    .accessibilityLabel(L10n.Studio.chatComposer.render(AppLocalePreference.current))
                    .padding(Theme.Spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.lg)
                            .fill(Theme.Colors.surface.opacity(0.86))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                                    .stroke(Theme.Colors.border, lineWidth: 1)
                            )
                    )
                    .onSubmit { send() }

                Button {
                    isStreaming ? stop() : send()
                } label: {
                    Label(isStreaming ? "Stop" : "Send", systemImage: isStreaming ? "stop.fill" : "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isStreaming && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Theme.Spacing.lg)
    }

    private var composerPromptDock: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Label(L10n.Studio.keepMoving.render(AppLocalePreference.current), systemImage: "arrow.turn.up.right")
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                Text(draftSessionTitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .lineLimit(1)
            }
            .frame(width: 132, alignment: .topLeading)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(composerSuggestions) { suggestion in
                        composerSuggestionButton(suggestion)
                    }
                }
                .padding(.trailing, 2)
            }
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surfaceHi.opacity(0.42))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.md)
                .stroke(Theme.Colors.border.opacity(0.72), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private var composerSuggestions: [ComposerSuggestion] {
        var suggestions = [
            ComposerSuggestion(
                id: "practical",
                title: "Make practical",
                caption: "Turn into steps",
                prompt: "Turn the last answer into concrete next steps with tradeoffs.",
                systemImage: "checklist",
                tint: Theme.Colors.success
            ),
            ComposerSuggestion(
                id: "risk",
                title: "Find risk",
                caption: "Assumptions and gaps",
                prompt: "Point out the hidden assumptions, failure modes, and missing evidence.",
                systemImage: "exclamationmark.triangle",
                tint: Theme.Colors.warning
            ),
            ComposerSuggestion(
                id: "branch",
                title: "Branch idea",
                caption: "Try another angle",
                prompt: "Explore a different approach without losing the current thread.",
                systemImage: "arrow.triangle.branch",
                tint: Theme.Colors.creative
            ),
            ComposerSuggestion(
                id: "summary",
                title: "Save summary",
                caption: "Write handoff file",
                prompt: "Summarize this session into decisions, open questions, and next actions.",
                systemImage: "doc.plaintext",
                tint: Theme.Colors.accent
            )
        ]
        if failedTurnCount > 0 {
            suggestions.insert(
                ComposerSuggestion(
                    id: "failure",
                    title: "Explain failure",
                    caption: "Diagnose and retry",
                    prompt: "Explain why the last response failed and suggest the shortest fix.",
                    systemImage: "arrow.clockwise.circle",
                    tint: Theme.Colors.danger
                ),
                at: 0
            )
        }
        return suggestions
    }

    private func composerSuggestionButton(_ suggestion: ComposerSuggestion) -> some View {
        Button {
            if suggestion.id == "summary" {
                saveSessionSummary()
            } else {
                prompt = suggestion.prompt
            }
        } label: {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: suggestion.systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(suggestion.tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.title)
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(1)
                    Text(suggestion.caption)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .frame(width: 176, alignment: .topLeading)
            .frame(minHeight: 54, alignment: .topLeading)
            .background(suggestion.tint.opacity(0.10))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .stroke(suggestion.tint.opacity(0.22), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("Keep moving \(suggestion.title)")
        .accessibilityLabel(suggestion.title)
        .accessibilityHint(suggestion.caption)
    }

    private func saveSessionSummary() {
        persistCurrentSession()
        guard let session = activeSession else {
            status = "No saved session to summarize"
            return
        }
        do {
            let exportedAt = Date()
            let url = try StudioChatSessionExporter.writeSummary(for: session, exportedAt: exportedAt)
            recordSummaryExport(url, exportedAt: exportedAt)
            status = "Saved summary: \(url.lastPathComponent)"
            #if canImport(AppKit)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
            #endif
        } catch {
            status = "Summary save failed"
            StudioDiagnosticIssueStore.record(
                source: .diagnostics,
                title: "Chat summary save failed",
                message: error.localizedDescription,
                context: session.title
            )
        }
    }

    private func recordSummaryExport(_ url: URL, exportedAt: Date) {
        guard let id = activeSessionID,
              let index = sessions.firstIndex(where: { $0.id == id })
        else { return }
        sessions[index].summaryExportPath = url.path
        sessions[index].summaryExportedAt = exportedAt
        sessions = StudioChatHistoryStore.sorted(sessions)
        activeSessionID = id
        app.selectedStudioChatSessionID = id
        StudioChatHistoryStore.saveSelectedSessionID(id)
        StudioChatHistoryStore.saveSessions(sessions)
    }

    private func loadSessions(selecting requestedID: UUID?, defaultToFirst: Bool = true) {
        let loaded = StudioChatHistoryStore.loadSessions()
        sessions = loaded
        let persistedID = StudioChatHistoryStore.loadSelectedSessionID()
        let selectedSession = [requestedID, persistedID, activeSessionID]
            .compactMap { $0 }
            .compactMap { id in loaded.first(where: { $0.id == id }) }
            .first ?? (defaultToFirst ? loaded.first : nil)
        activeSessionID = selectedSession?.id
        if selectedSession != nil {
            draftHandoffTitle = nil
        }
        turns = selectedSession?.turns ?? []
        applySavedModelSelection(for: selectedSession)
        if app.selectedStudioChatSessionID != selectedSession?.id {
            app.selectedStudioChatSessionID = selectedSession?.id
        }
        StudioChatHistoryStore.saveSelectedSessionID(selectedSession?.id)
    }

    private func selectSession(_ id: UUID) {
        guard !isStreaming else { return }
        persistCurrentSession()
        guard let session = sessions.first(where: { $0.id == id }) else { return }
        activeSessionID = session.id
        draftHandoffTitle = nil
        app.selectedStudioChatSessionID = session.id
        StudioChatHistoryStore.saveSelectedSessionID(session.id)
        turns = session.turns
        applySavedModelSelection(for: session)
        status = "Opened \(session.title)"
    }

    private func toggleActiveSessionPinned() {
        guard !isStreaming else { return }
        if activeSessionID == nil, !turns.isEmpty {
            persistCurrentSession()
        }
        guard let id = activeSessionID,
              let index = sessions.firstIndex(where: { $0.id == id })
        else { return }
        sessions[index].isPinned.toggle()
        let pinned = sessions[index].isPinned
        sessions = StudioChatHistoryStore.sorted(sessions)
        app.selectedStudioChatSessionID = id
        StudioChatHistoryStore.saveSelectedSessionID(id)
        StudioChatHistoryStore.saveSessions(sessions)
        status = pinned ? "Pinned chat session" : "Unpinned chat session"
    }

    private func newSession() {
        if isStreaming { stop() }
        persistCurrentSession()
        rememberActiveSessionForReopen()
        activeSessionID = nil
        draftHandoffTitle = nil
        turns = []
        prompt = ""
        status = "Draft chat"
        StudioChatHistoryStore.saveSelectedSessionID(nil)
        app.selectedStudioChatSessionID = nil
        restorePreSessionModelSelection()
    }

    private func rememberActiveSessionForReopen() {
        guard let activeSessionID,
              sessions.contains(where: { $0.id == activeSessionID })
        else { return }
        app.lastClosedStudioChatSessionID = activeSessionID
    }

    private func reopenLastClosedSession() {
        guard !isStreaming else {
            status = "Stop generation before reopening a chat"
            return
        }
        persistCurrentSession()
        let loaded = StudioChatHistoryStore.loadSessions()
        sessions = loaded
        let targetID = app.lastClosedStudioChatSessionID.flatMap { closedID in
            loaded.first(where: { $0.id == closedID })?.id
        } ?? loaded.first?.id
        guard let targetID,
              let session = loaded.first(where: { $0.id == targetID })
        else {
            status = "No closed chat to reopen"
            return
        }
        activeSessionID = session.id
        draftHandoffTitle = nil
        turns = session.turns
        applySavedModelSelection(for: session)
        app.selectedStudioChatSessionID = session.id
        StudioChatHistoryStore.saveSelectedSessionID(session.id)
        status = "Reopened \(session.title)"
    }

    private func applySavedModelSelection(for session: StudioChatSession?) {
        guard let session,
              let model = StudioChatModelSelection.chatModel(matching: session.modelName, in: localModels)
        else { return }
        rememberPreSessionModelSelection(beforeSelecting: model)
        selectedModelID = model.id
        if app.selectedModelPath != model.ref.localURL {
            app.selectedModelPath = model.ref.localURL
        }
    }

    private func rememberPreSessionModelSelection(beforeSelecting model: ModelSummary) {
        guard activeSessionID != nil,
              preSessionModelPath == nil,
              let currentPath = app.selectedModelPath,
              currentPath != model.ref.localURL,
              chatCapableModels.contains(where: { $0.ref.localURL == currentPath })
        else { return }
        preSessionModelPath = currentPath
    }

    private func restorePreSessionModelSelection() {
        defer { preSessionModelPath = nil }
        guard let previousPath = preSessionModelPath,
              let previousModel = chatCapableModels.first(where: { $0.ref.localURL == previousPath })
        else { return }
        selectedModelID = previousModel.id
        if app.selectedModelPath != previousModel.ref.localURL {
            app.selectedModelPath = previousModel.ref.localURL
        }
        if let previousURL = previousModel.ref.localURL {
            app.selectedServerSessionId = app.sessionId(forModelPath: previousURL)
            app.rebindEngineObserver()
        }
    }

    private func consumeStudioChatCommand() {
        guard let command = app.studioChatCommand else { return }
        app.studioChatCommand = nil
        switch command {
        case .newSession:
            newSession()
        case .reopenLastClosed:
            reopenLastClosedSession()
        }
    }

    private func consumePendingPromptHandoff() {
        guard !isStreaming, let handoff = app.pendingStudioChatPrompt else { return }
        persistCurrentSession()
        rememberActiveSessionForReopen()
        activeSessionID = nil
        draftHandoffTitle = handoff.title
        turns = []
        prompt = handoff.prompt
        status = handoff.status
        StudioChatHistoryStore.saveSelectedSessionID(nil)
        app.selectedStudioChatSessionID = nil
        restorePreSessionModelSelection()
        app.pendingStudioChatPrompt = nil
    }

    private func refreshModels() async {
        let modelService = StudioModelService(app: app)
        do {
            localModels = try await modelService.listLocalModels()
            recommended = try await modelService.listRecommendedModels()
            if let activeSession {
                applySavedModelSelection(for: activeSession)
            } else {
                selectedModelID = StudioChatModelSelection.selectedModelID(
                    currentID: selectedModelID,
                    selectedPath: app.selectedModelPath,
                    models: localModels
                )
                if app.selectedModelPath == nil,
                   let selected = chatCapableModels.first(where: { $0.id == selectedModelID }),
                   let localURL = selected.ref.localURL {
                    app.selectedModelPath = localURL
                }
            }
        } catch {
            status = error.localizedDescription
            StudioDiagnosticIssueStore.record(
                source: .chatLoad,
                title: "Model refresh failed",
                message: error.localizedDescription,
                context: "Chat"
            )
        }
    }

    private func loadSelectedModel() async {
        guard let selectedModel else { return }
        isLoadingModel = true
        status = "Loading \(selectedModel.ref.displayName)"
        do {
            try await StudioChatService(app: app).loadModel(selectedModel.ref)
            status = "Ready: \(selectedModel.ref.displayName)"
        } catch {
            status = error.localizedDescription
            StudioDiagnosticIssueStore.record(
                source: .chatLoad,
                title: "Model load failed",
                message: error.localizedDescription,
                context: selectedModel.ref.displayName
            )
        }
        isLoadingModel = false
        await refreshModels()
    }

    private func send() {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        guard selectedModel != nil else {
            status = "Select a local model"
            return
        }
        prompt = ""
        let userTurn = ChatTurn(role: .user, content: text)
        let assistant = ChatTurn(role: .assistant, content: "", streamState: .streaming)
        let shouldTitleSession = turns.isEmpty
        let titleSeed = shouldTitleSession ? (draftHandoffTitle ?? text) : nil
        draftHandoffTitle = nil
        turns.append(userTurn)
        turns.append(assistant)
        persistCurrentSession(
            titleSeed: titleSeed,
            modelNameOverride: selectedReplyModelName
        )
        streamAssistantResponse(assistantID: assistant.id)
    }

    private func streamAssistantResponse(assistantID: UUID) {
        guard let selectedModel else {
            status = "Select a local model"
            return
        }
        isStreaming = true
        streamingAssistantID = assistantID
        status = "Streaming"
        streamTask = Task {
            do {
                if !selectedModel.isLoaded {
                    await loadSelectedModel()
                }
                let request = StudioChatRequest(
                    model: selectedModel.ref,
                    messages: turns.filter { !$0.content.isEmpty || $0.role != .assistant },
                    enableThinking: app.experienceMode == .advanced
                )
                let stream = try await StudioChatService(app: app).streamMessage(request)
                for try await event in stream {
                    switch event {
                    case .token(let token), .reasoning(let token):
                        await MainActor.run {
                            append(token, to: assistantID)
                        }
                    case .usage:
                        break
                    case .finished:
                        break
                    }
                }
                await MainActor.run {
                    setTurnState(.complete, for: assistantID)
                    status = "Ready"
                    isStreaming = false
                    streamingAssistantID = nil
                    persistCurrentSession()
                }
            } catch {
                await MainActor.run {
                    if Task.isCancelled || error is CancellationError {
                        if turns.first(where: { $0.id == assistantID })?.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                            append("Stopped before completion.", to: assistantID)
                        }
                        setTurnState(.cancelled, for: assistantID)
                        status = "Stopped"
                    } else {
                        append("\n\n\(error.localizedDescription)", to: assistantID)
                        setTurnState(.failed, for: assistantID)
                        status = error.localizedDescription
                        StudioDiagnosticIssueStore.record(
                            source: .chatStream,
                            title: "Chat stream failed",
                            message: error.localizedDescription,
                            context: selectedModel.ref.displayName
                        )
                    }
                    isStreaming = false
                    streamingAssistantID = nil
                    persistCurrentSession()
                }
            }
        }
    }

    private func stop() {
        let assistantID = streamingAssistantID
        streamTask?.cancel()
        Task {
            await StudioChatService(app: app).stopGeneration()
            await MainActor.run {
                if let assistantID {
                    if turns.first(where: { $0.id == assistantID })?.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                        append("Stopped before completion.", to: assistantID)
                    }
                    setTurnState(.cancelled, for: assistantID)
                }
                isStreaming = false
                streamingAssistantID = nil
                status = "Stopped"
                persistCurrentSession()
            }
        }
    }

    private func copyTurn(_ turn: ChatTurn) {
        let text = StudioChatText.cleanForDisplay(turn.content)
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
        status = "Copied \(turn.role == .user ? "prompt" : "response")"
    }

    private func regenerate(from turn: ChatTurn) {
        if let disabledReason = regenerateDisabledReason(for: turn) {
            status = disabledReason
            return
        }
        guard let retryDraft = StudioChatRecovery.retryDraft(from: turn.id, in: turns) else {
            status = "No user prompt to retry"
            return
        }
        turns = retryDraft.retainedTurns + [retryDraft.assistant]
        persistCurrentSession(modelNameOverride: selectedReplyModelName)
        appendRetryDraftAutomationLog()
        streamAssistantResponse(assistantID: retryDraft.assistant.id)
    }

    private func regenerateDisabledReason(for turn: ChatTurn) -> String? {
        StudioChatRegenerateAvailability.disabledReason(
            hasSelectedModel: selectedModel != nil,
            isStreaming: isStreaming,
            turnID: turn.id,
            turns: turns
        )
    }

    private func append(_ token: String, to id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].content = StudioChatText.clean(turns[index].content + token)
    }

    private func setTurnState(_ state: ChatTurn.StreamState, for id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].streamState = state
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private func persistCurrentSession(
        titleSeed: String? = nil,
        modelNameOverride: String? = nil
    ) {
        guard !turns.isEmpty else {
            StudioChatHistoryStore.saveSessions(sessions.filter { !$0.turns.isEmpty })
            return
        }
        let now = Date()
        let sessionID = activeSessionID ?? UUID()
        let cleanedTurns = turns.map { turn in
            var cleaned = turn
            cleaned.content = StudioChatText.clean(cleaned.content)
            return cleaned
        }
        let prior = sessions.first { $0.id == sessionID }
        let seededTitle = titleSeed.map(StudioChatHistoryStore.title)
        let resolvedTitle = seededTitle
            ?? (prior?.title == "New Chat" ? nil : prior?.title)
            ?? StudioChatHistoryStore.title(from: cleanedTurns)
        let resolvedModelName = normalizedModelName(modelNameOverride)
            ?? normalizedModelName(prior?.modelName)
            ?? selectedReplyModelName
        let turnsChanged = prior?.turns != cleanedTurns
        let resolvedUpdatedAt = turnsChanged ? now : prior?.updatedAt ?? now
        let modelChanged = prior.map { normalizedModelName($0.modelName) != resolvedModelName } ?? false
        let resolvedSummaryExportPath = turnsChanged || modelChanged ? nil : prior?.summaryExportPath
        let resolvedSummaryExportedAt = turnsChanged || modelChanged ? nil : prior?.summaryExportedAt
        let updated = StudioChatSession(
            id: sessionID,
            title: resolvedTitle,
            modelName: resolvedModelName,
            turns: cleanedTurns,
            createdAt: prior?.createdAt ?? cleanedTurns.first?.createdAt ?? now,
            updatedAt: resolvedUpdatedAt,
            isPinned: prior?.isPinned ?? false,
            summaryExportPath: resolvedSummaryExportPath,
            summaryExportedAt: resolvedSummaryExportedAt
        )
        if let index = sessions.firstIndex(where: { $0.id == sessionID }) {
            sessions[index] = updated
        } else {
            sessions.insert(updated, at: 0)
        }
        sessions = StudioChatHistoryStore.sorted(sessions)
        activeSessionID = sessionID
        app.selectedStudioChatSessionID = sessionID
        StudioChatHistoryStore.saveSelectedSessionID(sessionID)
        StudioChatHistoryStore.saveSessions(sessions)
    }

    private func appendRetryDraftAutomationLog() {
        guard let logURL = chatRetryDraftLogURL() else { return }
        try? FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if !FileManager.default.fileExists(atPath: logURL.path) {
            _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let failedCount = turns.filter { $0.streamState == .failed }.count
        let streamingCount = turns.filter { $0.streamState == .streaming }.count
        let lastState = turns.last?.streamState.rawValue ?? "none"
        let sessionID = activeSessionID?.uuidString ?? "none"
        let line = "\(sessionID)|turns=\(turns.count)|failed=\(failedCount)|streaming=\(streamingCount)|last=\(lastState)\n"
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        handle.closeFile()
    }

    private func chatRetryDraftLogURL() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["MLX_STUDIO_CHAT_RETRY_DRAFT_LOG"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func download(_ model: RecommendedModel) {
        Task {
            do {
                guard let repo = model.ref.repo else { throw StudioServiceError.modelNotLocal }
                let request = ModelInstallRequest(
                    repo: repo,
                    displayName: model.ref.displayName,
                    source: .recommended,
                    openChatWhenReady: true
                )
                let stream = StudioModelInstallService(app: app).install(request)
                for try await event in stream {
                    let viewState = ModelInstallViewState.from(event)
                    starterInstallState = viewState
                    status = viewState.label
                    switch event {
                    case .installed, .ready:
                        await refreshModels()
                    default:
                        break
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
                StudioDiagnosticIssueStore.record(
                    source: .modelInstall,
                    title: "Starter model install failed",
                    message: error.localizedDescription,
                    context: model.ref.displayName
                )
            }
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
            try await StudioChatService(app: app).loadModel(model.ref)
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

struct StudioLibraryScreen: View {
    private enum LibraryFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case chats = "Chats"
        case images = "Images"
        case models = "Models"
        case pinned = "Pinned"

        var id: String { rawValue }
    }

    @Environment(AppState.self) private var app
    @State private var models: [ModelSummary] = []
    @State private var chatSessions: [StudioChatSession] = []
    @State private var imageRecords: [ImageGenerationRecord] = []
    @State private var selectedFilter: LibraryFilter = .all
    @State private var searchText = ""
    @State private var pendingDeleteChatSession: StudioChatSession?
    @State private var pendingDeleteImageRecord: ImageGenerationRecord?

    private var normalizedQuery: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isLibrarySearching: Bool {
        !normalizedQuery.isEmpty
    }

    private var libraryImageRecords: [ImageGenerationRecord] {
        imageRecords.filter { record in
            record.outputPath != nil || record.status != .pending
        }
    }

    private var librarySubtitle: String {
        let imageCount = libraryMetricImageRecords.count
        let chatCount = libraryMetricChatSessions.count
        let modelCount = libraryMetricModels.count
        let pinnedCount = libraryMetricPinnedSessions.count
        return [
            libraryCountText(imageCount, singular: "image"),
            libraryCountText(chatCount, singular: "chat"),
            libraryCountText(modelCount, singular: "model"),
            isLibrarySearching ? "\(pinnedCount) pinned match\(pinnedCount == 1 ? "" : "es")" : "\(pinnedCount) pinned",
        ].joined(separator: " - ")
    }

    private var provenanceCount: Int {
        provenanceCount(in: libraryImageRecords)
    }

    private var visibleProvenanceCount: Int {
        provenanceCount(in: visibleImageRecords)
    }

    private var libraryMetricProvenanceCount: Int {
        provenanceCount(in: libraryMetricImageRecords)
    }

    private var visibleImageRecords: [ImageGenerationRecord] {
        libraryImageRecords.filter { record in
            matchesSearch(imageSearchFields(for: record))
        }
    }

    private var visibleChatSessions: [StudioChatSession] {
        chatSessions.filter { session in
            guard selectedFilter != .pinned || session.isPinned else { return false }
            let status = StudioChatSessionStatus.summary(
                for: session,
                summaryExportExists: session.summaryExportFileExists
            )
            // Built imperatively rather than as one large concatenated
            // literal: the Swift type-checker times out on an expression
            // this size mixing ternaries, joins, and flatMap. Appending
            // is trivially typed.
            var tokens: [String] = []
            tokens.append(session.title)
            tokens.append(session.modelName ?? "")
            tokens.append(session.preview)
            tokens.append(session.turns.map(\.content).joined(separator: " "))
            tokens.append(session.isPinned ? "pinned favorite" : "")
            tokens.append(contentsOf: status.searchTokens)
            tokens.append(contentsOf: Self.searchDateFields(for: session.createdAt))
            tokens.append(contentsOf: Self.searchDateFields(for: session.updatedAt))
            tokens.append(contentsOf: session.turns.flatMap { Self.searchDateFields(for: $0.createdAt) })
            return matchesSearch(tokens)
        }
    }

    private var visibleModels: [ModelSummary] {
        models.filter { model in
            matchesSearch(StudioLibraryModelSearch.summary(for: model).searchTokens)
        }
    }

    private var libraryMetricImageRecords: [ImageGenerationRecord] {
        isLibrarySearching ? visibleImageRecords : libraryImageRecords
    }

    private var libraryMetricChatSessions: [StudioChatSession] {
        isLibrarySearching ? visibleChatSessions : chatSessions
    }

    private var libraryMetricModels: [ModelSummary] {
        isLibrarySearching ? visibleModels : models
    }

    private var libraryMetricPinnedSessions: [StudioChatSession] {
        isLibrarySearching ? visibleChatSessions.filter(\.isPinned) : chatSessions.filter(\.isPinned)
    }

    private var latestImageRecord: ImageGenerationRecord? {
        visibleImageRecords.max { $0.createdAt < $1.createdAt }
    }

    private func imageOutputExists(_ record: ImageGenerationRecord?) -> Bool {
        guard let outputPath = record?.outputPath else { return false }
        return FileManager.default.fileExists(atPath: outputPath)
    }

    private var resumeChatSession: StudioChatSession? {
        visibleChatSessions
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    private var spotlightModel: ModelSummary? {
        StudioLibraryModelArchive.spotlightModel(
            in: visibleModels,
            selectedModelPath: app.selectedModelPath
        )
    }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                StudioToolbar(title: "Library", subtitle: librarySubtitle) {
                    Picker("", selection: $selectedFilter) {
                        ForEach(LibraryFilter.allCases) { filter in
                            Text(filter.rawValue).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 350)

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Theme.Colors.textLow)
                        TextField("Search Library", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(Theme.Typography.caption)
                            .accessibilityLabel(L10n.Studio.searchLibrary.render(AppLocalePreference.current))
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.Colors.textLow)
                        }
                    }
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, 7)
                    .frame(width: 240)
                    .background(Theme.Colors.surfaceHi)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))

                    Button {
                        Task { await reloadLibrary() }
                    } label: {
                        Label(L10n.Studio.refresh.render(AppLocalePreference.current), systemImage: "arrow.clockwise")
                    }
                }
                Divider().background(Theme.Colors.border)
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                        if selectedFilter == .all {
                            libraryMemoryBoard
                            libraryOverview
                        } else {
                            filteredLibraryHeader
                        }

                        if shouldShow(.images) {
                            if selectedFilter == .images {
                                imageReuseLane
                            }
                            section("Generated Images")
                            ImageLibraryView(records: visibleImageRecords) { record in
                                pendingDeleteChatSession = nil
                                pendingDeleteImageRecord = record
                            } onReuse: { record, settings in
                                reuseImageRecord(record, settings: settings)
                            }
                        }

                        if shouldShow(.chats) {
                            section("Chat History")
                            if visibleChatSessions.isEmpty {
                                EmptyStateView(
                                    systemImage: "text.bubble",
                                    title: searchText.isEmpty ? "No chat history" : "No matching chat sessions",
                                    caption: "Conversations will appear here as sessions you can reopen.",
                                    cta: nil
                                )
                                .frame(minHeight: 180)
                            } else {
                                LazyVGrid(
                                    columns: [GridItem(.adaptive(minimum: 280), spacing: Theme.Spacing.md)],
                                    spacing: Theme.Spacing.md
                                ) {
                                    ForEach(visibleChatSessions) { session in
                                        StudioChatSessionCard(
                                            session: session,
                                            open: { openChatSession(session) },
                                            rename: { renameChatSession(session) },
                                            togglePinned: { togglePinnedChatSession(session) },
                                            exportMarkdown: { exportChatSession(session, as: .markdown) },
                                            exportJSON: { exportChatSession(session, as: .json) },
                                            delete: {
                                                pendingDeleteImageRecord = nil
                                                pendingDeleteChatSession = session
                                            }
                                        )
                                    }
                                }
                            }
                        }

                        if shouldShow(.models) {
                            section("Downloaded Models")
                            if visibleModels.isEmpty {
                                EmptyStateView(
                                    systemImage: "externaldrive",
                                    title: searchText.isEmpty ? "No downloaded models" : "No matching models",
                                    caption: "Downloaded chat and image models will appear here.",
                                    cta: nil
                                )
                                .frame(minHeight: 180)
                            } else {
                                VStack(spacing: Theme.Spacing.sm) {
                                    ForEach(visibleModels) { model in
                                        StudioLibraryModelCard(
                                            model: model,
                                            open: { openModelArchive(model) },
                                            reveal: { revealModel(model) },
                                            copyPath: { copyModelPath(model) },
                                            exportReport: { exportModelReport(model) }
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(Theme.Spacing.xl)
                }
            }

            if let pendingDeleteChatSession {
                chatDeleteConfirmationPanel(for: pendingDeleteChatSession)
            }

            if let pendingDeleteImageRecord {
                imageDeleteConfirmationPanel(for: pendingDeleteImageRecord)
            }
        }
        .background(Theme.ProNoirBackground())
        .task { await reloadLibrary() }
    }

    private func imageDeleteConfirmationPanel(for record: ImageGenerationRecord) -> some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
                .onTapGesture {
                    pendingDeleteImageRecord = nil
                }

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Label(L10n.Studio.deleteImageArtifactQ.render(AppLocalePreference.current), systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.danger)

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Remove \"\(record.prompt)\" from Library. This deletes the saved image record, output file if present, and metadata sidecar.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textMid)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.Studio.modelsChatsNotDeleted.render(AppLocalePreference.current))
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.warning)
                }

                HStack(spacing: Theme.Spacing.sm) {
                    Spacer()
                    Button("Cancel") {
                        pendingDeleteImageRecord = nil
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(role: .destructive) {
                        pendingDeleteImageRecord = nil
                        deleteImageRecord(record)
                    } label: {
                        Label(L10n.Studio.deleteImage.render(AppLocalePreference.current), systemImage: "trash")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Colors.danger)
                    .accessibilityIdentifier(imageDeleteConfirmationButtonTitle(for: record))
                    .accessibilityLabel(imageDeleteConfirmationButtonTitle(for: record))
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

    private func imageDeleteConfirmationButtonTitle(for record: ImageGenerationRecord) -> String {
        "Confirm delete image \(record.prompt)"
    }

    private func chatDeleteConfirmationPanel(for session: StudioChatSession) -> some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
                .onTapGesture {
                    pendingDeleteChatSession = nil
                }

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                Label(L10n.Studio.deleteChatSessionQ.render(AppLocalePreference.current), systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.Typography.title)
                    .foregroundStyle(Theme.Colors.danger)

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Remove \"\(session.title)\" from Library. This deletes the saved prompts, responses, model name, and turn state for this chat.")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textMid)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L10n.Studio.modelFilesNotDeleted.render(AppLocalePreference.current))
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.warning)
                }

                HStack(spacing: Theme.Spacing.sm) {
                    Spacer()
                    Button("Cancel") {
                        pendingDeleteChatSession = nil
                    }
                    .keyboardShortcut(.cancelAction)

                    Button(role: .destructive) {
                        pendingDeleteChatSession = nil
                        deleteChatSession(session)
                    } label: {
                        Label(L10n.Studio.deleteChat.render(AppLocalePreference.current), systemImage: "trash")
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.Colors.danger)
                    .accessibilityIdentifier(chatDeleteConfirmationButtonTitle(for: session))
                    .accessibilityLabel(chatDeleteConfirmationButtonTitle(for: session))
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
        }
    }

    private func chatDeleteConfirmationButtonTitle(for session: StudioChatSession) -> String {
        "Confirm delete chat \(session.title)"
    }

    private func section(_ title: String) -> some View {
        Text(title)
            .font(Theme.Typography.title)
            .foregroundStyle(Theme.Colors.textHigh)
    }

    private var filteredLibraryHeader: some View {
        let copy = filterHeaderCopy
        return HStack(alignment: .center, spacing: Theme.Spacing.lg) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .fill(copy.tint.opacity(0.12))
                Image(systemName: copy.systemImage)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(copy.tint)
            }
            .frame(width: 64, height: 64)
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.lg)
                    .stroke(copy.tint.opacity(0.34), lineWidth: 1)
            )

            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Label(copy.label, systemImage: "line.3.horizontal.decrease.circle")
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(copy.tint)
                Text(copy.title)
                    .font(.system(size: 24, weight: .semibold, design: .default))
                    .foregroundStyle(Theme.Colors.textHigh)
                Text(copy.caption)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(2)
            }

            Spacer(minLength: Theme.Spacing.md)

            HStack(spacing: Theme.Spacing.sm) {
                filterMetric(copy.primaryValue, copy.primaryLabel, systemImage: copy.primaryIcon)
                filterMetric(copy.secondaryValue, copy.secondaryLabel, systemImage: copy.secondaryIcon)
            }
            .frame(width: 280)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 116, alignment: .leading)
        .background(Theme.ProNoirPanelBackground(active: true))
    }

    private var filterHeaderCopy: (
        label: String,
        title: String,
        caption: String,
        systemImage: String,
        tint: Color,
        primaryValue: String,
        primaryLabel: String,
        primaryIcon: String,
        secondaryValue: String,
        secondaryLabel: String,
        secondaryIcon: String
    ) {
        switch selectedFilter {
        case .images:
            return (
                "Images memory",
                "Visual outputs",
                "\(visibleImageRecords.count) generated image\(visibleImageRecords.count == 1 ? "" : "s") with prompt, model, settings, and file provenance ready to reuse.",
                "photo.on.rectangle.angled",
                Theme.Colors.creative,
                "\(visibleImageRecords.count)",
                "images",
                "photo",
                "\(visibleProvenanceCount)",
                "with provenance",
                "doc.badge.gearshape"
            )
        case .chats:
            return (
                "Conversation archive",
                "Chat sessions",
                "\(visibleChatSessions.count) saved session\(visibleChatSessions.count == 1 ? "" : "s") with prompts, responses, model names, and resume actions.",
                "text.bubble",
                Theme.Colors.accent,
                "\(visibleChatSessions.count)",
                "sessions",
                "bubble.left.and.bubble.right",
                "\(visibleChatSessions.filter(\.isPinned).count)",
                "pinned",
                "pin.fill"
            )
        case .models:
            return (
                "Model archive",
                "Downloaded models",
                "\(visibleModels.count) local model\(visibleModels.count == 1 ? "" : "s") with paths, modality, loaded state, and reveal actions.",
                "externaldrive",
                Theme.Colors.success,
                "\(visibleModels.count)",
                "models",
                "cpu",
                "\(visibleModels.filter(\.isLoaded).count)",
                "loaded",
                "bolt.fill"
            )
        case .pinned:
            return (
                "Pinned work",
                "Pinned sessions",
                "\(visibleChatSessions.count) pinned conversation\(visibleChatSessions.count == 1 ? "" : "s") kept close for quick return.",
                "pin.fill",
                Theme.Colors.warning,
                "\(visibleChatSessions.count)",
                "pinned",
                "pin.fill",
                "\(visibleChatSessions.reduce(0) { $0 + $1.turnCount })",
                "turns",
                "number"
            )
        case .all:
            return (
                "Studio memory",
                "Recent work",
                "Searchable studio memory for images, chats, models, and pinned sessions.",
                "sparkles",
                Theme.Colors.creative,
                "\(libraryMetricImageRecords.count)",
                "images",
                "photo",
                "\(libraryMetricChatSessions.count)",
                "chats",
                "text.bubble"
            )
        }
    }

    private func filterMetric(_ value: String, _ label: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(label, systemImage: systemImage)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .default))
                .foregroundStyle(Theme.Colors.textHigh)
                .lineLimit(1)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(Theme.Colors.surfaceHi.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private var imageReuseLane: some View {
        let record = latestImageRecord
        let settings = record.flatMap { decodeImageSettings($0) }
        let fileExists = imageOutputExists(record)

        return HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Label(L10n.Studio.reuseLane.render(AppLocalePreference.current), systemImage: "arrow.triangle.2.circlepath")
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.creative)
                Text(record?.prompt ?? "Create an image and its reusable prompt will appear here.")
                    .font(Theme.Typography.bodyHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .lineLimit(2)
                Text(record.map { "\($0.modelAlias) - \(imageSettingsSummary($0))" } ?? "Prompt, model, seed, and output file stay attached.")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .lineLimit(2)
            }

            Spacer(minLength: Theme.Spacing.md)

            HStack(spacing: Theme.Spacing.sm) {
                imageReuseFact(
                    "Prompt",
                    record == nil ? "Empty" : "Captured",
                    systemImage: "text.quote",
                    tint: Theme.Colors.accent
                )
                imageReuseFact(
                    "Settings",
                    settings == nil ? "Metadata" : "Reusable",
                    systemImage: "slider.horizontal.3",
                    tint: Theme.Colors.success
                )
                imageReuseFact(
                    "File",
                    imageMemoryFileStateText(record, fileExists: fileExists),
                    systemImage: "doc.badge.gearshape",
                    tint: imageMemoryFileStateTint(record, fileExists: fileExists)
                )
            }
            .frame(width: 330)

            VStack(spacing: Theme.Spacing.sm) {
                Button {
                    if let record, let settings {
                        reuseImageRecord(record, settings: settings)
                    }
                } label: {
                    Label(L10n.Studio.reuseLatestPrompt.render(AppLocalePreference.current), systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(record == nil || settings == nil)
                .accessibilityIdentifier(imageReuseLaneActionTitle("Reuse latest prompt", record: record))
                .accessibilityLabel(imageReuseLaneActionTitle("Reuse latest prompt", record: record))

                Button {
                    if let record, let settings {
                        reuseImageRecord(record, settings: settings)
                    } else {
                        app.mode = .create
                    }
                } label: {
                    Label(L10n.Studio.openCanvas.render(AppLocalePreference.current), systemImage: "wand.and.stars")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(imageReuseLaneActionTitle("Open canvas", record: record))
                .accessibilityLabel(imageReuseLaneActionTitle("Open canvas", record: record))
            }
            .frame(width: 174)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .background(Theme.ProNoirPanelBackground(active: record != nil))
    }

    private func imageReuseLaneActionTitle(_ action: String, record: ImageGenerationRecord?) -> String {
        guard let record else { return action }
        return "\(action) \(record.prompt)"
    }

    private func imageReuseFact(
        _ title: String,
        _ value: String,
        systemImage: String,
        tint: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: systemImage)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
                .lineLimit(1)
            Text(value)
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textHigh)
                .lineLimit(1)
        }
        .padding(Theme.Spacing.sm)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(tint.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                .stroke(tint.opacity(0.24), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
    }

    private func imageMemoryFileStateText(
        _ record: ImageGenerationRecord?,
        fileExists: Bool,
        includeFilename: Bool = false
    ) -> String {
        guard let record else { return "Waiting" }
        if fileExists {
            if includeFilename, let outputPath = record.outputPath {
                return URL(fileURLWithPath: outputPath).lastPathComponent
            }
            return "On disk"
        }
        if record.outputPath != nil { return "Missing" }
        switch record.status {
        case .pending: return "Pending"
        case .completed: return "Missing"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    private func imageMemoryFileStateSystemImage(
        _ record: ImageGenerationRecord?,
        fileExists: Bool
    ) -> String {
        guard let record else { return "doc.badge.gearshape" }
        if fileExists { return "doc" }
        switch record.status {
        case .pending: return "hourglass"
        case .completed: return "doc.badge.exclamationmark"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "xmark.circle"
        }
    }

    private func imageMemoryFileStateTint(
        _ record: ImageGenerationRecord?,
        fileExists: Bool
    ) -> Color {
        guard let record else { return Theme.Colors.creative }
        if fileExists { return Theme.Colors.creative }
        if record.outputPath != nil { return Theme.Colors.warning }
        switch record.status {
        case .pending, .completed: return Theme.Colors.warning
        case .failed: return Theme.Colors.danger
        case .cancelled: return Theme.Colors.textLow
        }
    }

    private var libraryMemoryBoard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Label(L10n.Studio.studioMemory.render(AppLocalePreference.current), systemImage: "sparkles")
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.creative)
                    Text(L10n.Studio.recentWork.render(AppLocalePreference.current))
                        .font(Theme.Typography.title)
                        .foregroundStyle(Theme.Colors.textHigh)
                }
                Spacer()
                Text(L10n.Studio.studioMemoryA11y.render(AppLocalePreference.current))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                    .lineLimit(1)
            }

            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                latestImageMemoryCard
                    .frame(minWidth: 420, maxWidth: .infinity, alignment: .topLeading)

                VStack(spacing: Theme.Spacing.md) {
                    resumeSessionMemoryCard
                    modelArchiveMemoryCard
                }
                .frame(width: 340)
            }
        }
    }

    private var latestImageMemoryCard: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            libraryImagePreview(latestImageRecord)
                .frame(width: 292, height: 236)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                if let record = latestImageRecord {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Label(L10n.Studio.imageProvenance.render(AppLocalePreference.current), systemImage: "sparkles")
                            .font(Theme.Typography.captionHi)
                            .foregroundStyle(Theme.Colors.creative)
                        Text(L10n.Studio.latestImage.render(AppLocalePreference.current))
                            .font(.system(size: 24, weight: .semibold, design: .default))
                            .foregroundStyle(Theme.Colors.textHigh)
                        Text(record.prompt)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.textMid)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(spacing: Theme.Spacing.sm) {
                        HStack(spacing: Theme.Spacing.sm) {
                            memoryFact("Model", record.modelAlias, systemImage: "wand.and.stars", tint: Theme.Colors.creative)
                            memoryFact("Saved", Self.relativeFormatter.localizedString(for: record.createdAt, relativeTo: Date()), systemImage: "clock", tint: Theme.Colors.textMid)
                        }
                        HStack(spacing: Theme.Spacing.sm) {
                            memoryFact("Settings", imageSettingsSummary(record), systemImage: "slider.horizontal.3", tint: Theme.Colors.accent)
                            memoryFact(
                                "File",
                                imageMemoryFileStateText(
                                    record,
                                    fileExists: imageOutputExists(record),
                                    includeFilename: true
                                ),
                                systemImage: imageMemoryFileStateSystemImage(
                                    record,
                                    fileExists: imageOutputExists(record)
                                ),
                                tint: imageMemoryFileStateTint(
                                    record,
                                    fileExists: imageOutputExists(record)
                                )
                            )
                        }
                    }

                    HStack(spacing: Theme.Spacing.sm) {
                        Button {
                            if let settings = decodeImageSettings(record) {
                                reuseImageRecord(record, settings: settings)
                            }
                        } label: {
                            Label(L10n.Studio.reuseLatest.render(AppLocalePreference.current), systemImage: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(decodeImageSettings(record) == nil)
                        .accessibilityIdentifier(imageReuseLaneActionTitle("Reuse latest image", record: record))
                        .accessibilityLabel(imageReuseLaneActionTitle("Reuse latest image", record: record))

                        Button {
                            if let settings = decodeImageSettings(record) {
                                reuseImageRecord(record, settings: settings)
                            } else {
                                app.mode = .create
                            }
                        } label: {
                            Label(L10n.Studio.openCreate.render(AppLocalePreference.current), systemImage: "wand.and.stars")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier(imageReuseLaneActionTitle("Open latest image in Create", record: record))
                        .accessibilityLabel(imageReuseLaneActionTitle("Open latest image in Create", record: record))
                    }
                } else {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Label(L10n.Studio.imageProvenance.render(AppLocalePreference.current), systemImage: "sparkles")
                            .font(Theme.Typography.captionHi)
                            .foregroundStyle(Theme.Colors.creative)
                        Text(L10n.Studio.latestImage.render(AppLocalePreference.current))
                            .font(.system(size: 24, weight: .semibold, design: .default))
                            .foregroundStyle(Theme.Colors.textHigh)
                        Text(L10n.Studio.createFirstVisualHint.render(AppLocalePreference.current))
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.textMid)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button {
                        app.mode = .create
                    } label: {
                        Label(L10n.Studio.openCreate.render(AppLocalePreference.current), systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 328, alignment: .topLeading)
        .background(Theme.ProNoirPanelBackground(active: latestImageRecord != nil))
    }

    private var resumeSessionMemoryCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: resumeChatSession?.isPinned == true ? "pin.fill" : "text.bubble")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(resumeChatSession?.isPinned == true ? Theme.Colors.warning : Theme.Colors.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.Studio.resumeSession.render(AppLocalePreference.current))
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.textLow)
                    Text(resumeChatSession?.title ?? emptyChatMemoryTitle)
                        .font(Theme.Typography.bodyHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(1)
                    Text(resumeChatSession?.preview ?? emptyChatMemoryCaption)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMid)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: Theme.Spacing.sm) {
                if let session = resumeChatSession {
                    memoryMiniStat("\(session.turnCount)", "turns")
                    memoryMiniStat(session.modelName ?? "Model", "model")
                    memoryMiniStat(Self.relativeFormatter.localizedString(for: session.updatedAt, relativeTo: Date()), "updated")
                } else {
                    memoryMiniStat("0", isLibrarySearching ? "matches" : "sessions")
                    memoryMiniStat(isLibrarySearching ? "Try another" : "Ready", isLibrarySearching ? "search" : "when you chat")
                }
            }

            Button {
                if let session = resumeChatSession {
                    openChatSession(session)
                } else if isLibrarySearching {
                    searchText = ""
                } else {
                    app.mode = .chat
                }
            } label: {
                Label(resumeSessionActionTitle, systemImage: resumeSessionActionIcon)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(resumeSessionActionAccessibilityTitle)
            .accessibilityLabel(resumeSessionActionAccessibilityTitle)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .background(Theme.ProNoirPanelBackground(active: resumeChatSession != nil))
    }

    private var resumeSessionActionTitle: String {
        if resumeChatSession != nil { return "Open Latest Chat" }
        if isLibrarySearching { return "Clear Search" }
        return "Open Chat"
    }

    private var resumeSessionActionAccessibilityTitle: String {
        if let session = resumeChatSession { return "Open latest chat \(session.title)" }
        return resumeSessionActionTitle
    }

    private var resumeSessionActionIcon: String {
        isLibrarySearching && resumeChatSession == nil ? "xmark.circle" : "arrow.up.right"
    }

    private var emptyChatMemoryTitle: String {
        isLibrarySearching ? "No matching chats" : "No saved chats yet"
    }

    private var emptyChatMemoryCaption: String {
        isLibrarySearching
            ? "No chat sessions match the current Library search."
            : "Chat sessions will appear here as reusable work."
    }

    private var emptyModelMemoryTitle: String {
        isLibrarySearching ? "No matching models" : "No local models"
    }

    private var emptyModelMemoryCaption: String {
        isLibrarySearching
            ? "No local model records match the current Library search."
            : "Downloads and local folders will collect here."
    }

    private var modelArchiveMemoryCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                Image(systemName: "externaldrive")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.Colors.success)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.Studio.modelArchive.render(AppLocalePreference.current))
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.textLow)
                    Text(spotlightModel?.ref.displayName ?? emptyModelMemoryTitle)
                        .font(Theme.Typography.bodyHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(spotlightModel.map { "\($0.family) - \($0.modality) - \(formattedBytes($0.sizeBytes))" } ?? emptyModelMemoryCaption)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textMid)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: Theme.Spacing.sm) {
                memoryMiniStat("\(libraryMetricModels.count)", isLibrarySearching ? "matches" : "models")
                memoryMiniStat("\(libraryMetricModels.filter(\.isLoaded).count)", "loaded")
                memoryMiniStat("\(libraryMetricModels.filter { $0.modality.localizedCaseInsensitiveContains("image") }.count)", "image")
            }

            Button {
                if let localURL = spotlightModel?.ref.localURL {
                    app.selectedModelPath = localURL
                }
                app.mode = .models
            } label: {
                Label(L10n.Studio.browseModels.render(AppLocalePreference.current), systemImage: "arrow.up.right")
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(modelArchiveActionTitle)
            .accessibilityLabel(modelArchiveActionTitle)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 156, alignment: .topLeading)
        .background(Theme.ProNoirPanelBackground(active: spotlightModel != nil))
    }

    private var modelArchiveActionTitle: String {
        if let model = spotlightModel { return "Browse model archive \(model.ref.displayName)" }
        return "Browse Models"
    }

    private func memoryFact(_ title: String, _ value: String, systemImage: String, tint: Color) -> some View {
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

    private func memoryMiniStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textHigh)
                .lineLimit(1)
            Text(label)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textLow)
                .lineLimit(1)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.Colors.surfaceHi.opacity(0.46))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    @ViewBuilder
    private func libraryImagePreview(_ record: ImageGenerationRecord?) -> some View {
        #if canImport(AppKit)
        if let outputPath = record?.outputPath,
           let image = NSImage(contentsOf: URL(fileURLWithPath: outputPath)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .background(Theme.Colors.surfaceHi)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .stroke(Theme.Colors.borderHi, lineWidth: 1)
                )
        } else {
            libraryImagePlaceholder
        }
        #else
        libraryImagePlaceholder
        #endif
    }

    private var libraryImagePlaceholder: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 30, weight: .semibold))
            Text(L10n.Studio.noImageYet.render(AppLocalePreference.current))
                .font(Theme.Typography.captionHi)
        }
        .foregroundStyle(Theme.Colors.textLow)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Colors.surfaceHi.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    private func shouldShow(_ filter: LibraryFilter) -> Bool {
        if selectedFilter == .pinned {
            return filter == .chats
        }
        return selectedFilter == .all || selectedFilter == filter
    }

    private var imageOverviewCaption: String {
        if isLibrarySearching {
            return libraryMetricProvenanceCount == 0
                ? "Matching outputs keep prompt and settings"
                : "\(libraryMetricProvenanceCount) matching with exported provenance"
        }
        return provenanceCount == 0
            ? "Outputs keep prompt and settings"
            : "\(provenanceCount) with exported provenance"
    }

    private var chatOverviewCaption: String {
        if isLibrarySearching {
            return libraryMetricChatSessions.isEmpty
                ? "No matching sessions"
                : "\(libraryMetricPinnedSessions.count) matching pinned"
        }
        return chatSessions.isEmpty
            ? "Conversations save as reusable sessions"
            : "\(chatSessions.filter(\.isPinned).count) pinned for quick return"
    }

    private var modelOverviewCaption: String {
        if isLibrarySearching {
            return libraryMetricModels.isEmpty
                ? "No matching model records"
                : "\(libraryMetricModels.filter(\.isLoaded).count) matching loaded"
        }
        return "Paths, reports, and reveal actions"
    }

    private var pinnedOverviewCaption: String {
        isLibrarySearching ? "Pinned sessions matching search" : "Pinned sessions stay easy to reopen"
    }

    private var libraryOverview: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 220), spacing: Theme.Spacing.md)],
            spacing: Theme.Spacing.md
        ) {
            libraryTile(
                title: "Generated images",
                value: "\(libraryMetricImageRecords.count)",
                caption: imageOverviewCaption,
                systemImage: "photo.on.rectangle.angled",
                tint: Theme.Colors.creative,
                actionLabel: "Open Create",
                actionAccessibilityTitle: "Open generated images in Create",
                action: { app.mode = .create }
            )
            libraryTile(
                title: "Chat sessions",
                value: "\(libraryMetricChatSessions.count)",
                caption: chatOverviewCaption,
                systemImage: "text.bubble",
                tint: Theme.Colors.accent,
                actionLabel: "Open Chat",
                actionAccessibilityTitle: "Open chat sessions in Chat",
                action: { app.mode = .chat }
            )
            libraryTile(
                title: "Model archive",
                value: "\(libraryMetricModels.count)",
                caption: modelOverviewCaption,
                systemImage: "externaldrive",
                tint: Theme.Colors.success,
                actionLabel: "Show Archive",
                actionAccessibilityTitle: "Show Model archive",
                action: { selectedFilter = .models }
            )
            libraryTile(
                title: "Pinned work",
                value: "\(libraryMetricPinnedSessions.count)",
                caption: pinnedOverviewCaption,
                systemImage: "pin.fill",
                tint: Theme.Colors.warning,
                actionLabel: "Show Pinned",
                actionAccessibilityTitle: "Show Pinned work",
                action: { selectedFilter = .pinned }
            )
        }
    }

    private func libraryTile(
        title: String,
        value: String,
        caption: String,
        systemImage: String,
        tint: Color,
        actionLabel: String,
        actionAccessibilityTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
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

            Button(action: action) {
                Label(actionLabel, systemImage: "arrow.up.right")
                    .font(Theme.Typography.captionHi)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(actionAccessibilityTitle)
            .accessibilityLabel(actionAccessibilityTitle)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .topLeading)
        .background(Theme.ProNoirPanelBackground())
    }

    private func matchesSearch(_ fields: [String]) -> Bool {
        let query = normalizedQuery
        guard !query.isEmpty else { return true }
        return fields.contains { $0.lowercased().contains(query) }
    }

    private func imageSearchFields(for record: ImageGenerationRecord) -> [String] {
        let status = StudioImageRecordStatus.summary(
            for: record,
            fileExists: imageOutputExists(record)
        )
        return [
            record.prompt,
            record.modelAlias,
            record.settingsJSON,
            record.outputPath ?? "",
            record.status.rawValue,
            imageSettingsSummary(record),
        ] + status.searchTokens
            + Self.searchDateFields(for: record.createdAt)
    }

    private func libraryCountText(_ count: Int, singular: String) -> String {
        let noun = count == 1 ? singular : "\(singular)s"
        guard isLibrarySearching else { return "\(count) \(noun)" }
        return "\(count) \(singular) match\(count == 1 ? "" : "es")"
    }

    private func provenanceCount(in records: [ImageGenerationRecord]) -> Int {
        records.filter { record in
            guard let url = record.metadataSidecarURL else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }.count
    }

    private static func searchDateFields(for date: Date) -> [String] {
        [
            fullDateFormatter.string(from: date),
            dayDateFormatter.string(from: date),
            isoDayFormatter.string(from: date),
            isoMonthFormatter.string(from: date),
            yearFormatter.string(from: date),
        ]
    }

    private func decodeImageSettings(_ record: ImageGenerationRecord) -> ImageGenSettings? {
        try? JSONDecoder().decode(ImageGenSettings.self, from: Data(record.settingsJSON.utf8))
    }

    private func imageSettingsSummary(_ record: ImageGenerationRecord) -> String {
        guard let settings = decodeImageSettings(record) else { return "Settings saved" }
        let seed = settings.seed >= 0 ? "seed \(settings.seed)" : "random seed"
        return "\(settings.width)x\(settings.height) - \(settings.steps) steps - \(seed)"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private static let fullDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let dayDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let isoDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let isoMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"
        return formatter
    }()

    private static let yearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy"
        return formatter
    }()

    @MainActor
    private func reloadLibrary() async {
        models = (try? await StudioModelService(app: app).listLocalModels()) ?? []
        chatSessions = StudioChatHistoryStore.loadSessions()
        imageRecords = ImageHistoryStore.shared.all()
    }

    private func openChatSession(_ session: StudioChatSession) {
        app.selectedStudioChatSessionID = session.id
        StudioChatHistoryStore.saveSelectedSessionID(session.id)
        app.mode = .chat
    }

    private func renameChatSession(_ session: StudioChatSession) {
        #if canImport(AppKit)
        let alert = NSAlert()
        alert.messageText = "Rename Chat Session"
        alert.informativeText = "Give this conversation a name that will make sense later."
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: session.title)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityIdentifier("Rename chat title")
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        StudioChatHistoryStore.updateSessionTitle(session.id, title: field.stringValue)
        chatSessions = StudioChatHistoryStore.loadSessions()
        #endif
    }

    private func togglePinnedChatSession(_ session: StudioChatSession) {
        updateChatSession(session.id) { current in
            current.isPinned.toggle()
        }
    }

    private func deleteChatSession(_ session: StudioChatSession) {
        chatSessions.removeAll { $0.id == session.id }
        StudioChatHistoryStore.deleteSession(session.id)
        if app.lastClosedStudioChatSessionID == session.id {
            app.lastClosedStudioChatSessionID = nil
        }
        if app.selectedStudioChatSessionID == session.id {
            app.selectedStudioChatSessionID = chatSessions.first?.id
            StudioChatHistoryStore.saveSelectedSessionID(chatSessions.first?.id)
        }
    }

    private func exportChatSession(_ session: StudioChatSession, as format: StudioChatSessionExportFormat) {
        #if canImport(AppKit)
        if let directory = automatedChatExportDirectory() {
            do {
                let url = try StudioChatSessionExporter.write(
                    for: session,
                    format: format,
                    directory: directory
                )
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            } catch {
                StudioDiagnosticIssueStore.record(
                    source: .diagnostics,
                    title: "Chat export failed",
                    message: error.localizedDescription,
                    context: session.title
                )
            }
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = StudioChatSessionExporter.defaultFilename(
            for: session,
            format: format
        )
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try StudioChatSessionExporter.data(for: session, format: format)
            try data.write(to: url, options: .atomic)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        } catch {
            StudioDiagnosticIssueStore.record(
                source: .diagnostics,
                title: "Chat export failed",
                message: error.localizedDescription,
                context: session.title
            )
        }
        #endif
    }

    private func automatedChatExportDirectory() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["MLX_STUDIO_CHAT_EXPORT_DIR"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func reuseImageRecord(_ record: ImageGenerationRecord, settings: ImageGenSettings) {
        app.pendingStudioImageReuse = StudioImageReuseRequest(
            prompt: record.prompt,
            modelAlias: record.modelAlias,
            settings: settings
        )
        app.mode = .create
    }

    private func updateChatSession(
        _ id: UUID,
        mutate: (inout StudioChatSession) -> Void
    ) {
        guard let index = chatSessions.firstIndex(where: { $0.id == id }) else { return }
        mutate(&chatSessions[index])
        chatSessions = StudioChatHistoryStore.sorted(chatSessions)
        StudioChatHistoryStore.saveSessions(chatSessions)
    }

    private static func fileSafe(_ title: String) -> String {
        StudioChatSessionExporter.fileSafe(title)
    }

    private func deleteImageRecord(_ record: ImageGenerationRecord) {
        imageRecords.removeAll { $0.id == record.id }
        record.deleteOutputAndSidecar()
        _ = ImageHistoryStore.shared.delete(record.id)
    }

    private func revealModel(_ model: ModelSummary) {
        #if canImport(AppKit)
        guard let url = model.ref.localURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }

    private func openModelArchive(_ model: ModelSummary) {
        if let localURL = model.ref.localURL {
            app.selectedModelPath = localURL
        }
        app.mode = .models
    }

    private func copyModelPath(_ model: ModelSummary) {
        #if canImport(AppKit)
        guard let path = model.ref.localURL?.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        #endif
    }

    private func exportModelReport(_ model: ModelSummary) {
        #if canImport(AppKit)
        if let directory = automatedModelReportExportDirectory() {
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let url = directory.appendingPathComponent(modelReportFilename(for: model))
                try writeModelReport(for: model, to: url)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            } catch {
                StudioDiagnosticIssueStore.record(
                    source: .diagnostics,
                    title: "Model report export failed",
                    message: error.localizedDescription,
                    context: model.ref.displayName
                )
            }
            return
        }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = modelReportFilename(for: model)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try writeModelReport(for: model, to: url)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(url.path, forType: .string)
        } catch {
            StudioDiagnosticIssueStore.record(
                source: .diagnostics,
                title: "Model report export failed",
                message: error.localizedDescription,
                context: model.ref.displayName
            )
        }
        #endif
    }

    private func automatedModelReportExportDirectory() -> URL? {
        guard let path = ProcessInfo.processInfo.environment["MLX_STUDIO_MODEL_REPORT_EXPORT_DIR"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func modelReportFilename(for model: ModelSummary) -> String {
        "\(Self.fileSafe(model.ref.displayName))-model-report.json"
    }

    private func writeModelReport(for model: ModelSummary, to url: URL) throws {
        let report = LibraryModelReport(
            exportedAt: Date(),
            id: model.id,
            displayName: model.ref.displayName,
            repo: model.ref.repo,
            localPath: model.ref.localURL?.path,
            family: model.family,
            modality: model.modality,
            sizeBytes: model.sizeBytes,
            labels: model.labels,
            isLoaded: model.isLoaded,
            fileSummary: model.ref.localURL.map { Self.fileSummary(for: $0) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        try data.write(to: url, options: .atomic)
    }

    private struct LibraryModelReport: Codable {
        var exportedAt: Date
        var id: String
        var displayName: String
        var repo: String?
        var localPath: String?
        var family: String
        var modality: String
        var sizeBytes: Int64
        var labels: [String]
        var isLoaded: Bool
        var fileSummary: ModelFileSummary?
    }

    private struct ModelFileSummary: Codable {
        var fileCount: Int
        var directoryCount: Int
        var weightFileCount: Int
        var weightBytes: Int64
        var configPresent: Bool
        var tokenizerPresent: Bool
    }

    private static func fileSummary(for url: URL) -> ModelFileSummary {
        let fileManager = FileManager.default
        var fileCount = 0
        var directoryCount = 0
        var weightFileCount = 0
        var weightBytes: Int64 = 0

        if let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let item as URL in enumerator {
                let values = try? item.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
                if values?.isDirectory == true {
                    directoryCount += 1
                    continue
                }
                guard values?.isRegularFile == true else { continue }
                fileCount += 1
                let ext = item.pathExtension.lowercased()
                if ext == "safetensors" || ext == "bin" || ext == "gguf" {
                    weightFileCount += 1
                    weightBytes += Int64(values?.fileSize ?? 0)
                }
            }
        }

        return ModelFileSummary(
            fileCount: fileCount,
            directoryCount: directoryCount,
            weightFileCount: weightFileCount,
            weightBytes: weightBytes,
            configPresent: fileManager.fileExists(atPath: url.appendingPathComponent("config.json").path),
            tokenizerPresent: fileManager.fileExists(atPath: url.appendingPathComponent("tokenizer.json").path)
                || fileManager.fileExists(atPath: url.appendingPathComponent("tokenizer.model").path)
                || fileManager.fileExists(atPath: url.appendingPathComponent("vocab.json").path)
        )
    }
}

private struct StudioLibraryModelCard: View {
    var model: ModelSummary
    var open: () -> Void
    var reveal: () -> Void
    var copyPath: () -> Void
    var exportReport: () -> Void

    private var hasLocalPath: Bool { model.ref.localURL != nil }
    private var searchSummary: StudioLibraryModelSearch.Summary {
        StudioLibraryModelSearch.summary(for: model)
    }

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Spacing.md) {
            Image(systemName: model.modality.lowercased() == "image" ? "photo.stack" : "cpu")
                .foregroundStyle(model.isLoaded ? Theme.Colors.success : Theme.Colors.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(model.ref.displayName)
                        .font(Theme.Typography.bodyHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(1)
                        .textSelection(.enabled)
                    Label(
                        searchSummary.loadStateLabel,
                        systemImage: model.isLoaded ? "checkmark.circle.fill" : "circle.dashed"
                    )
                    .font(Theme.Typography.caption)
                    .foregroundStyle(model.isLoaded ? Theme.Colors.success : Theme.Colors.textMid)
                }
                Text("\(model.family) - \(model.modality) - \(formattedBytes(model.sizeBytes))")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                if let path = model.ref.localURL?.path {
                    Text(path)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            Spacer()
            HStack(spacing: Theme.Spacing.sm) {
                Button(action: open) {
                    Label(L10n.Studio.open.render(AppLocalePreference.current), systemImage: "arrow.up.right")
                }
                .buttonStyle(.bordered)
                .disabled(!hasLocalPath)
                .accessibilityIdentifier("Open model \(model.ref.displayName) in Models")
                .accessibilityLabel(L10n.Studio.a11yOpenModelInModels.render(AppLocalePreference.current, model.ref.displayName))
                Button(action: reveal) {
                    Label(L10n.Studio.reveal.render(AppLocalePreference.current), systemImage: "folder")
                }
                .buttonStyle(.plain)
                .disabled(!hasLocalPath)
                .accessibilityIdentifier("Reveal model \(model.ref.displayName)")
                .accessibilityLabel(L10n.Studio.a11yRevealModel.render(AppLocalePreference.current, model.ref.displayName))
                Button(action: copyPath) {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy model path")
                .disabled(!hasLocalPath)
                .accessibilityIdentifier("Copy model path \(model.ref.displayName)")
                .accessibilityLabel(L10n.Studio.a11yCopyModelPath.render(AppLocalePreference.current, model.ref.displayName))
                Button(action: exportReport) {
                    Label(L10n.Studio.exportReport.render(AppLocalePreference.current), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("Export model report \(model.ref.displayName)")
                .accessibilityLabel(L10n.Studio.a11yExportModelReport.render(AppLocalePreference.current, model.ref.displayName))
            }
            .font(Theme.Typography.caption)
        }
        .padding(Theme.Spacing.md)
        .background(Theme.ProNoirPanelBackground())
    }
}

private struct StudioChatSessionCard: View {
    var session: StudioChatSession
    var open: () -> Void
    var rename: () -> Void
    var togglePinned: () -> Void
    var exportMarkdown: () -> Void
    var exportJSON: () -> Void
    var delete: () -> Void

    private var status: StudioChatSessionStatus.Summary {
        StudioChatSessionStatus.summary(for: session)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                Image(systemName: session.isPinned ? "pin.fill" : "bubble.left.and.bubble.right")
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(Theme.Typography.bodyHi)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .lineLimit(1)
                    Text(session.modelName ?? "No model recorded")
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textLow)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(session.turnCount)")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
                    .monospacedDigit()
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Theme.Colors.surfaceHi)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                    .fixedSize(horizontal: true, vertical: false)
            }

            if session.isPinned || status.needsAttention || session.hasSummaryExport {
                HStack(spacing: Theme.Spacing.xs) {
                    Spacer()
                        .frame(width: 28)
                    if session.isPinned {
                        Label(L10n.Studio.pinned.render(AppLocalePreference.current), systemImage: "pin.fill")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.success)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.Colors.surfaceHi)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if status.needsAttention {
                        Label(status.label, systemImage: "exclamationmark.triangle")
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.danger)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Theme.Colors.danger.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    if session.hasSummaryExport {
                        Label(summaryExportLabel, systemImage: summaryExportSystemImage)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(summaryExportTint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(summaryExportTint.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength: 0)
                }
            }

            Text(session.preview)
                .font(Theme.Typography.caption)
                .foregroundStyle(Theme.Colors.textMid)
                .lineLimit(3)
                .frame(minHeight: 42, alignment: .topLeading)

            HStack(spacing: Theme.Spacing.sm) {
                Text(Self.dateFormatter.string(from: session.updatedAt))
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                Spacer()
                Button(action: open) {
                    Label(L10n.Studio.openChat.render(AppLocalePreference.current), systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(openAccessibilityTitle)
                .accessibilityLabel(openAccessibilityTitle)
                .help("Open chat session")
                Button(action: rename) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(renameAccessibilityTitle)
                .accessibilityLabel(renameAccessibilityTitle)
                .help("Rename chat session")
                Button(action: togglePinned) {
                    Image(systemName: session.isPinned ? "pin.slash" : "pin")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(pinAccessibilityTitle)
                .accessibilityLabel(pinAccessibilityTitle)
                .help(session.isPinned ? "Unpin chat session" : "Pin chat session")
                Button(action: exportMarkdown) {
                    Image(systemName: "doc.text")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(markdownExportAccessibilityTitle)
                .accessibilityLabel(markdownExportAccessibilityTitle)
                .help("Export chat as Markdown")
                Button(action: exportJSON) {
                    Image(systemName: "curlybraces")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(jsonExportAccessibilityTitle)
                .accessibilityLabel(jsonExportAccessibilityTitle)
                .help("Export chat as JSON")
                Button(role: .destructive, action: delete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(deleteAccessibilityTitle)
                .accessibilityLabel(deleteAccessibilityTitle)
                .help("Delete chat session")
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textMid)
        }
        .padding(Theme.Spacing.md)
        .background(Theme.ProNoirPanelBackground())
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .onTapGesture(perform: open)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private var openAccessibilityTitle: String {
        "Open chat \(session.title)"
    }

    private var renameAccessibilityTitle: String {
        "Rename chat \(session.title)"
    }

    private var pinAccessibilityTitle: String {
        "\(session.isPinned ? "Unpin" : "Pin") chat \(session.title)"
    }

    private var markdownExportAccessibilityTitle: String {
        "Export Markdown chat \(session.title)"
    }

    private var jsonExportAccessibilityTitle: String {
        "Export JSON chat \(session.title)"
    }

    private var deleteAccessibilityTitle: String {
        "Delete chat \(session.title)"
    }

    private var summaryExportExists: Bool {
        session.summaryExportFileExists
    }

    private var summaryExportLabel: String {
        summaryExportExists ? "Summary saved" : "Summary missing"
    }

    private var summaryExportSystemImage: String {
        summaryExportExists ? "doc.text.fill" : "doc.badge.exclamationmark"
    }

    private var summaryExportTint: Color {
        summaryExportExists ? Theme.Colors.success : Theme.Colors.warning
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

struct StudioAdvancedModelsScreen: View {
    @Environment(AppState.self) private var app
    @State private var models: [ModelSummary] = []
    @State private var selectedID: String?
    @State private var inspection: ModelInspection?
    @State private var jobs: [ModelJob] = []
    @State private var status = "Ready"
    @State private var jobService = StudioJobService()
    @State private var latestActionJobID: JobID?

    private var selected: ModelSummary? {
        models.first { $0.id == selectedID }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                StudioToolbar(title: "Advanced Models", subtitle: status) {
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
        .task { await refresh() }
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
        return StudioAdvancedModelBenchmarkGate.unavailableReason(
            displayName: selected.ref.displayName,
            modality: selectedModalityText,
            isLoaded: selected.isLoaded
        )
    }

    private var validationUnavailableReason: String? {
        StudioAdvancedModelValidationGate.unavailableReason(
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
        StudioAdvancedModelReportGate.unavailableReason(
            hasSelectedModel: selected != nil,
            hasInspection: inspection != nil
        )
    }

    private var reportStepValue: String {
        reportUnavailableReason ?? "Ready to export"
    }

    private var benchmarkActionTitle: String {
        if let reason = benchmarkUnavailableReason {
            return "Advanced Models Benchmark unavailable: \(reason)"
        }
        return "Advanced Models Benchmark \(selected?.ref.displayName ?? "selected model")"
    }

    private var validationActionTitle: String {
        if let reason = validationUnavailableReason {
            return "Advanced Models Validate unavailable: \(reason)"
        }
        return "Advanced Models Validate \(selected?.ref.displayName ?? "selected model")"
    }

    private var reportActionTitle: String {
        if let reason = reportUnavailableReason {
            return "Advanced Models Export Report unavailable: \(reason)"
        }
        return "Advanced Models Export Report for \(selected?.ref.displayName ?? "selected model")"
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
            .accessibilityIdentifier("Advanced Models Run Inspect")
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

            Spacer(minLength: Theme.Spacing.md)

            Button {
                copySelectedPath()
            } label: {
                Label(L10n.Studio.copyPath.render(AppLocalePreference.current), systemImage: "doc.on.doc")
            }
            .disabled(selected?.ref.localURL == nil)
            .accessibilityIdentifier("Advanced Models Copy Path")
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

    private func service() -> StudioAdvancedModelService {
        StudioAdvancedModelService(app: app, jobs: jobService)
    }

    private func refresh() async {
        models = (try? await StudioModelService(app: app).listLocalModels()) ?? []
        selectedID = selectedID ?? models.first(where: { $0.ref.localURL == app.selectedModelPath })?.id ?? models.first?.id
        jobs = (try? await jobService.listJobs()) ?? []
    }

    private func inspect() async {
        guard let selected else { return }
        let jobID = jobService.start(
            kind: .inspect,
            model: selected.ref,
            message: "Queued inspection"
        )
        latestActionJobID = jobID
        jobs = (try? await jobService.listJobs()) ?? jobs
        status = "Inspecting \(selected.ref.displayName)"
        jobService.update(
            jobID,
            status: .running,
            progress: 0.2,
            message: "Reading config, tokenizer, and weight files"
        )
        do {
            inspection = try await service().inspect(selected.ref)
            jobService.update(
                jobID,
                status: .completed,
                progress: 1.0,
                message: "Inspection completed"
            )
            updateStatus("Inspection ready", for: jobID)
        } catch {
            jobService.update(
                jobID,
                status: .failed,
                progress: 1.0,
                message: error.localizedDescription
            )
            updateStatus(error.localizedDescription, for: jobID)
            StudioAdvancedModelDiagnostic.recordFailure(
                kind: .inspect,
                model: selected.ref,
                message: error.localizedDescription
            )
        }
        jobs = (try? await jobService.listJobs()) ?? jobs
    }

    private func validate() async {
        guard let selected else { return }
        if let reason = validationUnavailableReason {
            status = reason
            return
        }
        status = "Validation queued"
        let jobID = try? await service().validate(selected.ref, suite: .loadAndShortChat)
        latestActionJobID = jobID
        await refreshJobsUntilTerminal(jobID)
        if let jobID, let job = jobs.first(where: { $0.id == jobID }) {
            updateStatus(job.message, for: jobID)
        }
    }

    private func benchmark() async {
        guard let selected else { return }
        if let reason = benchmarkUnavailableReason {
            status = reason
            return
        }
        status = "Benchmark queued"
        let jobID = try? await service().benchmark(selected.ref, config: BenchmarkConfig())
        latestActionJobID = jobID
        await refreshJobsUntilTerminal(jobID)
        if let jobID, let job = jobs.first(where: { $0.id == jobID }) {
            updateStatus(job.message, for: jobID)
        }
    }

    private func package() async {
        guard let selected else { return }
        if let reason = reportUnavailableReason {
            status = reason
            return
        }
        status = "Exporting report"
        let jobID = try? await service().package(selected.ref, options: PackageOptions())
        latestActionJobID = jobID
        jobs = (try? await jobService.listJobs()) ?? jobs
        if let jobID, let job = jobs.first(where: { $0.id == jobID }) {
            updateStatus(job.message, for: jobID)
        }
    }

    private func updateStatus(_ message: String, for jobID: JobID) {
        guard latestActionJobID == jobID else { return }
        status = message
    }

    private func refreshJobsUntilTerminal(_ jobID: JobID?) async {
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
        return "Advanced Models Copy \(outputKind) for \(job.inputModel.displayName)"
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
        return "Advanced Models Copy \(outputKind)"
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

private struct ChatTurnBubble: View {
    var turn: ChatTurn
    var regenerateDisabledReason: String?
    var copy: () -> Void
    var regenerate: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            if turn.role == .assistant {
                bubble
                Spacer(minLength: 80)
            } else {
                Spacer(minLength: 80)
                bubble
            }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(turn.role == .user ? "You" : "MLX Studio")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textLow)
                if turn.streamState != .complete {
                    Label(stateLabel, systemImage: stateIcon)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(stateColor)
                        .lineLimit(1)
                }
                Spacer()
            }
            let content = StudioChatText.cleanForDisplay(turn.content)
            Text(content.isEmpty ? "Thinking" : content)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.Colors.textHigh)
                .textSelection(.enabled)

            HStack(spacing: Theme.Spacing.sm) {
                Button(action: copy) {
                    Label(L10n.Studio.copy.render(AppLocalePreference.current), systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .disabled(content.isEmpty)
                .accessibilityIdentifier(copyAccessibilityTitle)
                .accessibilityLabel(copyAccessibilityTitle)

                Button(action: regenerate) {
                    Label(regenerateLabel, systemImage: regenerateIcon)
                }
                .buttonStyle(.plain)
                .disabled(regenerateDisabledReason != nil)
                .help(regenerateDisabledReason ?? regenerateHelp)
                .accessibilityIdentifier(regenerateAccessibilityTitle)
                .accessibilityLabel(regenerateAccessibilityTitle)
                .accessibilityHint(regenerateDisabledReason ?? regenerateHelp)
            }
            .font(Theme.Typography.caption)
            .foregroundStyle(Theme.Colors.textMid)
            .padding(.top, 2)
        }
        .padding(Theme.Spacing.md)
        .frame(maxWidth: 680, alignment: .leading)
        .background(turn.role == .user ? Theme.Colors.surfaceHi.opacity(0.92) : Theme.Colors.surface.opacity(0.92))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(Theme.Colors.border, lineWidth: 1)
        )
    }

    private var regenerateLabel: String {
        if turn.streamState == .failed { return "Retry" }
        return turn.role == .user ? "Regenerate" : "Regenerate"
    }

    private var copyAccessibilityTitle: String {
        turn.role == .user ? "Copy prompt" : "Copy response"
    }

    private var regenerateAccessibilityTitle: String {
        if turn.streamState == .failed { return "Retry response" }
        return turn.role == .user ? "Regenerate prompt" : "Regenerate response"
    }

    private var regenerateIcon: String {
        turn.streamState == .failed ? "arrow.clockwise.circle" : "arrow.triangle.2.circlepath"
    }

    private var regenerateHelp: String {
        if turn.streamState == .failed { return "Retry from the prior user prompt." }
        return "Regenerate from this point in the session."
    }

    private var stateLabel: String {
        switch turn.streamState {
        case .complete: return "Complete"
        case .streaming: return "Streaming"
        case .failed: return "Failed"
        case .cancelled: return "Stopped"
        }
    }

    private var stateIcon: String {
        switch turn.streamState {
        case .complete: return "checkmark.circle"
        case .streaming: return "dot.radiowaves.left.and.right"
        case .failed: return "exclamationmark.triangle"
        case .cancelled: return "stop.circle"
        }
    }

    private var stateColor: Color {
        switch turn.streamState {
        case .complete: return Theme.Colors.textLow
        case .streaming: return Theme.Colors.accent
        case .failed: return Theme.Colors.danger
        case .cancelled: return Theme.Colors.warning
        }
    }
}

struct ModelRecommendationCard: View {
    var model: RecommendedModel
    var installState: ModelInstallViewState? = nil
    var queue: () -> Void
    var downloadAndChat: () -> Void

    private var active: Bool { installState?.isActive == true }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Image(systemName: "arrow.down.circle")
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
                    downloadAndChat()
                } label: {
                    Label(active ? "Working" : "Download & Chat", systemImage: active ? "arrow.triangle.2.circlepath" : "arrow.down.circle")
                }
                .buttonStyle(.borderedProminent)
                .disabled(active)

                Button {
                    queue()
                } label: {
                    Label(L10n.Studio.queue.render(AppLocalePreference.current), systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.bordered)
                .disabled(active)
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
