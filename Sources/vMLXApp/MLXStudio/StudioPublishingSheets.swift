import AppKit
import MLXStudioDomain
import MLXStudioOptimization
import MLXStudioPersistence
import SwiftUI
import vMLXEngine
import vMLXTheme

struct StudioModelCardSheet: View {
    let model: ModelSummary

    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: JANGPublishingCoordinator?
    @State private var jobID: MLXStudioDomain.JobID?
    @State private var task: Task<Void, Never>?
    @State private var card: JANGModelCardResult?
    @StateObject private var progress = StudioPublishingStatusModel(
        "Generating a model-card preview…"
    )
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader("Model Card", subtitle: model.ref.displayName) { dismiss() }
            Divider()
            Group {
                if let card {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                            warning(card)
                            metadata(card)
                            Text(card.cardMarkdown)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(Theme.Spacing.lg)
                    }
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Model card unavailable",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else {
                    ProgressView(progress.text).padding(40)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text(progress.text).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textMid)
                Spacer()
                if let card {
                    Button("Copy Markdown") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(card.cardMarkdown, forType: .string)
                        progress.text = "Copied model-card markdown"
                    }
                    Button("Save README.md") { save(card) }
                        .buttonStyle(.borderedProminent)
                } else if errorMessage != nil {
                    Button("Retry") { generate() }
                }
            }
            .padding(Theme.Spacing.md)
        }
        .frame(minWidth: 760, minHeight: 620)
        .background(Theme.ProNoirBackground())
        .task { generate() }
        .onDisappear { cancel() }
    }

    private func warning(_ card: JANGModelCardResult) -> some View {
        Label {
            Text(card.licenseUnknown == true
                ? "Skeleton only. Confirm the source license and add evaluation evidence before publishing."
                : "Skeleton only. Add evaluation evidence and review every claim before publishing.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .foregroundStyle(Theme.Colors.warning)
        .padding(Theme.Spacing.md)
        .background(Theme.Colors.warning.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
    }

    private func metadata(_ card: JANGModelCardResult) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.lg, verticalSpacing: Theme.Spacing.sm) {
            GridRow { Text("License"); Text(card.license) }
            GridRow { Text("Base model"); Text(card.baseModel) }
            if let quantization = card.quantizationConfiguration {
                GridRow { Text("Profile"); Text(quantization.profile) }
                GridRow { Text("Average bits"); Text(String(format: "%.2f", quantization.actualBits)) }
            } else {
                GridRow { Text("Quantization"); Text("Not claimed") }
            }
        }
        .font(Theme.Typography.body)
        .foregroundStyle(Theme.Colors.textHigh)
    }

    private func generate() {
        cancel()
        guard let modelURL = model.ref.localURL else {
            errorMessage = "The selected model has no local path."
            return
        }
        errorMessage = nil
        card = nil
        progress.text = "Starting durable model-card job…"
        let nextJobID = MLXStudioDomain.JobID()
        jobID = nextJobID
        task = Task {
            do {
                guard let artifact = canonicalArtifact else {
                    throw StudioModelCardError.missingCanonicalArtifact
                }
                let result: JANGModelCardResult
                if artifact.format == .jang || artifact.format == .jangTQ {
                    let worker = try StudioJANGWorkerFactory.make()
                    let nextCoordinator = JANGPublishingCoordinator(worker: worker)
                    coordinator = nextCoordinator
                    result = try await nextCoordinator.generateModelCard(
                        modelURL: modelURL,
                        artifactID: artifact.id,
                        jobID: nextJobID,
                        eventSink: progress
                    )
                } else {
                    result = try ArtifactModelCardBuilder.build(
                        modelURL: modelURL,
                        artifact: artifact
                    )
                }
                guard !Task.isCancelled else { return }
                card = result
                progress.text = "Model-card preview ready"
            } catch is CancellationError {
                progress.text = "Model-card generation cancelled"
            } catch {
                errorMessage = error.localizedDescription
                progress.text = "Model-card generation failed"
            }
        }
    }

    private func save(_ card: JANGModelCardResult) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "README.md"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try Data(card.cardMarkdown.utf8).write(to: destination, options: .atomic)
            progress.text = "Saved \(destination.path)"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func cancel() {
        task?.cancel()
        if let coordinator, let jobID {
            Task { await coordinator.cancel(jobID: jobID) }
        }
    }

    private var canonicalArtifact: ModelArtifact? {
        guard let repository = try? ModelArtifactRepository() else { return nil }
        if let artifact = try? repository.artifact(legacyModelID: model.ref.id) {
            return artifact
        }
        guard let id = ModelArtifactID(rawValue: model.ref.id) else { return nil }
        return try? repository.artifact(id: id)
    }

}

