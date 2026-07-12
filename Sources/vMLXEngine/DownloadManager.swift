import Foundation

/// DownloadManager — actor that orchestrates HuggingFace model downloads for vMLX.
///
/// Design notes (per `feedback_download_window.md` — NO silent downloads EVER):
/// - Every state transition is broadcast as a `DownloadManager.Event` to every
///   subscriber so the UI can auto-open the Downloads window on first `.started`.
/// - Uses `URLSessionDownloadTask` with KVO progress observation — streams
///   directly to disk in OS-native chunks (not byte-by-byte). Delegate-free
///   keeps the actor bridging simple via `withCheckedThrowingContinuation`.
/// - HF API enumerates files via `https://huggingface.co/api/models/<repo>`; each
///   sibling blob is downloaded in parallel with a max-2 concurrency window.
/// - Gated repos: set `hfAuthToken` via `setHFAuthToken(_:)`. The token is
///   forwarded as `Authorization: Bearer <token>` on both the API lookup and
///   the file downloads. Stored in the macOS Keychain by the UI layer; the
///   manager itself only holds an in-memory copy per actor lifetime.
/// - Resume: on `resume()` we stat each existing partial file under the cache
///   dir and send a `Range: bytes=<size>-` header. Server returns 206 Partial
///   Content with the remainder; we append to the existing file. On 416 Range
///   Not Satisfiable the file is treated as complete. On ETag mismatch or
///   other 4xx we fall back to a fresh full download.
/// - Final files land under `~/.cache/huggingface/hub/models--<org>--<repo>/snapshots/main/`.
public actor DownloadManager {

    // MARK: - Public types

    public struct Job: Sendable, Identifiable, Codable {
        public let id: UUID
        public var repo: String
        public var displayName: String
        public var totalBytes: Int64
        public var receivedBytes: Int64
        public var bytesPerSecond: Double
        public var etaSeconds: Double?
        public var status: Status
        public var error: String?
        public var startedAt: Date
        public var localPath: URL?
        public var manifestFiles: [HuggingFaceDownloadSafety.RemoteFile]
        /// O7 §293 — set when the HF sibling-list fetch returns 401 or
        /// 403 so the DownloadStatusBar can show a targeted CTA
        /// ("Paste HF token in Settings → API") instead of just a
        /// generic error message. DownloadManager marks this true on
        /// 401/403 responses and clears it on any subsequent retry
        /// that succeeds past the auth step.
        public var requiresHFAuth: Bool

        public init(
            id: UUID,
            repo: String,
            displayName: String,
            totalBytes: Int64 = 0,
            receivedBytes: Int64 = 0,
            bytesPerSecond: Double = 0,
            etaSeconds: Double? = nil,
            status: Status = .queued,
            error: String? = nil,
            startedAt: Date = Date(),
            localPath: URL? = nil,
            manifestFiles: [HuggingFaceDownloadSafety.RemoteFile] = [],
            requiresHFAuth: Bool = false
        ) {
            self.id = id
            self.repo = repo
            self.displayName = displayName
            self.totalBytes = totalBytes
            self.receivedBytes = receivedBytes
            self.bytesPerSecond = bytesPerSecond
            self.etaSeconds = etaSeconds
            self.status = status
            self.error = error
            self.startedAt = startedAt
            self.localPath = localPath
            self.manifestFiles = manifestFiles
            self.requiresHFAuth = requiresHFAuth
        }

        // §327 — custom decoder defaults the newer `requiresHFAuth`
        // field (added in O7 §293) to `false` when the on-disk sidecar
        // was written by a pre-§293 build. Without this, the synthesized
        // Codable decoder throws `keyNotFound` on every upgraded user's
        // first launch and they lose their entire job history (the
        // outer SidecarPayload decode fails too, so loadSidecar returns
        // []). Same treatment for `localPath`/`etaSeconds`/`error`
        // which are already Optional and decode to nil on absence.
        enum CodingKeys: String, CodingKey {
            case id, repo, displayName, totalBytes, receivedBytes
            case bytesPerSecond, etaSeconds, status, error, startedAt
            case localPath, manifestFiles, requiresHFAuth
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try c.decode(UUID.self, forKey: .id)
            self.repo = try c.decode(String.self, forKey: .repo)
            self.displayName = try c.decode(String.self, forKey: .displayName)
            self.totalBytes = try c.decode(Int64.self, forKey: .totalBytes)
            self.receivedBytes = try c.decode(Int64.self, forKey: .receivedBytes)
            self.bytesPerSecond = try c.decode(Double.self, forKey: .bytesPerSecond)
            self.etaSeconds = try c.decodeIfPresent(Double.self, forKey: .etaSeconds)
            self.status = try c.decode(Status.self, forKey: .status)
            self.error = try c.decodeIfPresent(String.self, forKey: .error)
            self.startedAt = try c.decode(Date.self, forKey: .startedAt)
            self.localPath = try c.decodeIfPresent(URL.self, forKey: .localPath)
            self.manifestFiles =
                try c.decodeIfPresent([HuggingFaceDownloadSafety.RemoteFile].self, forKey: .manifestFiles) ?? []
            self.requiresHFAuth =
                try c.decodeIfPresent(Bool.self, forKey: .requiresHFAuth) ?? false
        }
    }

    public enum Status: String, Sendable, Codable {
        case queued, downloading, paused, completed, failed, cancelled
    }

    public enum Event: Sendable {
        case started(Job)
        case progress(Job)
        case paused(UUID)
        case resumed(UUID)
        case completed(Job)
        case failed(UUID, String)
        case cancelled(UUID)
    }

    // MARK: - State

    private var _jobs: [UUID: Job] = [:]
    private var order: [UUID] = []
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var workTasks: [UUID: Task<Void, Never>] = [:]
    /// 5-second sliding window samples: (timestamp, receivedBytes)
    private var speedSamples: [UUID: [(Date, Int64)]] = [:]

    private let maxConcurrentFiles = 2

    /// §253b: cross-job cap. Each `run(id:)` pulls up to
    /// `maxConcurrentFiles` shards in parallel, so 5 enqueued jobs can
    /// fire 10 simultaneous HTTP streams at huggingface.co — well past
    /// HF's unauthenticated rate-limit (~30 req/min per IP). Cap the
    /// number of jobs actively fetching shards to 3; extras stay
    /// `.downloading` but block on `jobSlots` before entering the
    /// sibling fetch. FIFO so the first-enqueued gets its turn first.
    private let maxConcurrentJobs = 3
    private var activeJobs: Int = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// HuggingFace access token for gated repos. Set via `setHFAuthToken(_:)`.
    /// The UI persists the real value in the macOS Keychain; the manager only
    /// keeps an in-memory copy for the duration of the actor's lifetime.
    private var hfAuthToken: String?

    /// In-flight native HTTP tasks per job. A job may fetch two files in
    /// parallel, so this is keyed by a transfer UUID rather than keeping only
    /// the most recently-created task. Retaining the transfer also retains its
    /// URLSession delegate while it streams bytes into the stable `.part` file.
    private var liveDataTasks: [UUID: [UUID: LiveDataTransfer]] = [:]

    /// Isolated session-configuration seam for download transport tests.
    /// Production uses an ephemeral configuration; XCTest can install a
    /// URLProtocol-backed configuration without touching the network or the
    /// user's Hugging Face cache.
    nonisolated(unsafe) static var sessionConfigurationFactory: @Sendable () -> URLSessionConfiguration = {
        .ephemeral
    }

    /// Matching isolated filesystem seam. It is intentionally internal so
    /// tests can prove pause/resume without inspecting or mutating a user's
    /// real Hugging Face cache.
    nonisolated(unsafe) static var huggingFaceHubRootProvider: @Sendable () -> URL = {
        FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub")
    }

    public init() {
        // §252: load any previously-enqueued jobs from the on-disk
        // sidecar so the user can see their downloads after app restart.
        // Entries restored as `.paused` — the user clicks Resume to
        // re-hydrate siblings from HF and continue via the existing
        // Range-header path. Corrupt sidecar = silently start empty;
        // we never want a bad persistence layer to break app launch.
        Self.loadSidecar().forEach { persisted in
            var job = persisted
            // Completed/cancelled jobs survive for history; everything
            // in-flight at the prior quit needs user confirmation
            // before resuming, so present as paused.
            if job.status == .downloading || job.status == .queued {
                job.status = .paused
                job.bytesPerSecond = 0
                job.etaSeconds = nil
            }
            _jobs[job.id] = job
            order.append(job.id)
            speedSamples[job.id] = []
        }
    }

    // MARK: - Auth

    /// Set or clear the HuggingFace access token. Pass nil to forget.
    public func setHFAuthToken(_ token: String?) {
        if let t = token, !t.isEmpty {
            self.hfAuthToken = t
        } else {
            self.hfAuthToken = nil
        }
    }

    public func hasHFAuthToken() -> Bool { hfAuthToken != nil }

    // MARK: - Subscription (multi-listener)

    public func subscribe() -> AsyncStream<Event> {
        AsyncStream { continuation in
            let token = UUID()
            self.continuations[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(token) }
            }
        }
    }

    private func removeContinuation(_ token: UUID) {
        continuations.removeValue(forKey: token)
    }

    private func broadcast(_ event: Event) {
        for (_, c) in continuations {
            c.yield(event)
        }
    }

    // MARK: - Queries

    public func jobs() -> [Job] {
        order.compactMap { _jobs[$0] }
    }

    public func job(_ id: UUID) -> Job? { _jobs[id] }

    // MARK: - Commands

    @discardableResult
    public func enqueue(repo: String, displayName: String) -> UUID {
        let id = UUID()
        let job = Job(id: id, repo: repo, displayName: displayName, status: .queued)
        _jobs[id] = job
        order.append(id)
        speedSamples[id] = []

        // Immediately broadcast .started so UI auto-opens.
        var started = job
        started.status = .downloading
        _jobs[id] = started
        broadcast(.started(started))
        persistSidecar()

        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(id: id)
        }
        workTasks[id] = task
        return id
    }

    public func pause(_ id: UUID) {
        guard var job = _jobs[id], job.status == .downloading else { return }
        workTasks[id]?.cancel()
        workTasks.removeValue(forKey: id)
        cancelDataTasks(jobId: id)
        job.status = .paused
        _jobs[id] = job
        broadcast(.paused(id))
        persistSidecar()
    }

    public func resume(_ id: UUID) {
        guard var job = _jobs[id], job.status == .paused || job.status == .failed else { return }
        job.status = .downloading
        job.error = nil
        _jobs[id] = job
        broadcast(.resumed(id))
        persistSidecar()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.run(id: id)
        }
        workTasks[id] = task
    }

    public func cancel(_ id: UUID) {
        guard var job = _jobs[id] else { return }
        workTasks[id]?.cancel()
        workTasks.removeValue(forKey: id)
        cancelDataTasks(jobId: id)
        if job.status == .completed { return }
        // Pause preserves `.part` bytes for a Range resume. Cancel is the
        // explicit discard action, so reclaim those bytes synchronously after
        // every live delegate has been told to stop writing.
        removePartialFiles(for: job)
        job.status = .cancelled
        _jobs[id] = job
        broadcast(.cancelled(id))
        persistSidecar()
    }

    public func clearCompleted() {
        let remaining = order.filter { id in
            guard let j = _jobs[id] else { return false }
            return j.status != .completed && j.status != .cancelled
        }
        for id in order where !remaining.contains(id) {
            _jobs.removeValue(forKey: id)
            speedSamples.removeValue(forKey: id)
        }
        order = remaining
        persistSidecar()
    }

    // MARK: - Worker

    private func run(id: UUID) async {
        guard var job = _jobs[id] else { return }

        // §253b: global slot acquire. Blocks until < maxConcurrentJobs
        // other runs are active. Released in all exit paths (success,
        // failure, cancel) via `defer`.
        await acquireSlot(for: id)
        defer { releaseSlot() }

        // Re-read the job now that we've waited — the user may have
        // cancelled or paused while we were queued.
        guard let refreshed = _jobs[id],
              refreshed.status == .downloading
        else { return }
        job = refreshed

        do {
            // 1. Enumerate files from HF API.
            let files = try await fetchDownloadSiblings(repo: job.repo)
            let manifestFiles = files.map {
                HuggingFaceDownloadSafety.RemoteFile(path: $0.rfilename, size: $0.size)
            }
            job.manifestFiles = manifestFiles
            let total = files.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
            job.totalBytes = max(total, job.totalBytes)
            _jobs[id] = job
            broadcast(.progress(job))

            // §251: pre-flight disk-space check. If HF reported a total
            // (sum of sibling `size` fields) and the destination volume
            // cannot fit it plus safety headroom, fail fast with an
            // actionable error instead of leaving a half-complete snapshot.
            if total > 0 {
                let hubRoot = Self.huggingFaceHubRoot()
                try? FileManager.default.createDirectory(
                    at: hubRoot, withIntermediateDirectories: true)
                if let free = Self.freeSpaceBytes(at: hubRoot),
                   let message = HuggingFaceDownloadSafety.storageRefusalMessage(
                    neededBytes: total,
                    freeBytes: free
                   ) {
                    throw DownloadError.diskFull(message)
                }
            }

            // 2. Prepare destination dir.
            let destDir = try cacheDir(for: job.repo)
            job.localPath = destDir
            _jobs[id] = job

            // 2b. Seed the progress bar with bytes already on disk from any
            //     prior (paused / crashed / resumed) attempt. This way a
            //     resume doesn't reset the bar to 0 then jump forward.
            var existingBytes: Int64 = 0
            for sib in files {
                guard let dest = HuggingFaceDownloadSafety.destinationURL(
                    forRemotePath: sib.rfilename,
                    under: destDir
                ) else { continue }
                let state = try Self.prepareDownloadFile(
                    destination: dest,
                    expectedSize: sib.size
                )
                existingBytes += state.accountedBytes
            }
            if existingBytes > 0 {
                job.receivedBytes = existingBytes
                _jobs[id] = job
                broadcast(.progress(job))
            }

            // 3. Download files with max-2 concurrency. For each file we
            //    stat the on-disk bytes and pass as resumeFrom so the
            //    HTTP Range header skips what's already local.
            var index = 0
            while index < files.count {
                if Task.isCancelled { return }
                let slice = files[index..<min(index + maxConcurrentFiles, files.count)]
                try await withThrowingTaskGroup(of: Int64.self) { group in
                    for sib in slice {
                        guard let url = HuggingFaceDownloadSafety.resolveURL(
                            repo: sib.sourceRepo ?? job.repo,
                            path: sib.rfilename
                        ),
                              let dest = HuggingFaceDownloadSafety.destinationURL(
                                forRemotePath: sib.rfilename,
                                under: destDir
                              )
                        else { continue }
                        let state = try Self.prepareDownloadFile(
                            destination: dest,
                            expectedSize: sib.size
                        )
                        // Only promoted final files are considered complete.
                        // Bytes in `.part` survive pause/restart but must still
                        // finish and pass the manifest before they become model
                        // files visible to the rest of the app.
                        if state.isComplete {
                            continue
                        }
                        let resumeFrom = state.resumeBytes
                        group.addTask { [weak self] in
                            guard let self else { return 0 }
                            return try await self.downloadFile(
                                jobId: id, url: url, dest: dest, resumeFrom: resumeFrom
                            )
                        }
                    }
                    for try await _ in group {}
                }
                index += maxConcurrentFiles
            }

            // 4. Verify the manifest, then mark complete.
            try HuggingFaceDownloadSafety.verifyManifest(
                files: manifestFiles,
                under: destDir
            )
            if var done = _jobs[id] {
                done.status = .completed
                done.receivedBytes = done.totalBytes
                done.etaSeconds = 0
                done.bytesPerSecond = 0
                _jobs[id] = done
                broadcast(.completed(done))
                persistSidecar()
            }
        } catch is CancellationError {
            // paused or cancelled — event already broadcast.
            return
        } catch {
            // iter-94 §121: URLSession cancellation surfaces as
            // `URLError(.cancelled)` (NSURLErrorCancelled = -999), NOT
            // Swift's `CancellationError`, so the case-is match above
            // doesn't catch it. Without this second guard, user-
            // cancelled downloads briefly appeared `.cancelled` (set
            // by `cancel(_:)` synchronously) and then flipped to
            // `.failed` with cryptic message "The operation couldn't
            // be completed" once the URLSession completion handler
            // resumed with URLError.cancelled. Also catch cases
            // where the outer Task was cancelled but the error
            // propagated as something other than CancellationError.
            if let urlErr = error as? URLError, urlErr.code == .cancelled {
                return
            }
            if Task.isCancelled {
                return
            }
            // Also skip the flip if the job was already flagged
            // `.cancelled` by the user — defensive in case a future
            // refactor threads cancellation through a different
            // error type.
            if _jobs[id]?.status == .cancelled {
                return
            }
            if var j = _jobs[id] {
                j.status = .failed
                j.error = "\(error)"
                // O7 §293: detect HF auth failure and set the flag so
                // the Downloads UI can CTA the user into the
                // HuggingFaceTokenCard. Match NSError.code (which
                // fetchSiblings + file-stream throw with the HTTP
                // status on domain "vMLX.DownloadManager") OR the
                // "requires authentication" / "is gated" hint strings
                // embedded in those errors, so we catch both the
                // initial sibling fetch and any per-file 401.
                let err = error as NSError
                let msg = (err.userInfo[NSLocalizedDescriptionKey] as? String) ?? "\(error)"
                if err.code == 401 || err.code == 403
                    || msg.contains("requires authentication")
                    || msg.contains("is gated")
                {
                    j.requiresHFAuth = true
                }
                _jobs[id] = j
                broadcast(.failed(id, j.error ?? "unknown error"))
                persistSidecar()
            }
        }
    }

    // MARK: - HF API

    private struct Sibling: Decodable {
        let rfilename: String
        let size: Int64?
        let sourceRepo: String?

        init(rfilename: String, size: Int64?, sourceRepo: String? = nil) {
            self.rfilename = rfilename
            self.size = size
            self.sourceRepo = sourceRepo
        }

        private enum CodingKeys: String, CodingKey {
            case rfilename
            case size
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rfilename = try container.decode(String.self, forKey: .rfilename)
            size = try container.decodeIfPresent(Int64.self, forKey: .size)
            sourceRepo = nil
        }
    }
    private struct ModelInfo: Decodable {
        let siblings: [Sibling]
    }

    private func fetchDownloadSiblings(repo: String) async throws -> [Sibling] {
        var files = try await fetchSiblings(repo: repo)
        guard let tokenizerRepo = Self.whisperTokenizerSourceRepo(for: repo) else {
            return files
        }

        let existingPaths = Set(files.map { $0.rfilename.lowercased() })
        let tokenizerFiles = try await fetchSiblings(repo: tokenizerRepo)
            .filter {
                Self.isWhisperTokenizerSidecar($0.rfilename)
                    && !existingPaths.contains($0.rfilename.lowercased())
            }
            .map {
                Sibling(
                    rfilename: $0.rfilename,
                    size: $0.size,
                    sourceRepo: tokenizerRepo
                )
            }

        files.append(contentsOf: tokenizerFiles)
        return files
    }

    private func fetchSiblings(repo: String) async throws -> [Sibling] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)") else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        if let token = hfAuthToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await URLSession.shared.data(for: request)
        if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
            let hint: String
            switch http.statusCode {
            case 401: hint = "HF repo \(repo) requires authentication. Set a HuggingFace token in Settings → Downloads."
            case 403: hint = "HF repo \(repo) is gated. Accept the license on huggingface.co, then retry."
            case 404: hint = "HF repo \(repo) not found. Check the owner/name spelling."
            default:  hint = "HF API returned \(http.statusCode) for \(repo)."
            }
            throw NSError(
                domain: "vMLX.DownloadManager",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: hint]
            )
        }
        let info = try JSONDecoder().decode(ModelInfo.self, from: data)
        // Restrict to weight + config + tokenizer files, AND
        // reject anything that could escape the destination
        // directory on disk.
        return info.siblings.filter { sib in
            Self.shouldDownloadSibling(sib.rfilename, for: repo)
        }
    }

    internal static func shouldDownloadSibling(_ filename: String) -> Bool {
        shouldDownloadSibling(filename, for: nil)
    }

    internal static func shouldDownloadSibling(_ filename: String, for repo: String?) -> Bool {
        guard isSafeFilename(filename) else { return false }
        let f = filename.lowercased()
        if repo?.lowercased() == "krea/krea-2-turbo" {
            return krea2RequiredDownloadPaths.contains(f)
        }
        return f.hasSuffix(".safetensors")
            || f.hasSuffix(".npz")
            || f.hasSuffix(".json")
            || f.hasSuffix(".txt")
            || f.hasSuffix(".model")
            || f.hasSuffix(".jinja")
    }

    private static let krea2RequiredDownloadPaths: Set<String> = [
        "model_index.json",
        "scheduler/scheduler_config.json",
        "turbo.safetensors",
        "vae/config.json",
        "vae/diffusion_pytorch_model.safetensors",
        "text_encoder/config.json",
        "text_encoder/model.safetensors",
        "tokenizer/chat_template.jinja",
        "tokenizer/tokenizer.json",
        "tokenizer/tokenizer_config.json",
    ]

    internal static func whisperTokenizerSourceRepo(for repo: String) -> String? {
        let lowercasedRepo = repo.lowercased()
        let name = lowercasedRepo.split(separator: "/").last.map(String.init) ?? lowercasedRepo
        guard name.contains("whisper") else { return nil }

        if name.contains("large-v3") { return "openai/whisper-large-v3" }
        if name.contains("large-v2") { return "openai/whisper-large-v2" }
        if name.contains("large") { return "openai/whisper-large" }
        if name.contains("medium.en") { return "openai/whisper-medium.en" }
        if name.contains("medium") { return "openai/whisper-medium" }
        if name.contains("small.en") { return "openai/whisper-small.en" }
        if name.contains("small") { return "openai/whisper-small" }
        if name.contains("base.en") { return "openai/whisper-base.en" }
        if name.contains("base") { return "openai/whisper-base" }
        if name.contains("tiny.en") { return "openai/whisper-tiny.en" }
        if name.contains("tiny") { return "openai/whisper-tiny" }
        return nil
    }

    internal static func isWhisperTokenizerSidecar(_ filename: String) -> Bool {
        guard isSafeFilename(filename), !filename.contains("/") else { return false }
        return [
            "tokenizer.json",
            "tokenizer_config.json",
            "added_tokens.json",
            "special_tokens_map.json",
            "normalizer.json",
            "vocab.json",
            "merges.txt",
        ].contains(filename.lowercased())
    }

    /// **iter-82 (§110)** — path-traversal guard for the filename
    /// coming back from the HuggingFace API. A compromised,
    /// man-in-the-middled, or malicious-mirror HF API response
    /// could set `rfilename` to `"../../../.ssh/authorized_keys"`;
    /// `URL.appendingPathComponent` preserves `..` literally but
    /// POSIX path resolution collapses them, so a write would
    /// land OUTSIDE `destDir`. This check rejects any filename
    /// that starts with `/`, contains `..` as a path component,
    /// or is empty/whitespace — defense in depth independent of
    /// TLS validation on the transport.
    internal static func isSafeFilename(_ raw: String) -> Bool {
        HuggingFaceDownloadSafety.normalizedRemoteFilePath(
            raw.trimmingCharacters(in: .whitespaces)
        ) != nil
    }

    // MARK: - File download
    //
    // Each transfer writes directly to `<file>.part`; only a completed HTTP
    // response atomically promotes that file to its model-visible name. This
    // matters because `URLSessionDownloadTask` hides its temporary file until
    // completion, so cancelling it loses every in-flight byte and makes a
    // claimed Range resume impossible. A streaming data-task delegate keeps
    // the partial file durable across pause, app restart, and retry.

    private func downloadFile(
        jobId: UUID,
        url: URL,
        dest: URL,
        resumeFrom: Int64 = 0
    ) async throws -> Int64 {
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var request = URLRequest(url: url)
        if let token = hfAuthToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if resumeFrom > 0 {
            request.setValue("bytes=\(resumeFrom)-", forHTTPHeaderField: "Range")
        }
        let transferID = UUID()
        let cancellation = DownloadTransferCancellationBox()
        let partialURL = Self.partialURL(for: dest)

        let outcome = try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<StreamingDownloadOutcome, Error>) in
                let delegate = StreamingDataDelegate(
                    partialURL: partialURL,
                    requestedRange: resumeFrom > 0,
                    onBytes: { [weak self] delta in
                        Task { await self?.addBytes(jobId: jobId, delta: delta) }
                    },
                    onRestartFromZero: { [weak self] in
                        guard resumeFrom > 0 else { return }
                        await self?.addBytes(jobId: jobId, delta: -resumeFrom)
                    },
                    onFinished: { [weak self] in
                        Task { await self?.unregisterDataTask(jobId: jobId, transferID: transferID) }
                    }
                )
                let session = URLSession(
                    configuration: Self.sessionConfigurationFactory(),
                    delegate: delegate,
                    delegateQueue: nil
                )
                let task = session.dataTask(with: request)
                let transfer = LiveDataTransfer(session: session, task: task, delegate: delegate)
                delegate.begin(continuation)

                // The continuation callback is nonisolated. Register and
                // start from an actor hop so pause/cancel can see every one
                // of a job's concurrent file transfers.
                Task { [weak self] in
                    guard let self else {
                        delegate.finishBeforeStart(CancellationError())
                        return
                    }
                    guard !cancellation.isCancelled else {
                        delegate.finishBeforeStart(CancellationError())
                        return
                    }
                    await self.registerDataTask(
                        jobId: jobId,
                        transferID: transferID,
                        transfer: transfer
                    )
                    guard !cancellation.isCancelled else {
                        await self.unregisterDataTask(jobId: jobId, transferID: transferID)
                        delegate.finishBeforeStart(CancellationError())
                        return
                    }
                    task.resume()
                }
            }
        }, onCancel: {
            cancellation.cancel()
            Task { [jobId, transferID] in
                await self.cancelDataTask(jobId: jobId, transferID: transferID)
            }
        })

        if outcome.shouldPromotePartial {
            try Self.promotePartialFile(partialURL, to: dest)
        }
        return outcome.bytesWritten
    }

    // MARK: - Data-task lifecycle bridging

    private func registerDataTask(
        jobId: UUID,
        transferID: UUID,
        transfer: LiveDataTransfer
    ) {
        liveDataTasks[jobId, default: [:]][transferID] = transfer
    }

    private func unregisterDataTask(jobId: UUID, transferID: UUID) {
        liveDataTasks[jobId]?.removeValue(forKey: transferID)
        if liveDataTasks[jobId]?.isEmpty == true {
            liveDataTasks.removeValue(forKey: jobId)
        }
    }

    private func cancelDataTask(jobId: UUID, transferID: UUID) {
        guard let transfer = liveDataTasks[jobId]?[transferID] else { return }
        transfer.cancel()
        unregisterDataTask(jobId: jobId, transferID: transferID)
    }

    private func cancelDataTasks(jobId: UUID) {
        guard let transfers = liveDataTasks.removeValue(forKey: jobId) else { return }
        for transfer in transfers.values {
            transfer.cancel()
        }
    }

    private func removePartialFiles(for job: Job) {
        guard let root = job.localPath else { return }
        let fm = FileManager.default
        for file in job.manifestFiles {
            guard let destination = HuggingFaceDownloadSafety.destinationURL(
                forRemotePath: file.path,
                under: root
            ) else { continue }
            try? fm.removeItem(at: Self.partialURL(for: destination))
        }
    }

    private func addBytes(jobId: UUID, delta: Int64) {
        guard var job = _jobs[jobId],
              job.status != .completed,
              job.status != .cancelled,
              job.status != .failed,
              delta != 0
        else { return }
        job.receivedBytes = max(0, job.receivedBytes + delta)

        if delta < 0 {
            // A server that ignores Range returns 200 with the whole file.
            // Drop the stale partial-file contribution before counting the
            // fresh response, otherwise progress can exceed 100%.
            speedSamples[jobId] = []
            job.bytesPerSecond = 0
            job.etaSeconds = nil
            _jobs[jobId] = job
            broadcast(.progress(job))
            return
        }

        // 5-second sliding window speed.
        let now = Date()
        var samples = speedSamples[jobId] ?? []
        samples.append((now, job.receivedBytes))
        samples.removeAll { now.timeIntervalSince($0.0) > 5.0 }
        speedSamples[jobId] = samples

        if let first = samples.first, samples.count > 1 {
            let dt = now.timeIntervalSince(first.0)
            let db = Double(job.receivedBytes - first.1)
            if dt > 0 {
                job.bytesPerSecond = db / dt
                if job.bytesPerSecond > 0, job.totalBytes > job.receivedBytes {
                    job.etaSeconds = Double(job.totalBytes - job.receivedBytes) / job.bytesPerSecond
                }
            }
        }

        _jobs[jobId] = job
        broadcast(.progress(job))
    }

    private struct LocalDownloadFileState {
        let accountedBytes: Int64
        let resumeBytes: Int64
        let isComplete: Bool
    }

    /// Return a stable sidecar name which the model scanner will never treat
    /// as a loadable weight shard (`model.safetensors.part` has extension
    /// `part`, not `safetensors`).
    private static func partialURL(for destination: URL) -> URL {
        destination.appendingPathExtension("part")
    }

    /// Normalize legacy direct-to-destination partials into the durable
    /// `.part` layout. Finished files are always at `destination`; in-flight
    /// bytes are always at `destination.part`.
    private static func prepareDownloadFile(
        destination: URL,
        expectedSize: Int64?
    ) throws -> LocalDownloadFileState {
        let fm = FileManager.default
        let partial = partialURL(for: destination)
        let finalSize = fileSize(at: destination, fileManager: fm)

        if let expectedSize, expectedSize > 0, finalSize == expectedSize {
            // A stale partial from an already-promoted file must not make a
            // later retry range from unrelated bytes.
            if fm.fileExists(atPath: partial.path) {
                try? fm.removeItem(at: partial)
            }
            return LocalDownloadFileState(
                accountedBytes: finalSize,
                resumeBytes: 0,
                isComplete: true
            )
        }

        var retainedFinalSize = finalSize
        if let expectedSize, expectedSize > 0, finalSize > expectedSize {
            // A previous buggy append (or corrupted final file) cannot be
            // resumed safely. Restart this one file from zero.
            try? fm.removeItem(at: destination)
            retainedFinalSize = 0
        }

        var partialSize = fileSize(at: partial, fileManager: fm)
        if retainedFinalSize > 0 {
            // Pre-.part versions wrote incomplete bytes directly to the final
            // path. Preserve the longer candidate once, then keep future
            // pauses isolated from model discovery.
            if retainedFinalSize >= partialSize {
                if fm.fileExists(atPath: partial.path) {
                    try? fm.removeItem(at: partial)
                }
                try fm.moveItem(at: destination, to: partial)
                partialSize = retainedFinalSize
            } else {
                try? fm.removeItem(at: destination)
            }
        }

        return LocalDownloadFileState(
            accountedBytes: partialSize,
            resumeBytes: partialSize,
            isComplete: false
        )
    }

    private static func fileSize(at url: URL, fileManager: FileManager) -> Int64 {
        guard fileManager.fileExists(atPath: url.path),
              let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber
        else { return 0 }
        return size.int64Value
    }

    private static func promotePartialFile(_ partial: URL, to destination: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: partial.path) else {
            throw URLError(.cannotCreateFile)
        }
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(
                destination,
                withItemAt: partial,
                backupItemName: nil,
                options: []
            )
        } else {
            // Same-directory move is an APFS rename and therefore atomic.
            try fm.moveItem(at: partial, to: destination)
        }
    }

    // MARK: - Paths

    private func cacheDir(for repo: String) throws -> URL {
        let sanitized = "models--" + repo.replacingOccurrences(of: "/", with: "--")
        let dir = Self.huggingFaceHubRoot()
            .appendingPathComponent(sanitized)
            .appendingPathComponent("snapshots")
            .appendingPathComponent("main")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // `resumeTokenDir` was removed 2026-04-15 per audit finding (lifecycle
    // #6). The helper was declared but never referenced — partial-download
    // state is derived entirely from on-disk file size + a `Range` header,
    // which is simpler and survives restart without a sidecar token file.
    // NSURLSession-native resume data was never wired up, so the helper
    // was misleading dead code.

    // MARK: - §251 disk-space helpers

    // MARK: - §253b slot coordination

    /// Wait until fewer than `maxConcurrentJobs` runs are active, then
    /// increment `activeJobs`. FIFO ordering keyed by UUID so enqueue
    /// order is preserved.
    private func acquireSlot(for id: UUID) async {
        if activeJobs < maxConcurrentJobs {
            activeJobs += 1
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            waiters[id] = cont
        }
        activeJobs += 1
    }

    /// Release the slot and wake the next waiter (if any). Called
    /// once per acquire; safe to call multiple times due to the
    /// `firstKey` check — never double-resumes a continuation.
    private func releaseSlot() {
        activeJobs = max(0, activeJobs - 1)
        // Take the oldest waiter — keyed on insertion order since
        // Swift dicts are unordered, we pick the first UUID
        // deterministically by sorting. Waiter-set size is O(enqueued),
        // almost always <5, so the sort cost is negligible.
        guard let next = waiters.keys.sorted().first else { return }
        let cont = waiters.removeValue(forKey: next)!
        cont.resume()
    }

    // MARK: - §252 sidecar persistence

    /// Location of the jobs sidecar. Written next to SettingsStore so
    /// cleanup (`rm -rf "~/Library/Application Support/vMLX"`) clears
    /// both. Created lazily on first write.
    private static func sidecarURL() -> URL {
        // Test override: `VMLX_SIDECAR_DIR` lets tests point at a
        // scratch dir without clobbering real user state. FileManager's
        // `.applicationSupportDirectory` URL isn't redirected by $HOME
        // on macOS, so env override is the cleanest seam.
        if let override = ProcessInfo.processInfo.environment["VMLX_SIDECAR_DIR"],
           !override.isEmpty
        {
            return URL(fileURLWithPath: override)
                .appendingPathComponent("downloads.json")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("vMLX/downloads.json")
    }

    /// Persist the full job list. Called after every status-changing
    /// event — enqueue, pause, resume, cancel, complete, progress tick
    /// (rate-limited by caller). JSON is small (<50KB for 100 jobs)
    /// so atomic overwrite is fine; no WAL needed.
    nonisolated private static func writeSidecar(_ jobs: [Job]) {
        let url = sidecarURL()
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        let payload = SidecarPayload(version: 1, jobs: jobs)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(payload) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Load jobs from disk. Returns empty on missing/corrupt file.
    nonisolated private static func loadSidecar() -> [Job] {
        let url = sidecarURL()
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(SidecarPayload.self, from: data)
        else { return [] }
        return payload.jobs
    }

    /// Trigger a sidecar write for the current state. Fire-and-forget;
    /// the write itself is async off-actor to avoid blocking the
    /// download hot path on disk IO.
    private func persistSidecar() {
        let snapshot = order.compactMap { _jobs[$0] }
        Task.detached(priority: .utility) {
            Self.writeSidecar(snapshot)
        }
    }

    private struct SidecarPayload: Codable {
        let version: Int
        let jobs: [Job]
    }

    /// Root directory where HuggingFace snapshots land. Used for the
    /// pre-flight disk check so we probe the correct volume.
    static func huggingFaceHubRoot() -> URL {
        huggingFaceHubRootProvider()
    }

    /// Available free bytes on the volume that hosts `url`. Returns nil
    /// if the FS attributes call fails (e.g. volume unmounted).
    nonisolated static func freeSpaceBytes(at url: URL) -> Int64? {
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// §251 — download-manager-level errors. Wrapped in a separate enum so
/// callers can surface a disk-full banner vs. a generic "download
/// failed" message.
public enum DownloadError: Error, LocalizedError {
    case diskFull(String)
    public var errorDescription: String? {
        switch self {
        case .diskFull(let m): return m
        }
    }
}

/// One data-task result. `shouldPromotePartial` is true for a successful
/// 2xx body and for a 416 response, where the persisted `.part` already has
/// every requested byte and must be promoted before manifest verification.
private struct StreamingDownloadOutcome: Sendable {
    let bytesWritten: Int64
    let shouldPromotePartial: Bool
}

/// Retains the session + delegate for exactly one native transfer. Several
/// transfers can belong to the same DownloadManager job concurrently.
private final class LiveDataTransfer: @unchecked Sendable {
    let session: URLSession
    let task: URLSessionDataTask
    let delegate: StreamingDataDelegate

    init(session: URLSession, task: URLSessionDataTask, delegate: StreamingDataDelegate) {
        self.session = session
        self.task = task
        self.delegate = delegate
    }

    func cancel() {
        // Prevent a delegate callback already queued by URLSession from
        // writing another chunk after a user chose Cancel and the actor has
        // removed the stable `.part` file.
        delegate.stopWriting()
        task.cancel()
        session.invalidateAndCancel()
    }
}

/// Lock-protected cancellation bit used to close the tiny gap between
/// creating a task and registering it with DownloadManager's actor state.
private final class DownloadTransferCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Streams HTTP response chunks into a durable `.part` file. Unlike a
/// URLSessionDownloadTask temporary location, that file survives task
/// cancellation and becomes the byte count used by the next Range request.
private final class StreamingDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let partialURL: URL
    private let requestedRange: Bool
    private let onBytes: @Sendable (Int64) -> Void
    private let onRestartFromZero: @Sendable () async -> Void
    private let onFinished: @Sendable () -> Void

    private let lock = NSLock()
    private var continuation: CheckedContinuation<StreamingDownloadOutcome, Error>?
    private var handle: FileHandle?
    private var statusCode: Int?
    private var bytesWritten: Int64 = 0
    private var terminalError: Error?
    private var finished = false

    init(
        partialURL: URL,
        requestedRange: Bool,
        onBytes: @escaping @Sendable (Int64) -> Void,
        onRestartFromZero: @escaping @Sendable () async -> Void,
        onFinished: @escaping @Sendable () -> Void
    ) {
        self.partialURL = partialURL
        self.requestedRange = requestedRange
        self.onBytes = onBytes
        self.onRestartFromZero = onRestartFromZero
        self.onFinished = onFinished
    }

    func begin(_ continuation: CheckedContinuation<StreamingDownloadOutcome, Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
    }

    func finishBeforeStart(_ error: Error) {
        finish(error: error)
    }

    func stopWriting() {
        finish(error: CancellationError())
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            finish(error: URLError(.badServerResponse))
            completionHandler(.cancel)
            return
        }

        let status = http.statusCode
        if status == 416 {
            lock.lock()
            statusCode = status
            lock.unlock()
            completionHandler(.allow)
            return
        }

        guard (200..<300).contains(status) else {
            let hint: String
            switch status {
            case 401: hint = "HF file requires authentication."
            case 403: hint = "HF file is gated — accept the license and retry."
            default:  hint = "HTTP \(status) downloading \(dataTask.originalRequest?.url?.lastPathComponent ?? "file")."
            }
            finish(error: NSError(
                domain: "vMLX.DownloadManager",
                code: status,
                userInfo: [NSLocalizedDescriptionKey: hint]
            ))
            completionHandler(.cancel)
            return
        }

        let append = requestedRange && status == 206
        let restartedFromZero = requestedRange && status == 200
        do {
            let fm = FileManager.default
            try fm.createDirectory(
                at: partialURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !append {
                if fm.fileExists(atPath: partialURL.path) {
                    try fm.removeItem(at: partialURL)
                }
                fm.createFile(atPath: partialURL.path, contents: nil)
            } else if !fm.fileExists(atPath: partialURL.path) {
                fm.createFile(atPath: partialURL.path, contents: nil)
            }

            let fileHandle = try FileHandle(forWritingTo: partialURL)
            if append {
                try fileHandle.seekToEnd()
            }
            lock.lock()
            statusCode = status
            handle = fileHandle
            lock.unlock()
            if restartedFromZero {
                // URLSession waits for this completion handler before
                // delivering body bytes, so the actor can subtract the old
                // partial-file contribution before fresh progress arrives.
                Task {
                    await self.onRestartFromZero()
                    completionHandler(.allow)
                }
            } else {
                completionHandler(.allow)
            }
        } catch {
            finish(error: error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var shouldReport = false
        lock.lock()
        if terminalError == nil,
           !finished,
           statusCode != 416,
           let handle
        {
            do {
                try handle.write(contentsOf: data)
                bytesWritten += Int64(data.count)
                shouldReport = !data.isEmpty
            } catch {
                terminalError = error
                dataTask.cancel()
            }
        }
        lock.unlock()
        if shouldReport {
            onBytes(Int64(data.count))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let savedError = terminalError ?? error
        let status = statusCode
        let savedBytes = bytesWritten
        lock.unlock()

        if let savedError {
            finish(error: savedError)
            return
        }
        guard let status else {
            finish(error: URLError(.badServerResponse))
            return
        }
        if status == 416 {
            finish(outcome: StreamingDownloadOutcome(bytesWritten: 0, shouldPromotePartial: true))
        } else if (200..<300).contains(status) {
            finish(outcome: StreamingDownloadOutcome(bytesWritten: savedBytes, shouldPromotePartial: true))
        } else {
            finish(error: URLError(.badServerResponse))
        }
    }

    private func finish(error: Error) {
        finish(result: .failure(error))
    }

    private func finish(outcome: StreamingDownloadOutcome) {
        finish(result: .success(outcome))
    }

    private func finish(result: Result<StreamingDownloadOutcome, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        let handle = self.handle
        self.handle = nil
        lock.unlock()

        try? handle?.close()
        onFinished()
        switch result {
        case .success(let outcome): continuation?.resume(returning: outcome)
        case .failure(let error): continuation?.resume(throwing: error)
        }
    }
}
