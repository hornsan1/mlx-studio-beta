import Foundation
import MLXStudioDomain
import MLXStudioOptimization
import MLXStudioPersistence
import SwiftUI
import vMLXTheme

#if canImport(AppKit)
import AppKit
import UniformTypeIdentifiers
#endif

struct StudioOptimizeScreen: View {
    @State private var model = StudioOptimizeViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Optimize")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textHigh)
                    Text(model.status)
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(model.hasError ? Theme.Colors.danger : Theme.Colors.textLow)
                        .lineLimit(2)
                }
                Spacer()
                Button { Task { await model.refresh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .padding(Theme.Spacing.lg)
            Divider().background(Theme.Colors.border)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    optimizeCard("1. Select source", subtitle: "Choose a canonical artifact from models.sqlite3.") {
                        Picker("Artifact", selection: $model.selectedArtifactID) {
                            Text("Select a model").tag(nil as ModelArtifactID?)
                            ForEach(model.artifacts, id: \.id) { artifact in
                                Text("\(artifact.name) — \(artifact.format.rawValue)")
                                    .tag(artifact.id as ModelArtifactID?)
                            }
                        }
                        .accessibilityIdentifier("optimize.artifact")
                        if let artifact = model.selectedArtifact {
                            Text(artifact.localURL.path)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.Colors.textLow)
                                .textSelection(.enabled)
                        }
                    }

                    optimizeCard("2. Define objective", subtitle: "Estimates remain labeled as estimates until measured.") {
                        Picker("Objective", selection: $model.objectivePreset) {
                            ForEach(StudioOptimizationObjectivePreset.allCases) { preset in
                                Text(preset.label).tag(preset)
                            }
                        }
                        .pickerStyle(.segmented)
                        TextField("Notes", text: $model.objectiveNotes)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("optimize.objective.notes")
                    }

                    optimizeCard("3. Review plan", subtitle: model.action.explanation) {
                        Picker("Action", selection: $model.action) {
                            Text("Analyze only").tag(OptimizationWorkspaceAction.analyzeOnly)
                            Text("Quantize only").tag(OptimizationWorkspaceAction.quantizeOnly)
                            Text("Prune only").tag(OptimizationWorkspaceAction.pruneOnly)
                        }
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("optimize.action")

                        if model.action == .quantizeOnly {
                            HStack {
                                Picker("Technology", selection: $model.quantizationTechnology) {
                                    Text("JANG").tag(QuantizationTechnology.jang)
                                    Text("JANGTQ").tag(QuantizationTechnology.jangTQ)
                                }
                                TextField("Profile", text: $model.quantizationProfile)
                                    .textFieldStyle(.roundedBorder)
                                Picker("Method", selection: $model.quantizationMethod) {
                                    Text("MSE").tag("mse")
                                    Text("RTN").tag("rtn")
                                }
                            }
                        }

                        if model.action == .pruneOnly {
                            Text("Specialized build support is currently limited to reviewed Qwen3 MoE keep maps.")
                                .font(Theme.Typography.captionHi)
                                .foregroundStyle(Theme.Colors.warning)
                            HStack {
                                TextField("Layer", value: $model.pruneLayer, format: .number)
                                TextField("Expert", value: $model.pruneExpert, format: .number)
                                Button("Choose reviewed keep map…") { model.chooseKeepMap() }
                            }
                            if !model.keepMapPath.isEmpty {
                                Text(model.keepMapPath)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Theme.Colors.textLow)
                            }
                        }

                        if model.action != .analyzeOnly {
                            HStack {
                                TextField("Output directory", text: $model.outputPath)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityIdentifier("optimize.output")
                                Button("Choose…") { model.chooseOutputDirectory() }
                            }
                        }

                        HStack {
                            Button("Review plan") { model.reviewPlan() }
                                .accessibilityIdentifier("optimize.review")
                            if let validation = model.planValidation {
                                Label(
                                    validation.status == .valid ? "Plan valid" : "Plan blocked",
                                    systemImage: validation.status == .valid
                                        ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                                )
                                .foregroundStyle(
                                    validation.status == .valid
                                        ? Theme.Colors.success : Theme.Colors.warning
                                )
                            }
                        }
                    }

                    optimizeCard("4. Build and verify", subtitle: model.workerSummary) {
                        if model.isRunning {
                            ProgressView(value: model.progress)
                                .accessibilityIdentifier("optimize.progress")
                        }
                        HStack {
                            Button(model.action == .analyzeOnly ? "Analyze" : "Build and verify") {
                                model.run()
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(
                                model.isRunning || model.selectedArtifact == nil
                                    || (model.action != .analyzeOnly && !model.workerReady)
                            )
                            .accessibilityIdentifier("optimize.run")
                            Button("Cancel") { model.cancel() }
                                .disabled(!model.isRunning)
                            Button("Recover last failed job") { model.recoverLastFailedJob() }
                                .disabled(model.isRunning || model.recoverableJobID == nil)
                        }
                        if !model.eventLog.isEmpty {
                            Text(model.eventLog.joined(separator: "\n"))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.Colors.textMid)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Theme.Spacing.md)
                                .background(Theme.Colors.surface.opacity(0.7))
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                                .accessibilityIdentifier("optimize.events")
                        }
                    }
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: 980)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.Colors.background)
        .task { await model.refresh() }
    }

    private func optimizeCard<Content: View>(
        _ title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Colors.textHigh)
            Text(subtitle)
                .font(Theme.Typography.captionHi)
                .foregroundStyle(Theme.Colors.textLow)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.lg)
        .background(Theme.Colors.surfaceHi.opacity(0.48))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .stroke(Theme.Colors.border.opacity(0.75), lineWidth: 1)
        }
    }
}

