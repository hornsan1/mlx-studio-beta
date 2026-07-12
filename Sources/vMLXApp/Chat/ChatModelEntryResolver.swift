import Foundation
import vMLXEngine

/// The model identity persisted on a conversation after a request starts.
/// `name` is deliberately human-readable; `path` remains the canonical local
/// path used to reopen or diagnose the conversation later.
struct ChatModelIdentity: Equatable, Sendable {
    let name: String
    let path: String?
}

/// Resolves the identity strings that can outlive a model-library scan back
/// to a concrete local model entry.
///
/// Chat history deliberately stores a readable model name rather than an
/// opaque library id. That means a fresh chat can inherit any of several
/// spellings: a display name (`LiquidAI/LFM2.5-350M`), the picker label used
/// to disambiguate duplicate copies, a model-directory basename
/// (`LFM2.5-350M`), or an absolute path. Keep this lookup in one place so the
/// picker, inline Load button, and banner CTA cannot disagree about whether a
/// selected model is available.
enum ChatModelEntryResolver {
    /// The visible picker label. Duplicate display names get a stable parent
    /// suffix so selecting either copy remains unambiguous after relaunch.
    static func pickerLabel(
        for entry: ModelLibrary.ModelEntry,
        in entries: [ModelLibrary.ModelEntry]
    ) -> String {
        let duplicateCount = entries.filter { $0.displayName == entry.displayName }.count
        guard duplicateCount > 1 else { return entry.displayName }
        let parent = entry.canonicalPath.deletingLastPathComponent().lastPathComponent
        return parent.isEmpty ? entry.displayName : "\(entry.displayName) (\(parent))"
    }

    /// Resolve an alias, falling back to a persisted model path only when the
    /// alias is absent or ambiguous. An explicit chat-level alias therefore
    /// continues to win over stale historical metadata, while a stored path
    /// safely breaks ties between two models with the same basename.
    static func resolve(
        alias: String?,
        modelPath: String? = nil,
        in entries: [ModelLibrary.ModelEntry]
    ) -> ModelLibrary.ModelEntry? {
        guard !entries.isEmpty else { return nil }

        if let alias,
           let directPath = uniquePathMatch(for: alias, in: entries) {
            return directPath
        }

        if let normalizedAlias = normalizedName(alias) {
            if let labelMatch = uniqueMatch(in: entries, where: { entry in
                normalizedName(pickerLabel(for: entry, in: entries)) == normalizedAlias
            }) {
                return labelMatch
            }
            if let displayNameMatch = uniqueMatch(in: entries, where: { entry in
                normalizedName(entry.displayName) == normalizedAlias
            }) {
                return displayNameMatch
            }
            if let basenameMatch = uniqueMatch(in: entries, where: { entry in
                entryBasenameAliases(entry).contains(normalizedAlias)
            }) {
                return basenameMatch
            }
        }

        if let modelPath,
           let storedPathMatch = uniquePathMatch(for: modelPath, in: entries) {
            return storedPathMatch
        }
        return nil
    }

    /// Convert the request's model field into stable chat metadata. A raw HF
    /// snapshot path ends in `main` (or a commit hash), which is useful to
    /// the loader but meaningless in the sidebar. When the library knows the
    /// model, persist its display name and canonical directory instead.
    static func persistedIdentity(
        alias: String?,
        fallbackModelPath: String?,
        in entries: [ModelLibrary.ModelEntry]
    ) -> ChatModelIdentity? {
        let cleanedAlias = nonEmpty(alias)
        let cleanedFallbackPath = nonEmpty(fallbackModelPath)

        if let alias = cleanedAlias {
            if let entry = resolve(alias: alias, in: entries) {
                return identity(for: entry)
            }
            // A legacy chat may have stored `main`, the last component of
            // an HF snapshot path. It is safe to use the fallback path only
            // when the two explicitly agree; otherwise an unknown remote
            // alias must not be mislabeled as whichever local model happens
            // to be globally selected.
            if let fallbackPath = cleanedFallbackPath,
               aliasMatchesPathBasename(alias, path: fallbackPath),
               let entry = resolve(alias: alias, modelPath: fallbackPath, in: entries) {
                return identity(for: entry)
            }
        } else if let fallbackPath = cleanedFallbackPath,
                  let entry = resolve(
                      alias: fallbackPath,
                      modelPath: fallbackPath,
                      in: entries
                  ) {
            return identity(for: entry)
        }

        // Preserve remote aliases as written. For a local path that raced a
        // library scan, still avoid storing the HF cache's `main` leaf.
        if let alias = cleanedAlias {
            if let path = normalizedPath(alias) {
                return ChatModelIdentity(
                    name: readableName(forCanonicalPath: path),
                    path: path
                )
            }
            return ChatModelIdentity(name: alias, path: nil)
        }
        if let path = cleanedFallbackPath.flatMap(normalizedPath) {
            return ChatModelIdentity(
                name: readableName(forCanonicalPath: path),
                path: path
            )
        }
        return nil
    }

