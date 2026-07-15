import Darwin
import MLXStudioDomain
import MLXStudioPersistence
import SwiftUI
import vMLXEngine
import vMLXTheme

struct StudioHomeData: Sendable {
    var artifacts: [ModelArtifact]
    var jobs: [DurableJobRecord]
    var evaluations: [StoredEvaluationRun]

    static let empty = StudioHomeData(artifacts: [], jobs: [], evaluations: [])

    static func load(databaseURL: URL = ModelArtifactRepository.defaultDatabaseURL()) throws -> StudioHomeData {
        let artifacts = try ModelArtifactRepository(databaseURL: databaseURL).artifacts()
            .sorted { $0.updatedAt > $1.updatedAt }
        let jobs = try DurableJobRepository(databaseURL: databaseURL).records()
            .sorted { $0.updatedAt > $1.updatedAt }
        let evaluations = try EvaluationRepository(databaseURL: databaseURL).runs()
        return StudioHomeData(artifacts: artifacts, jobs: jobs, evaluations: evaluations)
    }

    var optimizationJobs: [DurableJobRecord] {
        jobs.filter { $0.type.hasPrefix("python-jang-") }
    }

    var resumeDestination: AppState.Mode? {
        if optimizationJobs.contains(where: { [.pending, .running, .paused].contains($0.state) }) {
            return .optimize
        }
        if evaluations.contains(where: { $0.status == .pending || $0.status == .running }) {
            return .evaluate
        }
        if jobs.contains(where: {
            $0.type.hasPrefix("model-tools.")
                && [.pending, .running, .paused].contains($0.state)
        }) {
            return .models
        }
        return artifacts.isEmpty ? nil : .models
    }
}

struct StudioUnifiedMemorySnapshot: Equatable, Sendable {
    let availableBytes: UInt64
    let totalBytes: UInt64

    static func current() -> StudioUnifiedMemorySnapshot {
        let total = ProcessInfo.processInfo.physicalMemory
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else {
            return .init(availableBytes: 0, totalBytes: total)
        }

        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return .init(availableBytes: 0, totalBytes: total)
        }
        let reclaimablePages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count)
        return .init(
            availableBytes: min(reclaimablePages * UInt64(pageSize), total),
            totalBytes: total
        )
    }
}

