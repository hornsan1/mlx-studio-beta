// SPDX-License-Identifier: Apache-2.0
//
// Chat → Markdown / JSON exporter. Converts a `ChatSession` + its
// `[ChatMessage]` list into portable formats. Markdown is a human-readable
// non-lossless transcript; JSON v4 is the round-trip archive contract.

import Foundation
import vMLXEngine

enum ChatExporter {

    // MARK: - Markdown transcript (non-lossless)

    /// Human-readable transcript. Labels itself as non-lossless and uses
    /// dynamically sized fences so embedded triple-backticks do not corrupt
    /// the export.
    static func exportToMarkdown(_ session: ChatSession,
                                 messages: [ChatMessage]) -> String {
        var out = ""
        out += "# \(session.title.isEmpty ? "Untitled chat" : session.title)\n\n"
        out += "> **MLX Studio Markdown transcript** — human-readable, not a "
        out += "lossless database backup. Prefer JSON export for round-trip.\n\n"

        let dateStr = Self.dateFormatter.string(from: session.createdAt)
        let modelLabel = Self.modelLabel(for: session)

        out += "> Created: \(dateStr)  \n"
        out += "> Model: \(modelLabel)  \n"
        out += "> Messages: \(messages.count)\n\n"
        out += "---\n\n"

        for (idx, msg) in messages.enumerated() {
            out += renderMessage(msg)
            if idx < messages.count - 1 {
                out += "\n---\n\n"
            }
        }
        if !out.hasSuffix("\n") { out += "\n" }
        return out
    }

    private static func renderMessage(_ m: ChatMessage) -> String {
        var s = ""
        let header: String
        switch m.role {
        case .user:      header = "## User"
        case .assistant: header = "## Assistant"
        case .system:    header = "## System"
        case .tool:      header = "## Tool"
        }
        s += header + "\n"

        if let state = m.generationState {
            s += "_Generation: \(state.rawValue)_\n\n"
        }

        let content = m.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            s += content + "\n"
        } else {
            s += "_(empty)_\n"
        }

        // Document context is model-only — note presence, do not dump full text
        // into the human transcript by default.
        if !m.requestContext.isEmpty {
            s += "\n_Document request context attached (\(m.requestContext.count) characters; see JSON export)_\n"
        }

        if !m.imageData.isEmpty {
            s += "\n_\(m.imageData.count) image\(m.imageData.count == 1 ? "" : "s") attached (see JSON export for base64 payload)_\n"
        }
        if !m.videoPaths.isEmpty {
            s += "\n_Videos attached:_\n"
            for p in m.videoPaths {
                s += "- `\(p)`\n"
            }
        }

        if let reasoning = m.reasoning, !reasoning.isEmpty {
            s += "\n### Reasoning (collapsed in chat)\n"
            s += fenced("text", reasoning)
        }

        if let tcJSON = m.toolCallsJSON, !tcJSON.isEmpty {
            s += "\n### Tool calls\n"
            s += fenced("json", tcJSON)
        }
        return s
    }

    /// Fence long enough that embedded backticks cannot close early.
    /// Shared by production chat export and Studio Library summary embed
    /// (`StudioChatSessionExporter.summaryMarkdown` / `embedBody`).
    static func fenced(_ language: String, _ body: String) -> String {
        var ticks = 3
        while body.contains(String(repeating: "`", count: ticks)) {
            ticks += 1
        }
        let fence = String(repeating: "`", count: ticks)
        var out = fence
        if !language.isEmpty { out += language }
        out += "\n"
        out += body
        if !body.hasSuffix("\n") { out += "\n" }
        out += fence + "\n"
        return out
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func modelLabel(for session: ChatSession) -> String {
        if let name = session.modelName, !name.isEmpty { return name }
        if let mp = session.modelPath, !mp.isEmpty {
            return (mp as NSString).lastPathComponent
        }
        return "(unspecified)"
    }

    // MARK: - JSON export (v4)

    /// Structured export. Version 4 declares `contentFormat: "gfm"`, splits
    /// `displayContent` / `requestContext`, and records generation state.
    /// Versions 1–3 remain importable via `ChatImporter`.
    static func exportToJSON(_ session: ChatSession,
                             messages: [ChatMessage]) -> String {
        struct ExportEnvelope: Encodable {
            let version: Int
            let contentFormat: String
            let exportedAt: String
            let session: SessionBlock
            let messages: [MessageBlock]
        }
        struct SessionBlock: Encodable {
            let id: String
            let title: String
            let createdAt: String
            let model: String
            let modelName: String?
            let modelPath: String?
            let isPinned: Bool
            let collectionName: String?
        }
        struct MessageBlock: Encodable {
            let role: String
            let content: String
            let displayContent: String
            let requestContext: String?
            let contentFormat: String
            let reasoning: String?
            let toolCallsJSON: String?
            let imagesBase64: [String]?
            let videoPaths: [String]?
            let toolStatuses: [String: ToolCallStatus]?
            let generationState: String?
            let createdAt: String
        }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let modelLabel = Self.modelLabel(for: session)

        let envelope = ExportEnvelope(
            version: 4,
            contentFormat: "gfm",
            exportedAt: iso.string(from: Date()),
            session: .init(
                id: session.id.uuidString,
                title: session.title.isEmpty ? "Untitled chat" : session.title,
                createdAt: iso.string(from: session.createdAt),
                model: modelLabel,
                modelName: session.modelName?.isEmpty == false ? session.modelName : nil,
                modelPath: session.modelPath?.isEmpty == false ? session.modelPath : nil,
                isPinned: session.isPinned,
                collectionName: session.collectionName?.isEmpty == false ? session.collectionName : nil
            ),
            messages: messages.map { m in
                MessageBlock(
                    role: {
                        switch m.role {
                        case .user: return "user"
                        case .assistant: return "assistant"
                        case .system: return "system"
                        case .tool: return "tool"
                        }
                    }(),
                    content: m.content,
                    displayContent: m.content,
                    requestContext: m.requestContext.isEmpty ? nil : m.requestContext,
                    contentFormat: "gfm",
                    reasoning: m.reasoning?.isEmpty == false ? m.reasoning : nil,
                    toolCallsJSON: m.toolCallsJSON?.isEmpty == false
                        ? m.toolCallsJSON : nil,
                    imagesBase64: m.imageData.isEmpty
                        ? nil
                        : m.imageData.map { $0.base64EncodedString() },
                    videoPaths: m.videoPaths.isEmpty ? nil : m.videoPaths,
                    toolStatuses: m.toolStatuses.isEmpty ? nil : m.toolStatuses,
                    generationState: m.generationState?.rawValue,
                    createdAt: iso.string(from: m.createdAt)
                )
            }
        )

        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(envelope),
           let str = String(data: data, encoding: .utf8) {
            return str + "\n"
        }
        return "{\"version\": 1, \"error\": \"encode_failed\"}\n"
    }
}
