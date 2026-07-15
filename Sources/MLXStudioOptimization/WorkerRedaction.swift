import Foundation

struct WorkerRedactor: Sendable {
    private let homePath: String
    private let secrets: [String]

    init(homePath: String, secrets: [String]) {
        self.homePath = homePath
        self.secrets = secrets.filter { !$0.isEmpty }.sorted { $0.count > $1.count }
    }

    func redact(_ input: String) -> String {
        var output = input
        if !homePath.isEmpty {
            output = output.replacingOccurrences(of: homePath, with: "<HOME>")
        }
        for secret in secrets {
            output = output.replacingOccurrences(of: secret, with: "<REDACTED>")
        }
        output = replacing(
            pattern: #"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#,
            in: output,
            template: "Bearer <REDACTED>"
        )
        output = replacing(
            pattern: #"(?i)hf_[A-Za-z0-9]{8,}"#,
            in: output,
            template: "<REDACTED>"
        )
        output = replacing(
            pattern: #"(?i)((?:api[_-]?key|token)\s*[=:]\s*)[^\s,;]+"#,
            in: output,
            template: "$1<REDACTED>"
        )
        return output
    }

    func command(executable: URL, arguments: [String]) -> String {
        ([executable.path] + arguments)
            .map { shellQuote(redact($0)) }
            .joined(separator: " ")
    }

    private func replacing(pattern: String, in input: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return input }
        let range = NSRange(input.startIndex..<input.endIndex, in: input)
        return regex.stringByReplacingMatches(
            in: input,
            range: range,
            withTemplate: template
        )
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct BoundedWorkerLog: Sendable {
    let capacity: Int
    private(set) var value = ""

    init(capacity: Int) {
        self.capacity = max(0, capacity)
    }

    mutating func append(_ line: String) {
        guard capacity > 0 else { return }
        if !value.isEmpty { value.append("\n") }
        value.append(line)
        if value.count > capacity {
            value = String(value.suffix(capacity))
        }
    }
}