enum StudioOptimizationObjectivePreset: String, CaseIterable, Identifiable {
    case balanced
    case smaller
    case preserveQuality
    case faster

    var id: String { rawValue }
    var label: String {
        switch self {
        case .balanced: return "Balanced"
        case .smaller: return "Smaller"
        case .preserveQuality: return "Preserve quality"
        case .faster: return "Faster"
        }
    }

    func objective(notes: String) -> OptimizationObjective {
        switch self {
        case .balanced:
            return .init(minimumQualityScore: 0.95, notes: notes)
        case .smaller:
            return .init(maximumArtifactSizeBytes: 8_000_000_000, notes: notes)
        case .preserveQuality:
            return .init(minimumQualityScore: 0.99, notes: notes)
        case .faster:
            return .init(targetTokensPerSecond: 20, notes: notes)
        }
    }
}

extension OptimizationWorkspaceAction {
    fileprivate var explanation: String {
        switch self {
        case .analyzeOnly: return "Persist and validate a plan without changing model files."
        case .quantizeOnly: return "Run structured JANG conversion, then validate and register the result."
        case .pruneOnly: return "Apply a reviewed architecture-specific keep map, then validate the BF16 result."
        }
    }
}

@MainActor
@Observable
final class StudioOptimizeViewModel {
    var artifacts: [ModelArtifact] = []
    var selectedArtifactID: ModelArtifactID?
    var objectivePreset: StudioOptimizationObjectivePreset = .balanced
    var objectiveNotes = ""
    var action: OptimizationWorkspaceAction = .analyzeOnly
    var quantizationTechnology: QuantizationTechnology = .jang
    var quantizationProfile = "JANG_4K"
    var quantizationMethod = "mse"
    var pruneLayer = 0
    var pruneExpert = 0
    var keepMapPath = ""
    var outputPath = ""
    var status = "Loading canonical artifacts…"
    var workerSummary = "Checking the structured optimization worker…"
    var workerReady = false
    var eventLog: [String] = []
    var progress = 0.0
    var isRunning = false
    var hasError = false
    var planValidation: PlanValidationResult?
    var recoverableJobID: MLXStudioDomain.JobID?

    private var repository: ModelArtifactRepository?
    private var coordinator: OptimizationWorkspaceCoordinator?
    private var activeRequest: OptimizationWorkspaceRequest?
    private var activeTask: Task<Void, Never>?

    var selectedArtifact: ModelArtifact? {
        artifacts.first { $0.id == selectedArtifactID }
    }

    init() {
        do {
            let repository = try ModelArtifactRepository()
            let jobs = repository.makeJobRepository()
            let worker = PythonJANGWorker(
                configuration: Self.workerConfiguration(),
                jobRepository: jobs
            )
            self.repository = repository
            self.coordinator = OptimizationWorkspaceCoordinator(
                worker: worker,
                artifactRepository: repository,
                planRepository: repository.makeOptimizationPlanRepository(),
                jobRepository: jobs
            )
        } catch {
            status = "Optimize storage unavailable: \(error.localizedDescription)"
            hasError = true
        }
    }

