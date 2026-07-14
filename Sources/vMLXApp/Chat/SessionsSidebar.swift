import SwiftUI
import UniformTypeIdentifiers
#if canImport(AppKit)
import AppKit
#endif
import vMLXTheme

struct SessionsSidebar: View {
    @Bindable var vm: ChatViewModel
    @Environment(\.appLocale) private var appLocale
    @State private var importError: String?
    @State private var exportError: String?

    private var collectionNames: [String] {
        Array(Set(vm.sessions.compactMap(\.collectionName))).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Colors.textLow)
                    .font(.system(size: 11))
                TextField(L10n.Common.search.render(appLocale), text: $vm.searchQuery)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.textHigh)
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.Colors.surfaceHi)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .stroke(Theme.Colors.border, lineWidth: 1)
                    )
            )
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.md)

            Button {
                vm.newSession()
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: "plus")
                    Text(L10n.ChatUI.newChat.render(appLocale))
                }
                .font(Theme.Typography.bodyHi)
                .foregroundStyle(Theme.Colors.textHigh)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .fill(Theme.Colors.accent)
                )
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.sm)

            Button(action: importConversation) {
                Label("Import conversation", systemImage: "square.and.arrow.down")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.textMid)
            }
            .buttonStyle(.plain)
            .padding(.top, Theme.Spacing.xs)

            ScrollView {
                LazyVStack(spacing: Theme.Spacing.xs) {
                    ForEach(vm.filteredSessions) { s in
                        SessionRow(
                            session: s,
                            isActive: s.id == vm.activeSessionId,
                            onSelect: { vm.selectSession(s.id) },
                            onDelete: { vm.deleteSession(s.id) },
                            onRename: { newTitle in vm.renameSession(s.id, to: newTitle) },
                            onExport: { exportSession(s) },
                            onDuplicate: { vm.duplicateSession(s.id) },
                            onTogglePinned: { vm.togglePinned(s.id) },
                            onMove: { vm.moveSession(s.id, toCollection: $0) },
                            availableCollections: collectionNames
                        )
                    }
                }
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.top, Theme.Spacing.md)
            }

            // Footer — Clear-all button. Only enabled when there's at
            // least one chat to remove. Two-step confirm so a stray click
            // doesn't nuke the user's entire history.
            ClearAllButton(vm: vm)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
        }
        .alert("Import failed", isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) { importError = nil }
        } message: {
            Text(importError ?? "Unknown import error")
        }
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: {
            Text(exportError ?? "The conversation could not be written.")
        }
    }

    private func importConversation() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Import conversation"
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            Task { @MainActor in
                do {
                    try await vm.importConversation(data)
                } catch {
                    importError = error.localizedDescription
                }
            }
        } catch {
            importError = error.localizedDescription
        }
        #endif
    }

    /// Opens an NSSavePanel then writes the rendered Markdown or JSON
    /// to disk. Format is chosen via the save panel's content-type
    /// filter — the user picks `.md` or `.json` from the popup and we
    /// shape the output accordingly. Messages are fetched straight
    /// from SQLite so the export reflects persisted state even if the
    /// session isn't currently selected.
    private func exportSession(_ session: ChatSession) {
        #if canImport(AppKit)
        let msgs = Database.shared.messages(for: session.id)

        let panel = NSSavePanel()
        let mdType = UTType(filenameExtension: "md") ?? .plainText
        let jsonType = UTType(filenameExtension: "json") ?? .json
        panel.allowedContentTypes = [mdType, jsonType]
        panel.nameFieldStringValue = {
            let base = session.title.isEmpty ? "chat" : session.title
            let safe = base.replacingOccurrences(of: "/", with: "-")
            return "\(safe).md"
        }()
        panel.title = "Export chat"
        panel.prompt = "Export"
        if panel.runModal() == .OK, let url = panel.url {
            // Pick format from the final filename extension — AppKit
            // honours the user's pop-up choice by rewriting the URL's
            // extension to match the selected content type.
            let ext = url.pathExtension.lowercased()
            let payload: String
            if ext == "json" {
                payload = ChatExporter.exportToJSON(session, messages: msgs)
            } else {
                payload = ChatExporter.exportToMarkdown(session, messages: msgs)
            }
            do {
                guard let data = payload.data(using: .utf8) else {
                    throw CocoaError(.fileWriteInapplicableStringEncoding)
                }
                try data.write(to: url, options: .atomic)
            } catch {
                exportError = error.localizedDescription
            }
        }
        #endif
    }
}

