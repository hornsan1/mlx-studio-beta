import Foundation
import MLXStudioDomain
import MLXStudioEvaluation
import MLXStudioPersistence
import SwiftUI
import UniformTypeIdentifiers
import vMLXEngine
import vMLXTheme

enum StudioEvaluationMode: String, CaseIterable, Identifiable {
    case quickCompare = "Quick Compare"
    case blindAB = "Blind A/B"
    case promptSuite = "Prompt Suite"
    case lossAttribution = "Loss Attribution"

    var id: String { rawValue }
}

struct StudioEvaluateScreen: View {
    @Environment(AppState.self) private var app
    @State private var model = StudioEvaluateViewModel()
    @State private var importsSuite = false
    @State private var exportsSuite = false

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
                        subtitle: model.modeSubtitle
                    ) {
                        Picker("Evaluation mode", selection: $model.presentationMode) {
                            ForEach(StudioEvaluationMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .disabled(model.isRunning || model.hasUnrevealedBlindResult)
                        .accessibilityIdentifier("evaluate.mode")
                        if model.presentationMode == .promptSuite {
                            candidatePicker("Candidate", selection: $model.firstArtifactID)
                        } else if model.presentationMode == .lossAttribution {
                            VStack(spacing: Theme.Spacing.sm) {
                                HStack {
                                    candidatePicker(
                                        "A — Base, original precision",
                                        selection: $model.firstArtifactID,
                                        emptyLabel: "Skip variant"
                                    )
                                    candidatePicker(
                                        "B — Base, quantized",
                                        selection: $model.secondArtifactID,
                                        emptyLabel: "Skip variant"
                                    )
                                }
                                HStack {
                                    candidatePicker(
                                        "C — Pruned, original precision",
                                        selection: $model.thirdArtifactID,
                                        emptyLabel: "Skip variant"
                                    )
                                    candidatePicker(
                                        "D — Pruned and quantized",
                                        selection: $model.fourthArtifactID,
                                        emptyLabel: "Skip variant"
                                    )
                                }
                                Text(model.lossPlanSummary)
                                    .font(Theme.Typography.captionHi)
                                    .foregroundStyle(model.lossSelectionIssue == nil
                                        ? Theme.Colors.textLow : Theme.Colors.danger)
                            }
                        } else {
                            HStack {
                                candidatePicker("Candidate A", selection: $model.firstArtifactID)
                                candidatePicker("Candidate B", selection: $model.secondArtifactID)
                            }
                        }
                        Text(model.executionNote)
                            .font(Theme.Typography.captionHi)
                            .foregroundStyle(Theme.Colors.textLow)
                    }

                    compareCard(
                        model.usesPromptSuite ? "Suite and settings" : "Prompt and settings",
                        subtitle: model.usesPromptSuite
                            ? "Import a versioned JSONL suite or build an unscored suite from one custom prompt per line."
                            : "Both candidates use the same logical template, prompt, seed, and sampling configuration."
                    ) {
                        if model.usesPromptSuite {
                            HStack {
                                Button("Import JSONL") { importsSuite = true }
                                    .disabled(model.isRunning)
                                    .accessibilityIdentifier("evaluate.suite-import")
                                Button("Export JSONL") { exportsSuite = true }
                                    .disabled(model.promptSuite == nil || model.isRunning)
                                    .accessibilityIdentifier("evaluate.suite-export")
                                if let summary = model.promptSuiteSummary {
                                    Text(summary)
                                        .font(Theme.Typography.captionHi)
                                        .foregroundStyle(Theme.Colors.textLow)
                                }
                            }
                            TextEditor(text: $model.customPromptsText)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 110)
                                .padding(6)
                                .background(Theme.Colors.surface)
                                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                                .disabled(model.isRunning)
                                .accessibilityIdentifier("evaluate.suite-custom-prompts")
                            Button("Build custom suite") { model.buildCustomSuite() }
                                .disabled(model.customPromptsText
                                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || model.isRunning)
                                .accessibilityIdentifier("evaluate.suite-build")
                        } else {
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
                        }
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
                        Text("Template contract: \(model.templateIdentifier)")
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
                        if let manifest = model.activeManifest {
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

                    if let outcome = model.promptSuiteOutcome {
                        promptSuiteResults(outcome)
                    }

                    if let report = model.lossAttributionReport {
                        lossAttributionResults(report)
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
        .fileImporter(
            isPresented: $importsSuite,
            allowedContentTypes: [.json, .plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            model.importSuite(result)
        }
        .fileExporter(
            isPresented: $exportsSuite,
            document: EvaluationSuiteDocument(data: model.exportData ?? Data()),
            contentType: .plainText,
            defaultFilename: model.exportFilename
        ) { result in
            model.finishExport(result)
        }
    }

    private func candidatePicker(
        _ title: String,
        selection: Binding<ModelArtifactID?>,
        emptyLabel: String = "Select a model"
    ) -> some View {
        let identifier: String
        if title == "Candidate B" || title.hasPrefix("B —") {
            identifier = "evaluate.candidate-b"
        } else if title.hasPrefix("C —") {
            identifier = "evaluate.candidate-c"
        } else if title.hasPrefix("D —") {
            identifier = "evaluate.candidate-d"
        } else {
            identifier = "evaluate.candidate-a"
        }
        return Picker(title, selection: selection) {
            Text(emptyLabel).tag(nil as ModelArtifactID?)
            ForEach(model.artifacts, id: \.id) { artifact in
                Text("\(artifact.name) — \(artifact.format.rawValue)")
                    .tag(artifact.id as ModelArtifactID?)
            }
        }
        .disabled(model.isRunning)
        .accessibilityIdentifier(identifier)
    }

    private func promptSuiteResults(_ outcome: PromptSuiteOutcome) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ForEach(outcome.scorecards, id: \.artifactID) { scorecard in
                compareCard(
                    "Scorecard — \(model.artifactName(scorecard.artifactID))",
                    subtitle: model.scorecardSummary(scorecard)
                ) {
                    ForEach(scorecard.domains, id: \.domain) { domain in
                        Text(model.domainScoreSummary(domain))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Theme.Colors.textLow)
                    }
                }
            }
            compareCard(
                "Case results",
                subtitle: "Every completed case is durable and will be skipped by Resume."
            ) {
                ForEach(Array(outcome.result.caseResults.enumerated()), id: \.offset) { _, result in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(outcome.scorecards.count > 1
                            ? "\(model.caseName(result.caseID)) — \(model.artifactName(result.artifactID))"
                            : model.caseName(result.caseID))
                            .font(.system(size: 13, weight: .semibold))
                        if let error = result.errorDescription {
                            Text(error).foregroundStyle(Theme.Colors.danger)
                        } else {
                            Text(result.generationResult?.text ?? "No output")
                                .textSelection(.enabled)
                            Text(model.caseScoreSummary(result))
                                .font(Theme.Typography.captionHi)
                                .foregroundStyle(Theme.Colors.textLow)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }

    private func lossAttributionResults(_ report: LossAttributionReport) -> some View {
        compareCard(
            "Loss Attribution",
            subtitle: report.plan.usesFullMatrix
                ? "Full A/B/C/D matrix measured."
                : "Partial matrix. Missing variants remain explicit and are not estimated."
        ) {
            ForEach(LossAttributionVariant.allCases, id: \.self) { variant in
                let assignment = report.plan.artifacts.first { $0.variant == variant }
                Text("\(variant.code) · \(variant.displayName): \(assignment.map { model.artifactName($0.artifactID) } ?? "missing")")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(assignment == nil ? Theme.Colors.danger : Theme.Colors.textLow)
            }
            Divider().background(Theme.Colors.border)
            ForEach(report.comparisons, id: \.kind) { comparison in
                VStack(alignment: .leading, spacing: 3) {
                    Text(comparison.kind.displayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(model.lossComparisonSummary(comparison))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(comparison.state == .measured
                            ? Theme.Colors.textLow : Theme.Colors.danger)
                }
                .padding(.vertical, 3)
            }
            Text("Quality interaction: \(model.percent(report.qualityInteractionEffect))")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.Colors.textHigh)
        }
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
                Button("Both failed") { model.choose(.bothFailed) }
                    .tint(model.judgment?.choice == .bothFailed ? Theme.Colors.accent : nil)
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
final class StudioEvaluateViewModel {
    var artifacts: [ModelArtifact] = []
    var artifactSizeBytes: [ModelArtifactID: Int64] = [:]
    var firstArtifactID: ModelArtifactID?
    var secondArtifactID: ModelArtifactID?
    var thirdArtifactID: ModelArtifactID?
    var fourthArtifactID: ModelArtifactID?
    var presentationMode: StudioEvaluationMode = .quickCompare {
        didSet {
            guard presentationMode != oldValue, !isRunning else { return }
            outcome = nil
            promptSuiteOutcome = nil
            lossAttributionReport = nil
            judgment = nil
            status = usesPromptSuite
                ? (artifacts.isEmpty ? "Evaluation needs local text-model artifacts." : "Ready")
                : (artifacts.count >= 2 ? "Ready" : status)
            if presentationMode == .promptSuite { discoverInterruptedPromptSuite() }
            if presentationMode == .lossAttribution {
                populateLossSelections()
                discoverInterruptedLossAttribution()
            }
        }
    }
    var systemPrompt = ""
    var prompt = "Reply with one concise sentence."
    var customPromptsText = "Summarize why deterministic evaluation matters.\nWrite a one-line Swift greeting."
    var maximumTokenCount = 128
    var temperature = 0.0
    var seedText = "42"
    var status = "Loading canonical artifacts…"
    var hasError = false
    var isRunning = false
    var outcome: QuickCompareOutcome?
    var promptSuiteOutcome: PromptSuiteOutcome?
    var lossAttributionReport: LossAttributionReport?
    var promptSuite: EvaluationSuite?
    var judgment: HumanJudgment?
    var resumableRequest: EvaluationRunRequest?

    private var artifactRepository: ModelArtifactRepository?
    private var evaluationRepository: EvaluationRepository?
    private var activeTask: Task<Void, Never>?

    var canRun: Bool {
        if presentationMode == .lossAttribution {
            guard let plan = currentLossPlan else { return false }
            return promptSuite?.cases.isEmpty == false
                && selectedLossArtifactIDs.count >= 2
                && lossSelectionIssue == nil
                && plan.artifacts.count == selectedLossArtifactIDs.count
        }
        guard firstArtifactID != nil else { return false }
        if presentationMode == .promptSuite { return promptSuite?.cases.isEmpty == false }
        return UInt64(seedText) != nil
            && secondArtifactID != nil
            && firstArtifactID != secondArtifactID
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isRevealed: Bool { judgment?.revealedAt != nil }
    var runButtonTitle: String {
        switch presentationMode {
        case .quickCompare: "Run Quick Compare"
        case .blindAB: "Run Blind A/B"
        case .promptSuite: hasMatchingResume ? "Resume Prompt Suite" : "Run Prompt Suite"
        case .lossAttribution:
            hasMatchingResume ? "Resume Loss Attribution" : "Run Loss Attribution"
        }
    }
    var canJudge: Bool { outcome?.result.status == .completed && judgment != nil }
    var hasUnrevealedBlindResult: Bool {
        presentationMode == .blindAB && canJudge && !isRevealed
    }

    var hasMatchingResume: Bool {
        guard let resumableRequest, let promptSuite else { return false }
        return resumableRequest.suite.id == promptSuite.id
            && resumableRequest.candidates.map(\.artifactID) == selectedEvaluationArtifactIDs
    }

    var modeSubtitle: String {
        switch presentationMode {
        case .quickCompare:
            "Run identical messages and generation settings through two artifacts in a reproducible sequential order."
        case .blindAB:
            "Compare anonymous responses, persist your judgment, then reveal model identity."
        case .promptSuite:
            "Run a versioned multi-case suite with durable per-case progress, resumability, and domain scorecards."
        case .lossAttribution:
            "Measure pruning, quantization, interaction, and total deployment effects across an optional four-variant matrix."
        }
    }

    var executionNote: String {
        usesPromptSuite
            ? "Each case is committed before the next starts. Resume skips durable case results after cancellation or restart."
            : "Sequential fallback unloads and loads candidates one at a time, so comparison remains available when both models cannot fit in memory together."
    }

    var templateIdentifier: String {
        usesPromptSuite
            ? PromptSuiteRunner.templateIdentifier : QuickCompareRunner.templateIdentifier
    }

    var activeManifest: EvaluationRunManifest? {
        promptSuiteOutcome?.manifest ?? outcome?.manifest
    }

    var usesPromptSuite: Bool {
        presentationMode == .promptSuite || presentationMode == .lossAttribution
    }

    var selectedLossArtifactIDs: [ModelArtifactID] {
        [firstArtifactID, secondArtifactID, thirdArtifactID, fourthArtifactID]
            .compactMap { $0 }
    }

    var selectedEvaluationArtifactIDs: [ModelArtifactID] {
        presentationMode == .lossAttribution
            ? selectedLossArtifactIDs : firstArtifactID.map { [$0] } ?? []
    }

    var lossSelectionIssue: String? {
        let ids = selectedLossArtifactIDs
        guard Set(ids).count == ids.count else {
            return "Each selected variant must use a distinct artifact."
        }
        guard ids.count >= 2 else {
            return "Select at least two variants; the full A/B/C/D matrix is recommended."
        }
        return nil
    }

    var currentLossPlan: LossAttributionExperimentPlan? {
        try? LossAttributionPlanner.plan(artifacts: lossArtifacts())
    }

    var lossPlanSummary: String {
        if let lossSelectionIssue { return lossSelectionIssue }
        guard let plan = currentLossPlan else { return "Select artifact variants." }
        if plan.usesFullMatrix { return "Full A/B/C/D matrix selected (recommended)." }
        return "Partial matrix selected · missing \(plan.missingVariants.map(\.code).joined(separator: ", "))."
    }

    var promptSuiteSummary: String? {
        guard let promptSuite else { return nil }
        return "\(promptSuite.name) · \(promptSuite.cases.count) cases · \(promptSuite.suiteHash.prefix(12))"
    }

    var exportData: Data? { try? promptSuite.map(EvaluationJSONL.encode) }
    var exportFilename: String {
        let name = promptSuite?.name ?? "evaluation-suite"
        let safe = name.lowercased().map { character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(safe).replacingOccurrences(of: "--", with: "-") + ".jsonl"
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
        case .bothFailed: choice = "Judgment: Both failed"
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
            artifactSizeBytes = Dictionary(uniqueKeysWithValues: artifacts.compactMap { artifact in
                guard let legacyID = artifact.legacyModelID,
                      let size = indexedByLegacyID[legacyID]?.totalSizeBytes
                else { return nil }
                return (artifact.id, size)
            })
            if !artifacts.contains(where: { $0.id == firstArtifactID }) {
                firstArtifactID = artifacts.first?.id
            }
            if !artifacts.contains(where: { $0.id == secondArtifactID })
                || secondArtifactID == firstArtifactID
            {
                secondArtifactID = artifacts.dropFirst().first?.id
            }
            if !artifacts.contains(where: { $0.id == thirdArtifactID }) {
                thirdArtifactID = nil
            }
            if !artifacts.contains(where: { $0.id == fourthArtifactID }) {
                fourthArtifactID = nil
            }
            status = usesPromptSuite
                ? (artifacts.isEmpty
                    ? "Evaluation needs local text-model artifacts." : "Ready")
                : (artifacts.count >= 2
                    ? "Ready" : "Quick Compare needs two local text-model artifacts.")
            hasError = false
            if presentationMode == .promptSuite { discoverInterruptedPromptSuite() }
            if presentationMode == .lossAttribution { discoverInterruptedLossAttribution() }
        } catch {
            fail(error)
        }
    }

    func run(engine: Engine) {
        if presentationMode == .promptSuite {
            runPromptSuite(engine: engine)
            return
        }
        if presentationMode == .lossAttribution {
            runLossAttribution(engine: engine)
            return
        }
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
            promptSuiteOutcome = nil
            lossAttributionReport = nil
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

    private func runPromptSuite(engine: Engine) {
        guard activeTask == nil,
              let evaluationRepository,
              let suite = promptSuite,
              let artifact = artifacts.first(where: { $0.id == firstArtifactID })
        else { return }
        do {
            let request: EvaluationRunRequest
            if let resumableRequest,
               resumableRequest.suite.id == suite.id,
               resumableRequest.candidates.map(\.artifactID) == [artifact.id]
            {
                request = resumableRequest
            } else {
                let persistedSuite = try PromptSuiteFactory.resolvingPersistedSuite(
                    suite,
                    repository: evaluationRepository
                )
                promptSuite = persistedSuite
                request = EvaluationRunRequest(
                    suite: persistedSuite,
                    candidates: [.init(
                        artifactID: artifact.id,
                        blindLabel: artifact.name,
                        artifactHash: artifact.contentHash
                    )],
                    runtimeVersion: Self.runtimeVersion,
                    kernelVersion: "mlx-0.31.1",
                    executionOrder: [artifact.id]
                )
            }
            let runner = try PromptSuiteRunner(
                provider: VMLXInferenceProvider(engine: engine),
                repository: evaluationRepository
            )
            isRunning = true
            hasError = false
            outcome = nil
            promptSuiteOutcome = nil
            lossAttributionReport = nil
            judgment = nil
            let completed = (try? evaluationRepository.caseResults(runID: request.id).count) ?? 0
            status = completed > 0
                ? "Resuming after \(completed) durable case results…"
                : "Running \(request.suite.cases.count) prompt-suite cases sequentially…"
            activeTask = Task { [weak self] in
                do {
                    let result = try await runner.run(request)
                    self?.promptSuiteOutcome = result
                    self?.resumableRequest = nil
                    self?.status = result.result.status == .completed
                        ? "Prompt suite complete; results and scorecards are durable."
                        : "Prompt suite finished with case errors; partial results are durable."
                    self?.hasError = result.result.status == .failed
                } catch is CancellationError {
                    self?.resumableRequest = request
                    self?.status = "Prompt suite cancelled; use Resume Prompt Suite to continue durable work."
                } catch {
                    self?.resumableRequest = request
                    self?.fail(error)
                }
                self?.isRunning = false
                self?.activeTask = nil
            }
        } catch {
            fail(error)
        }
    }

    private func runLossAttribution(engine: Engine) {
        guard activeTask == nil,
              let evaluationRepository,
              let suite = promptSuite
        else { return }
        do {
            let plan = try LossAttributionPlanner.plan(artifacts: lossArtifacts())
            guard plan.artifacts.count >= 2 else { return }
            let request: EvaluationRunRequest
            if let resumableRequest,
               resumableRequest.suite.id == suite.id,
               resumableRequest.candidates.map(\.artifactID) == plan.artifacts.map(\.artifactID)
            {
                request = resumableRequest
            } else {
                let persistedSuite = try PromptSuiteFactory.resolvingPersistedSuite(
                    suite,
                    repository: evaluationRepository
                )
                promptSuite = persistedSuite
                request = EvaluationRunRequest(
                    suite: persistedSuite,
                    candidates: LossAttributionPlanner.candidates(for: plan),
                    runtimeVersion: Self.runtimeVersion,
                    kernelVersion: "mlx-0.31.1",
                    executionOrder: plan.artifacts.map(\.artifactID)
                )
            }
            let runner = try PromptSuiteRunner(
                provider: VMLXInferenceProvider(engine: engine),
                repository: evaluationRepository
            )
            isRunning = true
            hasError = false
            outcome = nil
            promptSuiteOutcome = nil
            lossAttributionReport = nil
            judgment = nil
            let completed = (try? evaluationRepository.caseResults(runID: request.id).count) ?? 0
            status = completed > 0
                ? "Resuming Loss Attribution after \(completed) durable case results…"
                : "Running \(plan.artifacts.count) variants sequentially across \(request.suite.cases.count) cases…"
            activeTask = Task { [weak self] in
                do {
                    let result = try await runner.run(request)
                    let observations = LossAttributionObservationBuilder.build(
                        plan: plan,
                        outcome: result,
                        artifactSizeBytes: self?.artifactSizeBytes ?? [:]
                    )
                    let report = try LossAttributionReportBuilder.build(
                        runID: request.id,
                        plan: plan,
                        observations: observations,
                        judgments: try evaluationRepository.humanJudgments()
                    )
                    self?.promptSuiteOutcome = result
                    self?.lossAttributionReport = report
                    self?.resumableRequest = nil
                    self?.status = result.result.status == .completed
                        ? "Loss Attribution complete; quality, performance, and preference evidence is reported."
                        : "Loss Attribution finished with case errors; available measurements remain explicit."
                    self?.hasError = result.result.status == .failed
                } catch is CancellationError {
                    self?.resumableRequest = request
                    self?.status = "Loss Attribution cancelled; use Resume Loss Attribution to continue durable work."
                } catch {
                    self?.resumableRequest = request
                    self?.fail(error)
                }
                self?.isRunning = false
                self?.activeTask = nil
            }
        } catch {
            fail(error)
        }
    }

    private func discoverInterruptedPromptSuite() {
        guard let evaluationRepository else { return }
        do {
            guard let stored = try evaluationRepository.runs().first(where: {
                [.pending, .running, .cancelled].contains($0.status)
                    && $0.request.candidates.count == 1
            }) else {
                resumableRequest = nil
                return
            }
            resumableRequest = stored.request
            promptSuite = stored.request.suite
            let candidateID = stored.request.candidates[0].artifactID
            if artifacts.contains(where: { $0.id == candidateID }) {
                firstArtifactID = candidateID
            }
            let completed = try evaluationRepository.caseResults(runID: stored.request.id).count
            status = "Interrupted prompt suite found with \(completed) durable case results."
            hasError = false
        } catch {
            fail(error)
        }
    }

    private func discoverInterruptedLossAttribution() {
        guard let evaluationRepository else { return }
        do {
            guard let stored = try evaluationRepository.runs().first(where: { stored in
                [.pending, .running, .cancelled].contains(stored.status)
                    && stored.request.candidates.count >= 2
                    && stored.request.candidates.allSatisfy {
                        lossVariant(from: $0.blindLabel) != nil
                    }
            }) else {
                resumableRequest = nil
                return
            }
            firstArtifactID = nil
            secondArtifactID = nil
            thirdArtifactID = nil
            fourthArtifactID = nil
            for candidate in stored.request.candidates {
                guard let variant = lossVariant(from: candidate.blindLabel) else { continue }
                setLossArtifact(candidate.artifactID, for: variant)
            }
            resumableRequest = stored.request
            promptSuite = stored.request.suite
            let completed = try evaluationRepository.caseResults(runID: stored.request.id).count
            status = "Interrupted Loss Attribution run found with \(completed) durable case results."
            hasError = false
        } catch {
            fail(error)
        }
    }

    private func populateLossSelections() {
        if firstArtifactID == nil { firstArtifactID = artifacts.first?.id }
        var selected = Set(firstArtifactID.map { [$0] } ?? [])
        if secondArtifactID == nil || secondArtifactID == firstArtifactID {
            secondArtifactID = artifacts.first { !selected.contains($0.id) }?.id
        }
        if let secondArtifactID { selected.insert(secondArtifactID) }
        if thirdArtifactID == nil {
            thirdArtifactID = artifacts.first { !selected.contains($0.id) }?.id
        } else if let thirdArtifactID {
            selected.insert(thirdArtifactID)
        }
        if let thirdArtifactID { selected.insert(thirdArtifactID) }
        if fourthArtifactID == nil {
            fourthArtifactID = artifacts.first { !selected.contains($0.id) }?.id
        }
    }

    private func lossArtifacts() -> [LossAttributionArtifact] {
        let selections: [(LossAttributionVariant, ModelArtifactID?)] = [
            (.baseOriginalPrecision, firstArtifactID),
            (.baseQuantized, secondArtifactID),
            (.prunedOriginalPrecision, thirdArtifactID),
            (.prunedQuantized, fourthArtifactID),
        ]
        return selections.compactMap { variant, id in
            guard let id, let artifact = artifacts.first(where: { $0.id == id }) else {
                return nil
            }
            return LossAttributionArtifact(
                variant: variant,
                artifactID: id,
                artifactHash: artifact.contentHash
            )
        }
    }

    private func lossVariant(from label: String) -> LossAttributionVariant? {
        LossAttributionVariant.allCases.first { label.hasPrefix("\($0.code) —") }
    }

    private func setLossArtifact(
        _ artifactID: ModelArtifactID,
        for variant: LossAttributionVariant
    ) {
        switch variant {
        case .baseOriginalPrecision: firstArtifactID = artifactID
        case .baseQuantized: secondArtifactID = artifactID
        case .prunedOriginalPrecision: thirdArtifactID = artifactID
        case .prunedQuantized: fourthArtifactID = artifactID
        }
    }

    func buildCustomSuite() {
        guard let seed = UInt64(seedText) else { return }
        do {
            let proposed = try PromptSuiteFactory.customPrompts(
                prompts: customPromptsText.components(separatedBy: .newlines),
                generationConfiguration: GenerationConfiguration(
                    maximumTokenCount: maximumTokenCount,
                    temperature: temperature,
                    topP: 1,
                    seed: seed
                )
            )
            promptSuite = try evaluationRepository.map {
                try PromptSuiteFactory.resolvingPersistedSuite(proposed, repository: $0)
            } ?? proposed
            resumableRequest = nil
            promptSuiteOutcome = nil
            lossAttributionReport = nil
            status = "Custom suite ready with \(proposed.cases.count) prompts."
            hasError = false
        } catch {
            fail(error)
        }
    }

    func importSuite(_ result: Result<[URL], Error>) {
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let imported = try PromptSuiteImport.decode(
                Data(contentsOf: url),
                name: url.deletingPathExtension().lastPathComponent
            )
            promptSuite = try evaluationRepository.map {
                try PromptSuiteFactory.resolvingPersistedSuite(imported, repository: $0)
            } ?? imported
            resumableRequest = nil
            promptSuiteOutcome = nil
            lossAttributionReport = nil
            status = "Imported \(imported.name) with \(imported.cases.count) cases."
            hasError = false
        } catch {
            fail(error)
        }
    }

    func finishExport(_ result: Result<URL, Error>) {
        switch result {
        case .success:
            status = "Prompt suite exported as versioned JSONL."
            hasError = false
        case .failure(let error):
            fail(error)
        }
    }

    func scorecardSummary(_ scorecard: EvaluationScorecard) -> String {
        let score = scorecard.overall.weightedScore.map {
            String(format: "%.1f%%", $0 * 100)
        } ?? "unscored"
        return "Weighted score \(score) · \(scorecard.overall.scoredCaseCount) scored · \(scorecard.overall.unscoredCaseCount) unscored · \(scorecard.overall.errorCaseCount) errors · \(scorecard.generatedTokenCount) tokens"
    }

    func domainScoreSummary(_ score: EvaluationDomainScore) -> String {
        let value = score.weightedScore.map { String(format: "%.1f%%", $0 * 100) }
            ?? "unscored"
        return "\(score.domain): \(value) · pass \(score.passedCaseCount) · fail \(score.failedCaseCount) · unscored \(score.unscoredCaseCount) · errors \(score.errorCaseCount)"
    }

    func caseName(_ id: EvaluationCaseID) -> String {
        promptSuite?.cases.first { $0.id == id }?.name ?? id.rawValue
    }

    func caseScoreSummary(_ result: EvaluationCaseResult) -> String {
        guard let score = result.score else { return "Free-form · not scored" }
        return "\(score.kind.rawValue): \(String(format: "%.3f", score.value)) · \(score.details["scorer"] ?? "scorer unavailable")"
    }

    func percent(_ value: Double?) -> String {
        value.map { String(format: "%+.1f%%", $0 * 100) } ?? "not measured"
    }

    func lossComparisonSummary(_ report: LossAttributionComparisonReport) -> String {
        guard report.state == .measured else {
            return report.state.rawValue
                .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        }
        var parts: [String] = []
        if let quality = report.quality {
            parts.append("quality \(percent(quality.change)) (loss \(String(format: "%.1f%%", quality.loss * 100)))")
        } else {
            parts.append("quality not scored")
        }
        if let performance = report.performance {
            parts.append("storage saved \(percent(performance.storageSavingsFraction))")
            parts.append("memory saved \(percent(performance.peakMemorySavingsFraction))")
            parts.append("generation rate \(percent(performance.generationRateChangeFraction))")
        } else {
            parts.append("performance not measured")
        }
        let human = report.humanPreference
        parts.append(human.judgmentCount == 0
            ? "human preference not measured"
            : "human source \(human.sourcePreferredCount) · target \(human.targetPreferredCount) · tie \(human.tieCount) · both failed \(human.bothFailedCount)")
        return parts.joined(separator: " · ")
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

struct EvaluationSuiteDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .json, .data] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