    func refresh() async {
        guard let repository, let coordinator else { return }
        do {
            artifacts = try repository.artifacts().filter(Self.isSelectableArtifact)
            if selectedArtifact == nil { selectedArtifactID = artifacts.first?.id }
            if outputPath.isEmpty, let source = selectedArtifact {
                outputPath = source.localURL.deletingLastPathComponent()
                    .appendingPathComponent(source.name + "-optimized").path
            }
            let diagnostics = await coordinator.diagnostics()
            if diagnostics.issues.isEmpty {
                workerReady = true
                workerSummary = "Structured worker ready: \(diagnostics.toolVersion ?? diagnostics.pythonVersion ?? diagnostics.executable)"
            } else {
                workerReady = false
                workerSummary = "Worker blocked: \(diagnostics.issues.joined(separator: "; "))"
            }
            let recoverable = try repository.makeJobRepository().records().first {
                Set<DurableJobState>([.failed, .cancelled, .paused]).contains($0.state)
                    && $0.type.hasPrefix("optimization.")
            }
            recoverableJobID = recoverable?.id
            status = artifacts.isEmpty ? "No ready model artifacts found." : "Ready"
            hasError = false
        } catch {
            fail(error)
        }
    }

    func reviewPlan() {
        Task {
            do {
                let (_, request) = try makeRequest()
                guard let coordinator else { return }
                planValidation = try await coordinator.review(request)
                status = planValidation?.status == .valid ? "Plan is ready to run." : "Plan needs attention."
                hasError = planValidation?.status == .invalid
            } catch {
                planValidation = .init(status: .invalid, errors: [error.localizedDescription])
                fail(error)
            }
        }
    }

    func run() {
        guard activeTask == nil else { return }
        do {
            let (_, request) = try makeRequest()
            guard let coordinator else { return }
            activeRequest = request
            isRunning = true
            hasError = false
            progress = 0
            eventLog = []
            activeTask = Task { [weak self] in
                do {
                    for try await event in coordinator.events(for: request) {
                        guard !Task.isCancelled else { return }
                        self?.consume(event)
                    }
                    self?.isRunning = false
                    self?.activeTask = nil
                    await self?.refresh()
                } catch {
                    self?.isRunning = false
                    self?.activeTask = nil
                    self?.fail(error)
                    await self?.refreshRecoverableJob()
                }
            }
        } catch {
            fail(error)
        }
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        isRunning = false
        status = "Cancellation requested. Partial output follows the quarantine policy."
        if let activeRequest, let coordinator {
            Task { await coordinator.cancel(activeRequest) }
        }
    }

    func recoverLastFailedJob() {
        guard let recoverableJobID, let coordinator, activeTask == nil else { return }
        isRunning = true
        eventLog = []
        activeTask = Task { [weak self] in
            do {
                let stream = try await coordinator.recover(jobID: recoverableJobID)
                for try await event in stream { self?.consumeWorker(event) }
                self?.status = "Recovered worker job completed. Review and verify its output before publishing."
                self?.hasError = false
            } catch {
                self?.fail(error)
            }
            self?.isRunning = false
            self?.activeTask = nil
            await self?.refreshRecoverableJob()
        }
    }