private struct SessionRow: View {
    let session: ChatSession
    let isActive: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onRename: (String) -> Void
    let onExport: () -> Void
    let onDuplicate: () -> Void
    let onTogglePinned: () -> Void
    let onMove: (String?) -> Void
    let availableCollections: [String]

    @State private var hovered = false
    @State private var showDeleteConfirm = false
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @Environment(\.appLocale) private var appLocale

    var body: some View {
        Button(action: { if !isRenaming { onSelect() } }) {
            HStack(spacing: Theme.Spacing.sm) {
                if isRenaming {
                    TextField(L10n.Misc.chatName.render(appLocale), text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.Colors.textHigh)
                        .onSubmit { commitRename() }
                        .onExitCommand { cancelRename() }
                } else {
                    if session.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.Colors.warning)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.title)
                            .font(Theme.Typography.body)
                            .foregroundStyle(isActive ? Theme.Colors.textHigh : Theme.Colors.textMid)
                            .lineLimit(1)
                        if let detail = sessionDetail {
                            Text(detail)
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textLow)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
                if hovered && !isRenaming {
                    Button {
                        startRename()
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.textLow)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.Tooltip.renameChat.render(appLocale))
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Colors.textLow)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.Tooltip.deleteChat.render(appLocale))
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(isActive ? Theme.Colors.surfaceHi : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .contextMenu {
            Button(L10n.Common.rename.render(appLocale)) { startRename() }
            Button(session.isPinned ? "Unpin" : "Pin") { onTogglePinned() }
            Button("Duplicate") { onDuplicate() }
            Menu("Move to collection") {
                Button("Unfiled") { onMove(nil) }
                ForEach(availableCollections, id: \.self) { name in
                    Button(name) { onMove(name) }
                }
                Divider()
                Button("New collection…") { startCollectionRename() }
            }
            Button(L10n.Common.exportAsMarkdown.render(appLocale)) { onExport() }
            Divider()
            Button(L10n.Common.deleteChat.render(appLocale), role: .destructive) {
                showDeleteConfirm = true
            }
        }
        .confirmationDialog(
            "Delete this chat?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.Common.delete.render(appLocale), role: .destructive) { onDelete() }
            Button(L10n.Common.cancel.render(appLocale), role: .cancel) { }
        } message: {
            Text(L10n.ChatUI.deleteSessionConfirm.format(locale: appLocale, session.title as NSString))
        }
        .alert("New collection", isPresented: $showCollectionPrompt) {
            TextField("Collection name", text: $collectionDraft)
            Button("Cancel", role: .cancel) { }
            Button("Move") { onMove(collectionDraft) }
                .disabled(collectionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("Keep related conversations together without changing their content.")
        }
    }

    @State private var showCollectionPrompt = false
    @State private var collectionDraft = ""

    private var sessionDetail: String? {
        let parts = [session.collectionName, session.modelName]
            .compactMap { value in
                value?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func startCollectionRename() {
        collectionDraft = session.collectionName ?? ""
        showCollectionPrompt = true
    }

    private func startRename() {
        renameDraft = session.title
        isRenaming = true
    }

    private func commitRename() {
        onRename(renameDraft)
        isRenaming = false
    }

    private func cancelRename() {
        isRenaming = false
    }
}

/// Footer button that wipes every chat after a confirmation dialog.
/// Lives at the bottom of the sidebar; disabled when there are zero chats
/// so an empty-state app doesn't show a destructive button you can't use.
private struct ClearAllButton: View {
    @Bindable var vm: ChatViewModel
    @State private var showConfirm = false
    @Environment(\.appLocale) private var appLocale

    var body: some View {
        Button {
            showConfirm = true
        } label: {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "trash.slash")
                    .font(.system(size: 11, weight: .medium))
                Text(L10n.ChatUI.clearAllChats.render(appLocale))
                    .font(Theme.Typography.body)
            }
            .foregroundStyle(Theme.Colors.danger)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .stroke(Theme.Colors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(vm.sessions.isEmpty)
        .opacity(vm.sessions.isEmpty ? 0.4 : 1.0)
        .confirmationDialog(
            "Clear all chats?",
            isPresented: $showConfirm,
            titleVisibility: .visible
        ) {
            Button(L10n.Common.deleteAll.render(appLocale), role: .destructive) { vm.clearAllSessions() }
            Button(L10n.Common.cancel.render(appLocale), role: .cancel) { }
        } message: {
            Text(L10n.ChatUI.clearAllChatsConfirm.format(locale: appLocale, Int64(vm.sessions.count)))
        }
    }
}