    private static func identity(for entry: ModelLibrary.ModelEntry) -> ChatModelIdentity {
        ChatModelIdentity(
            name: entry.displayName,
            path: entry.canonicalPath.standardizedFileURL.resolvingSymlinksInPath().path
        )
    }

    private static func uniquePathMatch(
        for rawPath: String,
        in entries: [ModelLibrary.ModelEntry]
    ) -> ModelLibrary.ModelEntry? {
        guard let normalizedPath = normalizedPath(rawPath) else { return nil }
        return uniqueMatch(in: entries) {
            $0.canonicalPath.standardizedFileURL.resolvingSymlinksInPath().path == normalizedPath
        }
    }

    private static func uniqueMatch(
        in entries: [ModelLibrary.ModelEntry],
        where predicate: (ModelLibrary.ModelEntry) -> Bool
    ) -> ModelLibrary.ModelEntry? {
        let matches = entries.filter(predicate)
        return matches.count == 1 ? matches[0] : nil
    }

    private static func normalizedName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.lowercased()
    }

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func aliasMatchesPathBasename(_ alias: String, path: String) -> Bool {
        guard let canonicalPath = normalizedPath(path),
              let normalizedAlias = normalizedName(alias) else { return false }
        let leaf = URL(fileURLWithPath: canonicalPath).lastPathComponent
        return normalizedName(leaf) == normalizedAlias
    }

    private static func normalizedPath(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let url: URL
        if trimmed.hasPrefix("file://") {
            guard let fileURL = URL(string: trimmed), fileURL.isFileURL else { return nil }
            url = fileURL
        } else {
            guard trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else { return nil }
            url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        return url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Names which are safe to treat as a short alias. We intentionally do
    /// not expose cache plumbing such as `snapshots` or `main`: a basename
    /// match must describe the model, not a common directory every model has.
    private static func entryBasenameAliases(_ entry: ModelLibrary.ModelEntry) -> Set<String> {
        var aliases = Set<String>()
        let displayLeaf = (entry.displayName as NSString).lastPathComponent
        if let normalized = normalizedName(displayLeaf) {
            aliases.insert(normalized)
        }

        let leaf = entry.canonicalPath.lastPathComponent
        if !isStructuralPathComponent(leaf), let normalized = normalizedName(leaf) {
            aliases.insert(normalized)
        }

        // Hugging Face cache entries live below
        // `models--<org>--<repo>/snapshots/<revision>`. Preserve both the
        // full readable repo identity and its basename for old chats that
        // recorded only `repo` before the library learned the org prefix.
        for component in entry.canonicalPath.pathComponents where component.hasPrefix("models--") {
            let slug = String(component.dropFirst("models--".count))
            guard let separator = slug.range(of: "--") else { continue }
            let org = String(slug[..<separator.lowerBound])
            let repo = String(slug[separator.upperBound...])
            if let normalized = normalizedName("\(org)/\(repo)") {
                aliases.insert(normalized)
            }
            if let normalized = normalizedName(repo) {
                aliases.insert(normalized)
            }
        }
        return aliases
    }

    private static func isStructuralPathComponent(_ component: String) -> Bool {
        let structural: Set<String> = [
            "snapshots", "refs", "blobs", "main", "hub", "huggingface", "cache", ".cache",
        ]
        return structural.contains(component.lowercased()) || looksLikeHash(component)
    }

    private static func looksLikeHash(_ value: String) -> Bool {
        value.count >= 40 && value.count <= 64 && value.allSatisfy(\.isHexDigit)
    }

    private static func readableName(forCanonicalPath path: String) -> String {
        let url = URL(fileURLWithPath: path)
        for component in url.pathComponents where component.hasPrefix("models--") {
            let slug = String(component.dropFirst("models--".count))
            guard let separator = slug.range(of: "--") else { continue }
            let org = String(slug[..<separator.lowerBound])
            let repo = String(slug[separator.upperBound...])
            if !org.isEmpty, !repo.isEmpty { return "\(org)/\(repo)" }
        }

        var cursor = url
        while cursor.path != "/" {
            let component = cursor.lastPathComponent
            if !component.isEmpty, !isStructuralPathComponent(component) {
                return component
            }
            cursor.deleteLastPathComponent()
        }
        return url.lastPathComponent
    }
}
