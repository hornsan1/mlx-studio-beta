import Foundation
import MLXStudioDomain
import MLXStudioEvaluation
import MLXStudioPersistence
import SwiftUI
import vMLXEngine
import vMLXTheme

enum StudioEvaluationMode: String, CaseIterable, Identifiable {
    case quickCompare = "Quick Compare"
    case blindAB = "Blind A/B"

    var id: String { rawValue }
}

struct StudioEvaluateScreen: View {
    @Environment(AppState.self) private var app
    @State private var model = StudioQuickCompareViewModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Evaluate")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textHigh)
                    Text(model.status)
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(model.hasError ? Theme.Colors.danger : Theme.Colors.textLow)
                }
                Spacer()
                Button { model.refresh() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .padding(Theme.Spacing.lg)
            Divider().background(Theme.Colors.border)

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                    compareCard(
                        model.presentationMode.rawValue,
                        subtitle: model.presentationMode == .blindAB
                            ? "Compare anonymous responses, persist your judgment, then reveal model identity."
                            : "Run identical messages and generation settings through two artifacts in a reproducible sequential order."
                    ) {
                        Picker("Evaluation mode", selection: $model.presentationMode) {
                            ForEach(StudioEvaluationMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.isRunning || model.hasUnrevealedBlindResult)
                        .accessibilityIdentifier("evaluate.mode")
                        HStack {
                            candidatePicker("Candidate A", selection: $model.firstArtifactID)
                            candidatePicker("Candidate B", selection: $model.secondArtifactID)
                        }
                        Text("Sequential fallback unloads and loads candidates one at a time, so comparison remains available when both models cannot fit in memory together.")
                            .font(Theme.Typography.captionHi)
                            .foregroundStyle(Theme.Colors.textLow)
                    }

                    compareCard(
                        "Prompt and settings",
                        subtitle: "Both candidates use the same logical template, prompt, seed, and sampling configuration."
                    ) {
                        TextField("Optional system prompt", text: $model.systemPrompt)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("evaluate.system-prompt")
                        TextEditor(text: $model.prompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 100)
                            .padding(6)
                            .background(Theme.Colors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                            .accessibilityIdentifier("evaluate.prompt")
                        HStack {
                            Stepper(
                                "Maximum tokens: \(model.maximumTokenCount)",
                                value: $model.maximumTokenCount,
                                in: 1...2_048,
                                step: 16
                            )
                            VStack(alignment: .leading) {
                                Text("Temperature: \(model.temperature, specifier: "%.2f")")
                                Slider(value: $model.temperature, in: 0...2, step: 0.05)
                            }
                            TextField("Seed", text: $model.seedText)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 110)
                                .accessibilityIdentifier("evaluate.seed")
                        }
                        Text("Template contract: \(QuickCompareRunner.templateIdentifier)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.Colors.textLow)
                    }

                    compareCard(
                        "Run",
                        subtitle: "The request, manifest, execution order, outputs, metrics, and errors are stored in models.sqlite3."
                    ) {
                        HStack {
                            Button(model.runButtonTitle) { model.run(engine: app.engine) }
                                .buttonStyle(.borderedProminent)
                                .disabled(!model.canRun || model.isRunning)
                                .accessibilityIdentifier("evaluate.run")
                            Button("Cancel") { model.cancel() }
                                .disabled(!model.isRunning)
                            if model.isRunning { ProgressView() }
                        }
                        if let manifest = model.outcome?.manifest {
                            Text(model.manifestSummary(manifest))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Theme.Colors.textLow)
                                .textSelection(.enabled)
                        }
                    }

                    if let outcome = model.outcome {
                        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                            if model.presentationMode == .blindAB {
                                if let assignment = model.judgment?.assignment {
                                    resultColumn(
                                        title: model.blindTitle(response: "Response A", artifactID: assignment.responseAArtifactID),
                                        artifactID: assignment.responseAArtifactID,
                                        outcome: outcome,
                                        showsMetrics: model.isRevealed,
                                        showsDetailedError: model.isRevealed
                                    )
                                    resultColumn(
                                        title: model.blindTitle(response: "Response B", artifactID: assignment.responseBArtifactID),
                                        artifactID: assignment.responseBArtifactID,
                                        outcome: outcome,
                                        showsMetrics: model.isRevealed,
                                        showsDetailedError: model.isRevealed
                                    )
                                } else {
                                    Text("Blind outputs are withheld because their anonymous assignment was not persisted.")
                                        .foregroundStyle(Theme.Colors.danger)
                                }
                            } else {
                                resultColumn(
                                    title: model.artifactName(model.firstArtifactID),
                                    artifactID: model.firstArtifactID,
                                    outcome: outcome
                                )
                                resultColumn(
                                    title: model.artifactName(model.secondArtifactID),
                                    artifactID: model.secondArtifactID,
                                    outcome: outcome
                                )
                            }
                        }
                    }

                    if model.presentationMode == .blindAB, model.judgment != nil {
                        blindJudgmentCard
                    }
                }
                .padding(Theme.Spacing.xl)
                .frame(maxWidth: 1_100)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.Colors.background)
        .task { model.refresh() }
    }

    private func candidatePicker(
        _ title: String,
        selection: Binding<ModelArtifactID?>
    ) -> some View {
        Picker(title, selection: selection) {
            Text("Select a model").tag(nil as ModelArtifactID?)
            ForEach(model.artifacts, id: \.id) { artifact in
                Text("\(artifact.name) — \(artifact.format.rawValue)")
                    .tag(artifact.id as ModelArtifactID?)
            }
        }
        .accessibilityIdentifier(title == "Candidate A" ? "evaluate.candidate-a" : "evaluate.candidate-b")
    }

    private func resultColumn(
        title: String,
        artifactID: ModelArtifactID?,
        outcome: QuickCompareOutcome,
        showsMetrics: Bool = true,
        showsDetailedError: Bool = true
    ) -> some View {
        let result = outcome.result.caseResults.first { $0.artifactID == artifactID }
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Colors.textHigh)
            if let error = result?.errorDescription {
                Text(showsDetailedError
                    ? error : "This anonymous response failed to generate; identifying details remain hidden.")
                    .foregroundStyle(Theme.Colors.danger)
            } else {
                Text(result?.generationResult?.text ?? "No output")
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
                    .textSelection(.enabled)
                if showsMetrics, let metrics = result?.generationResult?.metrics {
                    Text("\(metrics.generatedTokenCount) tokens · \(metrics.tokensPerSecond.map { String(format: "%.2f tok/s", $0) } ?? "rate unavailable") · \(metrics.totalDurationSeconds.map { String(format: "%.2fs", $0) } ?? "duration unavailable")")
                        .font(Theme.Typography.captionHi)
                        .foregroundStyle(Theme.Colors.textLow)
                }
            }
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

    private var blindJudgmentCard: some View {
        compareCard(
            "Blind judgment",
            subtitle: model.isRevealed
                ? "Identity and runtime metrics are revealed after the persisted judgment."
                : "Model identity, execution order, and runtime metrics remain hidden until you judge."
        ) {
            HStack {
                Button("Prefer Response A") { model.choose(.responseA) }
                    .tint(model.judgment?.choice == .responseA ? Theme.Colors.accent : nil)
                Button("Prefer Response B") { model.choose(.responseB) }
                    .tint(model.judgment?.choice == .responseB ? Theme.Colors.accent : nil)
                Button("Tie") { model.choose(.tie) }
                    .tint(model.judgment?.choice == .tie ? Theme.Colors.accent : nil)
            }
            .disabled(model.isRevealed || !model.canJudge)
            Button("Reveal identities") { model.reveal() }
                .buttonStyle(.borderedProminent)
                .disabled(model.judgment?.choice == nil || model.isRevealed)
                .accessibilityIdentifier("evaluate.reveal")
            if model.isRevealed, let summary = model.revealSummary {
                Text(summary)
                    .font(Theme.Typography.captionHi)
                    .foregroundStyle(Theme.Colors.textHigh)
                    .textSelection(.enabled)
            }
        }
    }

    private func compareCard<Content: View>(
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

@MainActor
@Observable
final class StudioQuickCompareViewModel {
    var artifacts: [ModelArtifact] = []
    var firstArtifactID: ModelArtifactID?
    var secondArtifactID: ModelArtifactID?
    var presentationMode: StudioEvaluationMode = .quickCompare {
        didSet {
            guard presentationMode != oldValue, !isRunning else { return }
            outcome = nil
            judgment = nil
            status = artifacts.count >= 2 ? "Ready" : status
        }
    }
    var systemPrompt = ""
    var prompt = "Reply with one concise sentence."
    var maximumTokenCount = 128
    var temperature = 0.0
    var seedText = "42"
    var status = "Loading canonical artifacts…"
    var hasError = false
    var isRunning = false
    var outcome: QuickCompareOutcome?
    var judgment: HumanJudgment?

    private var artifactRepository: ModelArtifactRepository?
    private var evaluationRepository: EvaluationRepository?
    private var activeTask: Task<Void, Never>?

    var canRun: Bool {
        firstArtifactID != nil
            && secondArtifactID != nil
            && firstArtifactID != secondArtifactID
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && UInt64(seedText) != nil
    }

    var isRevealed: Bool { judgment?.revealedAt != nil }
    var runButtonTitle: String {
        presentationMode == .blindAB ? "Run Blind A/B" : "Run Quick Compare"
    }
    var canJudge: Bool { outcome?.result.status == .completed && judgment != nil }
    var hasUnrevealedBlindResult: Bool {
        presentationMode == .blindAB && canJudge && !isRevealed
    }

    var revealSummary: String? {
        guard let judgment, judgment.revealedAt != nil else { return nil }
        let a = artifactName(judgment.assignment.responseAArtifactID)
        let b = artifactName(judgment.assignment.responseBArtifactID)
        let choice: String
        switch judgment.choice {
        case .responseA: choice = "Preferred: Response A (\(a))"
        case .responseB: choice = "Preferred: Response B (\(b))"
        case .tie: choice = "Judgment: Tie"
        case nil: return nil
        }
        return "Response A: \(a) · Response B: \(b) · \(choice)"
    }

    init() {
        do {
            artifactRepository = try ModelArtifactRepository()
            evaluationRepository = try EvaluationRepository()
        } catch {
            artifactRepository = nil
            evaluationRepository = nil
            status = "Evaluation storage unavailable: \(error.localizedDescription)"
            hasError = true
        }
    }

    func refresh() {
        guard let artifactRepository else { return }
        do {
            let indexed = try artifactRepository.indexedModels()
            let indexedByLegacyID = Dictionary(uniqueKeysWithValues: indexed.map {
                ($0.legacyModelID, $0)
            })
            artifacts = try artifactRepository.artifacts().filter { artifact in
                guard Self.isSelectableArtifact(artifact) else { return false }
                guard let legacyID = artifact.legacyModelID else { return true }
                guard let record = indexedByLegacyID[legacyID] else { return true }
                return record.modality.lowercased() != "image"
                    && !record.family.lowercased().contains("whisper")
            }.sorted { lhs, rhs in
                let lhsSize = lhs.legacyModelID.flatMap { indexedByLegacyID[$0]?.totalSizeBytes }
                    ?? Int64.max
                let rhsSize = rhs.legacyModelID.flatMap { indexedByLegacyID[$0]?.totalSizeBytes }
                    ?? Int64.max
                return lhsSize == rhsSize
                    ? lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                    : lhsSize < rhsSize
            }
            if !artifacts.contains(where: { $0.id == firstArtifactID }) {
                firstArtifactID = artifacts.first?.id
            }
            if !artifacts.contains(where: { $0.id == secondArtifactID })
                || secondArtifactID == firstArtifactID
            {
                secondArtifactID = artifacts.dropFirst().first?.id
            }
            status = artifacts.count >= 2
                ? "Ready" : "Quick Compare needs two local text-model artifacts."
            hasError = false
        } catch {
            fail(error)
        }
    }

    func run(engine: Engine) {
        guard activeTask == nil,
              let evaluationRepository,
              let first = artifacts.first(where: { $0.id == firstArtifactID }),
              let second = artifacts.first(where: { $0.id == secondArtifactID }),
              let seed = UInt64(seedText)
        else { return }
        do {
            let configuration = GenerationConfiguration(
                maximumTokenCount: maximumTokenCount,
                temperature: temperature,
                topP: 1,
                seed: seed
            )
            let proposedSuite = try QuickCompareSuiteFactory.singlePrompt(
                systemPrompt: systemPrompt,
                prompt: prompt,
                generationConfiguration: configuration
            )
            let suite = try QuickCompareSuiteFactory.resolvingPersistedSuite(
                proposedSuite,
                repository: evaluationRepository
            )
            let pendingJudgment: HumanJudgment?
            let candidates: [EvaluationCandidate]
            if presentationMode == .blindAB {
                let assignmentSeed = UInt64.random(in: UInt64.min...UInt64.max)
                let assignments = try BlindAssignmentPlanner.assignments(
                    candidateIDs: [first.id, second.id],
                    cases: suite.cases,
                    seed: assignmentSeed
                )
                guard let evaluationCase = suite.cases.first,
                      let assignment = assignments[evaluationCase.id]
                else { return }
                pendingJudgment = HumanJudgment(
                    runID: EvaluationRunID(),
                    caseID: evaluationCase.id,
                    assignment: assignment
                )
                candidates = [first, second].map { artifact in
                    EvaluationCandidate(
                        artifactID: artifact.id,
                        blindLabel: assignment.responseAArtifactID == artifact.id
                            ? "Response A" : "Response B",
                        artifactHash: artifact.contentHash
                    )
                }
            } else {
                pendingJudgment = nil
                candidates = [
                    .init(
                        artifactID: first.id,
                        blindLabel: "Candidate A: \(first.name)",
                        artifactHash: first.contentHash
                    ),
                    .init(
                        artifactID: second.id,
                        blindLabel: "Candidate B: \(second.name)",
                        artifactHash: second.contentHash
                    ),
                ]
            }
            let runID = pendingJudgment?.runID ?? EvaluationRunID()
            let request = EvaluationRunRequest(
                id: runID,
                suite: suite,
                candidates: candidates,
                runtimeVersion: Self.runtimeVersion,
                kernelVersion: "mlx-0.31.1",
                executionOrder: [first.id, second.id]
            )
            let runner = QuickCompareRunner(
                provider: VMLXInferenceProvider(engine: engine),
                repository: evaluationRepository
            )
            isRunning = true
            hasError = false
            outcome = nil
            judgment = nil
            status = presentationMode == .blindAB
                ? "Generating two anonymous responses sequentially…"
                : "Running Candidate A, then Candidate B…"
            activeTask = Task { [weak self] in
                do {
                    let result = try await runner.run(request)
                    if let pendingJudgment {
                        try evaluationRepository.saveHumanJudgment(pendingJudgment)
                        self?.judgment = pendingJudgment
                    }
                    self?.outcome = result
                    self?.status = result.result.status == .completed
                        ? (pendingJudgment == nil
                            ? "Quick Compare complete and persisted."
                            : "Anonymous responses ready. Judge before revealing identity.")
                        : "Comparison completed with candidate errors; partial results were persisted."
                    self?.hasError = result.result.status == .failed
                } catch is CancellationError {
                    self?.status = "Quick Compare cancelled; durable run state was preserved."
                } catch {
                    self?.fail(error)
                }
                self?.isRunning = false
                self?.activeTask = nil
            }
        } catch {
            fail(error)
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    func choose(_ choice: BlindResponseChoice) {
        guard canJudge, let judgment, let evaluationRepository else { return }
        do {
            let updated = BlindJudgmentWorkflow.choosing(choice, in: judgment)
            try evaluationRepository.saveHumanJudgment(updated)
            self.judgment = updated
            status = "Judgment persisted. Identity remains hidden until reveal."
            hasError = false
        } catch {
            fail(error)
        }
    }

    func reveal() {
        guard let judgment, let evaluationRepository else { return }
        do {
            let revealed = try BlindJudgmentWorkflow.revealing(judgment)
            try evaluationRepository.saveHumanJudgment(revealed)
            self.judgment = revealed
            status = "Judgment and identity reveal persisted."
            hasError = false
        } catch {
            fail(error)
        }
    }

    func artifactName(_ artifactID: ModelArtifactID?) -> String {
        artifacts.first { $0.id == artifactID }?.name ?? "Candidate"
    }

    func blindTitle(response: String, artifactID: ModelArtifactID) -> String {
        isRevealed ? "\(response) — \(artifactName(artifactID))" : response
    }

    func manifestSummary(_ manifest: EvaluationRunManifest) -> String {
        if presentationMode == .blindAB && !isRevealed {
            return "Manifest \(manifest.manifestHash) · randomized assignment persisted · identity hidden"
        }
        return "Manifest \(manifest.manifestHash) · order \(manifest.executionOrder.map(\.rawValue).joined(separator: " → "))"
    }

    static func isSelectableArtifact(_ artifact: ModelArtifact) -> Bool {
        guard artifact.state == .ready || artifact.state == .discovered else { return false }
        return FileManager.default.fileExists(atPath: artifact.localURL.path)
    }

    private static var runtimeVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let version = [short, build].compactMap { $0 }.joined(separator: "+")
        return version.isEmpty ? "vmlx-app-development" : version
    }

    private func fail(_ error: Error) {
        status = error is ModelStoreMigrationError
            ? String(describing: error) : error.localizedDescription
        hasError = true
    }
}