private enum StudioModelCardError: Error, LocalizedError {
    case missingCanonicalArtifact

    var errorDescription: String? {
        "The selected model is not a canonical artifact, so provenance claims cannot be generated."
    }
}

struct StudioPublishSheet: View {
    let model: ModelSummary

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var hfAuth = HuggingFaceAuth.shared
    @State private var repositoryID: String
    @State private var isPrivate = false
    @State private var coordinator: JANGPublishingCoordinator?
    @State private var preview: JANGPublishPreview?
    @State private var result: JANGPublishResult?
    @State private var activeJobID: MLXStudioDomain.JobID?
    @State private var task: Task<Void, Never>?
    @StateObject private var progress = StudioPublishingStatusModel(
        "Run Preview before publishing."
    )
    @State private var errorMessage: String?
    @State private var isRunning = false

    init(model: ModelSummary) {
        self.model = model
        _repositoryID = State(initialValue: HuggingFaceRepositoryIDValidator.sanitizedModelName(
            model.ref.localURL?.lastPathComponent ?? model.ref.displayName
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader("Publish to Hugging Face", subtitle: model.ref.displayName) { dismiss() }
            Divider()
            Form {
                Section("Repository") {
                    TextField("org/model-name", text: $repositoryID)
                    Toggle("Private repository", isOn: $isPrivate)
                    Text("Preview may create a missing README.md locally using the reviewed JANG model-card skeleton.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Authentication") {
                    if hfAuth.hasToken {
                        Label(hfAuth.username.map { "Signed in as @\($0)" } ?? "Token stored in Keychain", systemImage: "checkmark.shield")
                            .foregroundStyle(Theme.Colors.success)
                    } else {
                        Label("Add and validate a Hugging Face token in Settings > API & Accounts.", systemImage: "key")
                            .foregroundStyle(Theme.Colors.warning)
                    }
                }
                if let preview {
                    Section("Confirmed preview") {
                        LabeledContent("Files", value: String(preview.fileCount))
                        LabeledContent("Total size", value: ByteCountFormatter.string(
                            fromByteCount: preview.totalSizeBytes,
                            countStyle: .file
                        ))
                        LabeledContent("Destination", value: preview.repositoryID)
                    }
                }
                if let result {
                    Section("Published") {
                        Link(result.url.absoluteString, destination: result.url)
                        if let commitURL = result.commitURL {
                            Link("Open published commit", destination: commitURL)
                        }
                    }
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Colors.danger)
                    }
                }
                Section("Job status") {
                    HStack {
                        if isRunning { ProgressView().controlSize(.small) }
                        Text(progress.text).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if isRunning {
                    Button("Cancel", role: .destructive) { cancel() }
                }
                Spacer()
                Button("Preview") { runPreview() }
                    .disabled(isRunning || !hfAuth.hasToken || repositoryID.isEmpty)
                Button("Publish") { runPublish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(isRunning || preview == nil || !hfAuth.hasToken)
            }
            .padding(Theme.Spacing.md)
        }
        .frame(minWidth: 680, minHeight: 560)
        .background(Theme.ProNoirBackground())
        .onChange(of: repositoryID) { _, _ in invalidatePreview() }
        .onChange(of: isPrivate) { _, _ in invalidatePreview() }
        .onDisappear { cancel() }
    }

    private func runPreview() {
        run { coordinator, modelURL, jobID in
            let next = try await coordinator.preview(
                modelURL: modelURL,
                repositoryID: repositoryID,
                isPrivate: isPrivate,
                artifactID: canonicalArtifactID,
                jobID: jobID,
                eventSink: progress
            )
            preview = next
            result = nil
            progress.text = "Preview confirmed. Review destination and size before Publish."
        }
    }

    private func runPublish() {
        let confirmed = preview
        run { coordinator, modelURL, jobID in
            let published = try await coordinator.publish(
                modelURL: modelURL,
                repositoryID: repositoryID,
                isPrivate: isPrivate,
                confirmedPreview: confirmed,
                artifactID: canonicalArtifactID,
                jobID: jobID,
                eventSink: progress
            )
            result = published
            progress.text = "Published successfully"
        }
    }

    private func run(
        operation: @escaping @MainActor (
            JANGPublishingCoordinator,
            URL,
            MLXStudioDomain.JobID
        ) async throws -> Void
    ) {
        cancel()
        guard let modelURL = model.ref.localURL else {
            errorMessage = "The selected model has no local path."
            return
        }
        guard let token = hfAuth.currentToken() else {
            errorMessage = "A validated Hugging Face token is required."
            return
        }
        let jobID = MLXStudioDomain.JobID()
        activeJobID = jobID
        isRunning = true
        errorMessage = nil
        task = Task {
            do {
                let worker = try StudioJANGWorkerFactory.make(
                    secretEnvironment: ["HF_HUB_TOKEN": token]
                )
                let nextCoordinator = JANGPublishingCoordinator(worker: worker)
                coordinator = nextCoordinator
                try await operation(nextCoordinator, modelURL, jobID)
            } catch is CancellationError {
                progress.text = "Publishing job cancelled"
            } catch {
                errorMessage = error.localizedDescription
                progress.text = "Publishing job failed"
            }
            isRunning = false
        }
    }

    private func cancel() {
        task?.cancel()
        if let coordinator, let activeJobID {
            Task { await coordinator.cancel(jobID: activeJobID) }
        }
        isRunning = false
    }

    private func invalidatePreview() {
        preview = nil
        result = nil
        if !isRunning { progress.text = "Repository changed; run Preview again." }
    }

    private var canonicalArtifactID: ModelArtifactID? {
        guard let repository = try? ModelArtifactRepository(),
              let artifact = try? repository.artifact(legacyModelID: model.ref.id) else { return nil }
        return artifact.id
    }

}

@MainActor
private final class StudioPublishingStatusModel: ObservableObject, JANGPublishingEventSink {
    @Published var text: String

    init(_ text: String) {
        self.text = text
    }

    func receive(_ envelope: OptimizationWorkerEventEnvelope) async {
        text = publishingEventDescription(envelope.event)
    }
}

private func sheetHeader(
    _ title: String,
    subtitle: String,
    close: @escaping () -> Void
) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title).font(Theme.Typography.title).foregroundStyle(Theme.Colors.textHigh)
            Text(subtitle).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textMid)
        }
        Spacer()
        Button("Close", action: close)
    }
    .padding(Theme.Spacing.lg)
}

@MainActor
private func publishingEventDescription(_ event: OptimizationWorkerEvent) -> String {
    switch event {
    case .phase(let index, let total, let name): return "\(name) (\(index)/\(total))"
    case .progress(let completed, let total, let label):
        return "\(label ?? "Uploading") — \(completed)/\(total) bytes"
    case .message(_, let text): return text
    case .structuredOutput: return "Processing structured result…"
    case .toolReportedCompletion(let ok, _, let error): return ok ? "Tool completed" : (error ?? "Tool failed")
    case .completed: return "Job completed"
    case .cancelled: return "Job cancelled"
    case .failed(let message, _, _): return message
    }
}