    func chooseOutputDirectory() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { outputPath = url.path }
        #endif
    }

    func chooseKeepMap() {
        #if canImport(AppKit)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url { keepMapPath = url.path }
        #endif
    }

    private func makeRequest() throws -> (OptimizationPlan, OptimizationWorkspaceRequest) {
        guard let artifact = selectedArtifact else { throw StudioOptimizeError.missingArtifact }
        let recipe: QuantizationRecipe? = action == .quantizeOnly
            ? .init(
                name: "\(quantizationTechnology.rawValue.uppercased()) \(quantizationProfile)",
                technology: quantizationTechnology,
                profile: quantizationProfile,
                tensorRoleRules: ["method": quantizationMethod]
            ) : nil
        let pruning = action == .pruneOnly
            ? Set([ExpertCoordinate(layerIndex: pruneLayer, expertIndex: pruneExpert)]) : nil
        let plan = OptimizationPlan(
            projectID: artifact.projectID,
            sourceArtifactID: artifact.id,
            objective: objectivePreset.objective(notes: objectiveNotes),
            pruningConstraints: .init(minimumSurvivorsPerLayer: 1, maximumRemovalFraction: 0.5),
            strategyProposedRemovals: pruning,
            quantizationRecipe: recipe
        )
        let topology = action == .pruneOnly ? try Self.readTopology(at: artifact.localURL) : nil
        let request = OptimizationWorkspaceRequest(
            plan: plan,
            action: action,
            topology: topology,
            sourceURL: artifact.localURL,
            outputURL: action == .analyzeOnly ? nil : URL(fileURLWithPath: outputPath),
            reviewedKeepMapURL: keepMapPath.isEmpty ? nil : URL(fileURLWithPath: keepMapPath),
            outputName: URL(fileURLWithPath: outputPath).lastPathComponent
        )
        return (plan, request)
    }

    private func consume(_ event: OptimizationWorkspaceEvent) {
        switch event {
        case .planReady(_, let validation):
            planValidation = validation
            eventLog.append("Plan validated: \(validation.status.rawValue)")
            progress = 0.1
        case .analysisCompleted:
            eventLog.append("Analysis-only plan persisted")
            progress = 1
        case .worker(let role, let event):
            eventLog.append("\(role.rawValue): \(Self.describe(event.event))")
            if case .progress(let completed, let total, _) = event.event, total > 0 {
                let base = role == .build ? 0.1 : 0.75
                let span = role == .build ? 0.6 : 0.2
                progress = base + span * Double(completed) / Double(total)
            }
        case .completed(_, let artifact, let verified):
            progress = 1
            status = artifact.map {
                verified ? "Verified artifact registered: \($0.name)" : "Completed: \($0.name)"
            } ?? "Analysis complete. No model files were changed."
            eventLog.append(status)
        }
    }

    private func consumeWorker(_ event: OptimizationWorkerEventEnvelope) {
        eventLog.append("recovery: \(Self.describe(event.event))")
    }

    private func refreshRecoverableJob() async {
        guard let repository else { return }
        do {
            recoverableJobID = try repository.makeJobRepository().records().first {
                Set<DurableJobState>([.failed, .cancelled, .paused]).contains($0.state)
                    && $0.type.hasPrefix("optimization.")
            }?.id
        } catch {
            recoverableJobID = nil
        }
    }

    private func fail(_ error: Error) {
        status = error.localizedDescription
        hasError = true
        eventLog.append("Error: \(error.localizedDescription)")
    }

    private static func describe(_ event: OptimizationWorkerEvent) -> String {
        switch event {
        case .phase(_, _, let name): return name
        case .progress(let completed, let total, let label):
            return "\(label ?? "progress") \(completed)/\(total)"
        case .message(_, let text): return text
        case .toolReportedCompletion(let ok, _, let error): return ok ? "tool completed" : (error ?? "tool failed")
        case .completed: return "completed"
        case .cancelled: return "cancelled"
        case .failed(let message, _, _): return "failed: \(message)"
        }
    }

    private static func workerConfiguration() -> PythonJANGWorkerConfiguration {
        let variables = ProcessInfo.processInfo.environment
        let python = variables["MLX_STUDIO_JANG_PYTHON"] ?? "/usr/bin/python3"
        var environment = variables
        if let pythonPath = variables["MLX_STUDIO_JANG_PYTHONPATH"] {
            environment["PYTHONPATH"] = pythonPath
        }
        return .init(
            executableURL: URL(fileURLWithPath: python),
            environment: environment
        )
    }

    static func isSelectableArtifact(_ artifact: ModelArtifact) -> Bool {
        guard artifact.state == .ready || artifact.state == .discovered else { return false }
        return FileManager.default.fileExists(atPath: artifact.localURL.path)
    }

    private static func readTopology(at modelURL: URL) throws -> ModelExpertTopology {
        let data = try Data(contentsOf: modelURL.appendingPathComponent("config.json"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StudioOptimizeError.invalidTopology
        }
        let architecture = (json["model_type"] as? String)
            ?? (json["architecture"] as? String)
            ?? (json["architectures"] as? [String])?.first
            ?? "unknown"
        guard let layerCount = json["num_hidden_layers"] as? Int,
              let expertCount = (json["num_experts"] as? Int) ?? (json["num_local_experts"] as? Int),
              let topK = (json["num_experts_per_tok"] as? Int) ?? (json["num_experts_per_token"] as? Int)
        else { throw StudioOptimizeError.invalidTopology }
        return .init(
            architecture: architecture,
            layers: (0..<layerCount).map {
                .init(layerIndex: $0, expertCount: expertCount, trainedTopK: topK)
            }
        )
    }
}

private enum StudioOptimizeError: Error, LocalizedError {
    case missingArtifact
    case invalidTopology

    var errorDescription: String? {
        switch self {
        case .missingArtifact: return "Select a source artifact first."
        case .invalidTopology: return "config.json does not contain a supported MoE topology."
        }
    }
}