struct StudioHomeScreen: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var data = StudioHomeData.empty
    @State private var memory = StudioUnifiedMemorySnapshot.current()
    @State private var status = "Loading canonical workspace…"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text("Home")
                            .font(.system(size: 30, weight: .semibold))
                            .foregroundStyle(Theme.Colors.textHigh)
                        Text("Run, optimize, compare, and resume work from one canonical workspace.")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.Colors.textMid)
                    }
                    Spacer()
                    Button { Task { await refresh() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }

                actionGrid
                statusGrid
                recentGrid
            }
            .padding(Theme.Spacing.xl)
        }
        .background(Theme.ProNoirBackground())
        .task { await refresh() }
    }

    private var actionGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 210), spacing: Theme.Spacing.md)],
            spacing: Theme.Spacing.md
        ) {
            action("Run a model", "Start or resume a local conversation", "play.fill", .chat)
            action("Optimize a model", "Build a verified optimization plan", "slider.horizontal.3", .optimize)
            action("Compare models", "Run reproducible evaluations", "chart.bar.xaxis", .evaluate)
            action("Download a model", "Find a compatible Hugging Face artifact", "arrow.down.circle") {
                openWindow(id: "downloads")
            }
            action("Models", "Browse artifacts, lineage, and model tools", "square.stack.3d.up", .models)
            action("Resume a project", resumeCaption, "clock.arrow.circlepath") {
                if let destination = data.resumeDestination { app.mode = destination }
            }
            .disabled(data.resumeDestination == nil)
        }
    }

    private var statusGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 280), spacing: Theme.Spacing.md)],
            spacing: Theme.Spacing.md
        ) {
            statusCard(
                "Runtime",
                value: runtimeLabel,
                caption: status,
                systemImage: "bolt.horizontal.circle"
            )
            statusCard(
                "Unified memory available",
                value: bytes(memory.availableBytes),
                caption: "\(bytes(memory.totalBytes)) physical · free plus reclaimable inactive pages",
                systemImage: "memorychip"
            )
            statusCard(
                "Canonical repository",
                value: "models.sqlite3",
                caption: "\(data.artifacts.count) artifacts · \(data.jobs.count) jobs · \(data.evaluations.count) evaluations",
                systemImage: "cylinder.split.1x2"
            )
        }
    }

    private var recentGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: Theme.Spacing.md)], spacing: Theme.Spacing.md) {
            recentCard("Recent models", systemImage: "square.stack.3d.up") {
                if data.artifacts.isEmpty { emptyRow("No canonical artifacts yet") }
                ForEach(Array(data.artifacts.prefix(3)), id: \.id) { artifact in
                    recentRow(artifact.name, detail: "\(artifact.format.rawValue) · \(artifact.state.rawValue)")
                }
            }
            recentCard("Recent optimization jobs", systemImage: "gearshape.2") {
                if data.optimizationJobs.isEmpty { emptyRow("No optimization jobs yet") }
                ForEach(Array(data.optimizationJobs.prefix(3)), id: \.id) { job in
                    recentRow(job.type, detail: "\(job.state.rawValue) · \(Int(job.progress * 100))%")
                }
            }
            recentCard("Recent evaluations", systemImage: "checklist") {
                if data.evaluations.isEmpty { emptyRow("No evaluation runs yet") }
                ForEach(Array(data.evaluations.prefix(3)), id: \.request.id) { run in
                    recentRow(run.request.suite.name, detail: run.status.rawValue)
                }
            }
        }
    }

    private var resumeCaption: String {
        switch data.resumeDestination {
        case .optimize: return "Continue a durable optimization job"
        case .evaluate: return "Continue an interrupted evaluation"
        case .models: return "Open the most recent artifact project"
        default: return "No resumable project yet"
        }
    }

    private var runtimeLabel: String {
        switch app.engineState {
        case .stopped: return "Stopped"
        case .loading: return "Loading"
        case .running: return "Running"
        case .standby(.soft): return "Light sleep"
        case .standby(.deep): return "Deep sleep"
        case .error: return "Error"
        }
    }

    private func refresh() async {
        do {
            data = try StudioHomeData.load()
            memory = .current()
            status = data.resumeDestination == nil ? "Ready for a new project" : "Workspace restored from durable state"
        } catch {
            status = "Workspace unavailable: \(error.localizedDescription)"
        }
    }

    private func action(_ title: String, _ caption: String, _ icon: String, _ mode: AppState.Mode) -> some View {
        action(title, caption, icon) { app.mode = mode }
    }

    private func action(
        _ title: String,
        _ caption: String,
        _ icon: String,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Theme.Colors.accent)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(title).font(Theme.Typography.bodyHi).foregroundStyle(Theme.Colors.textHigh)
                    Text(caption).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textMid).lineLimit(2)
                }
                Spacer()
            }
            .padding(Theme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
            .background(Theme.ProNoirPanelBackground(active: true))
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
        }
        .buttonStyle(.plain)
    }

    private func statusCard(_ title: String, value: String, caption: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Label(title, systemImage: systemImage).font(Theme.Typography.captionHi).foregroundStyle(Theme.Colors.textMid)
            Text(value).font(Theme.Typography.title).foregroundStyle(Theme.Colors.textHigh)
            Text(caption).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textLow).lineLimit(2)
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .leading)
        .background(Theme.ProNoirPanelBackground(active: false))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    private func recentCard<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Label(title, systemImage: systemImage).font(Theme.Typography.title).foregroundStyle(Theme.Colors.textHigh)
            content()
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
        .background(Theme.ProNoirPanelBackground(active: false))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
    }

    private func recentRow(_ title: String, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.Typography.bodyHi).foregroundStyle(Theme.Colors.textHigh).lineLimit(1)
                Text(detail).font(Theme.Typography.caption).foregroundStyle(Theme.Colors.textLow).lineLimit(1)
            }
            Spacer()
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text).font(Theme.Typography.body).foregroundStyle(Theme.Colors.textLow)
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }
}
