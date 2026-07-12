import Foundation

/// Normalizes fenced-code language tags for display (e.g. `py` → `Python`).
enum MarkdownLanguage {
    private static let map: [String: String] = [
        "py": "Python", "python": "Python",
        "js": "JavaScript", "javascript": "JavaScript", "ts": "TypeScript", "typescript": "TypeScript",
        "tsx": "TSX", "jsx": "JSX",
        "rb": "Ruby", "ruby": "Ruby",
        "rs": "Rust", "rust": "Rust",
        "go": "Go", "golang": "Go",
        "c": "C", "cpp": "C++", "cxx": "C++", "cc": "C++", "c++": "C++",
        "cs": "C#", "csharp": "C#",
        "java": "Java", "kt": "Kotlin", "kotlin": "Kotlin", "swift": "Swift",
        "sh": "Shell", "bash": "Shell", "zsh": "Shell", "shell": "Shell",
        "ps1": "PowerShell", "powershell": "PowerShell",
        "sql": "SQL", "html": "HTML", "css": "CSS", "scss": "SCSS",
        "json": "JSON", "yaml": "YAML", "yml": "YAML", "toml": "TOML", "xml": "XML",
        "md": "Markdown", "markdown": "Markdown",
        "r": "R", "lua": "Lua", "php": "PHP", "perl": "Perl",
        "text": "Plain text", "txt": "Plain text", "plain": "Plain text",
    ]

    static func displayName(for raw: String) -> String {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key.isEmpty { return "Code" }
        return map[key] ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Table clipboard helpers.
enum MarkdownTableClipboard {
    static func asMarkdown(
        headers: [String],
        alignments: [MarkdownTableAlignment],
        rows: [[String]]
    ) -> String {
        func escape(_ cell: String) -> String {
            cell.replacingOccurrences(of: "|", with: "\\|")
        }
        var lines: [String] = []
        lines.append("| " + headers.map(escape).joined(separator: " | ") + " |")
        let delim = alignments.map { alignment -> String in
            switch alignment {
            case .leading: return ":---"
            case .center: return ":---:"
            case .trailing: return "---:"
            }
        }
        lines.append("| " + delim.joined(separator: " | ") + " |")
        for row in rows {
            lines.append("| " + row.map(escape).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func asTSV(headers: [String], rows: [[String]]) -> String {
        func cell(_ value: String) -> String {
            value
                .replacingOccurrences(of: "\t", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
        }
        var lines = [headers.map(cell).joined(separator: "\t")]
        for row in rows {
            lines.append(row.map(cell).joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
