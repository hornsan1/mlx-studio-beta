import Foundation
#if canImport(PDFKit)
import PDFKit
#endif

/// Extracted local document text queued for the next chat turn. Codable so a
/// composer draft survives an app restart just like its text and media.
struct ChatDocumentAttachment: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var text: String
    var sourceByteCount: Int
}

enum ChatDocumentError: LocalizedError {
    case unsupported(String)
    case unreadable(String)
    case empty(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name): return "\(name) is not a supported PDF, DOCX, or text document."
        case .unreadable(let name): return "\(name) could not be read."
        case .empty(let name): return "\(name) does not contain extractable text."
        }
    }
}

enum ChatDocumentExtractor {
    static func extract(from url: URL) throws -> ChatDocumentAttachment {
        let ext = url.pathExtension.lowercased()
        let text: String
        switch ext {
        case "txt", "md", "text", "csv", "tsv", "json":
            let data = try Data(contentsOf: url)
            text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
                ?? ""
        case "pdf":
            #if canImport(PDFKit)
            text = PDFDocument(url: url)?.string ?? ""
            #else
            throw ChatDocumentError.unsupported(url.lastPathComponent)
            #endif
        case "docx":
            text = try extractDOCX(url)
        default:
            throw ChatDocumentError.unsupported(url.lastPathComponent)
        }

        let cleaned = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw ChatDocumentError.empty(url.lastPathComponent) }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ChatDocumentAttachment(
            name: url.lastPathComponent,
            text: cleaned,
            sourceByteCount: size
        )
    }

    private static func extractDOCX(_ url: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "word/document.xml"]
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ChatDocumentError.unreadable(url.lastPathComponent)
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let delegate = WordXMLTextCollector()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw ChatDocumentError.unreadable(url.lastPathComponent) }
        return delegate.text
    }
}

private final class WordXMLTextCollector: NSObject, XMLParserDelegate {
    private(set) var text = ""

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "w:p" || elementName == "w:tr" { text += "\n" }
        if elementName == "w:tab" { text += "\t" }
    }
}

/// Inserts small documents verbatim. Oversized documents use deterministic,
/// local extractive retrieval: paragraphs/chunks are ranked against the user's
/// prompt and only the best-fitting excerpts enter model context.
enum ChatDocumentContext {
    static let directCharacterLimit = 48_000
    static let totalCharacterBudget = 64_000
    private static let chunkSize = 2_400

    static func render(
        documents: [ChatDocumentAttachment],
        query: String
    ) -> String {
        guard !documents.isEmpty else { return "" }
        var remaining = totalCharacterBudget
        var sections: [String] = []
        for document in documents where remaining > 0 {
            let body: String
            let mode: String
            if document.text.count <= directCharacterLimit {
                body = String(document.text.prefix(remaining))
                mode = "full document"
            } else {
                body = retrievedExcerpt(
                    from: document.text,
                    query: query,
                    limit: min(remaining, directCharacterLimit)
                )
                mode = "locally retrieved excerpts from oversized document"
            }
            guard !body.isEmpty else { continue }
            sections.append("[Document: \(document.name) — \(mode)]\n\(body)\n[End document]")
            remaining -= body.count
        }
        return sections.joined(separator: "\n\n")
    }

    private static func retrievedExcerpt(from text: String, query: String, limit: Int) -> String {
        let chunks = chunk(text)
        let terms = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count > 2 }
            .map(String.init))
        let ranked = chunks.enumerated().sorted { lhs, rhs in
            let left = score(lhs.element, terms: terms)
            let right = score(rhs.element, terms: terms)
            return left == right ? lhs.offset < rhs.offset : left > right
        }
        var selected: [(Int, String)] = []
        var used = 0
        for item in ranked {
            guard used < limit else { break }
            let excerpt = String(item.element.prefix(limit - used))
            selected.append((item.offset, excerpt))
            used += excerpt.count
        }
        return selected.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: "\n\n[…]\n\n")
    }

    private static func score(_ chunk: String, terms: Set<String>) -> Int {
        guard !terms.isEmpty else { return 0 }
        let lower = chunk.lowercased()
        return terms.reduce(0) { result, term in
            result + lower.components(separatedBy: term).count - 1
        }
    }

    private static func chunk(_ text: String) -> [String] {
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }
}
