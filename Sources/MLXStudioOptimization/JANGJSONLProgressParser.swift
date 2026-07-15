// Adapted from hornsan1/jangq-private@5d5487c27fa81d9f51da27264ae855964e334070
// JANGStudio/JANGStudio/Runner/JSONLProgressParser.swift.
import Foundation
import MLXStudioDomain

enum JANGJSONLParseResult: Equatable {
    case event(OptimizationWorkerEvent)
    case plainText(String)
    case protocolFailure(String)
}

struct JANGJSONLProgressParser {
    private struct RawEvent: Decodable {
        let v: Int?
        let type: String?
        let n: Int?
        let total: Int?
        let name: String?
        let done: Int?
        let label: String?
        let msg: String?
        let ok: Bool?
        let output: String?
        let error: String?
    }

    private let decoder = JSONDecoder()

    func parse(line: String) -> JANGJSONLParseResult {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return .plainText(trimmed) }
        guard let data = trimmed.data(using: .utf8) else {
            return .protocolFailure("Progress event was not valid UTF-8.")
        }
        let raw: RawEvent
        do {
            raw = try decoder.decode(RawEvent.self, from: data)
        } catch {
            return .protocolFailure("Malformed JSONL progress event.")
        }
        let version = raw.v ?? OptimizationWorkerEventEnvelope.currentProtocolVersion
        guard version == OptimizationWorkerEventEnvelope.currentProtocolVersion else {
            return .protocolFailure(
                "Unsupported JSONL protocol version \(version); expected \(OptimizationWorkerEventEnvelope.currentProtocolVersion)."
            )
        }
        switch raw.type {
        case "phase":
            guard let n = raw.n, let total = raw.total, let name = raw.name else {
                return .protocolFailure("Phase event is missing n, total, or name.")
            }
            return .event(.phase(index: n, total: total, name: name))
        case "tick":
            guard let done = raw.done, let total = raw.total else {
                return .protocolFailure("Tick event is missing done or total.")
            }
            return .event(.progress(completed: done, total: total, label: raw.label))
        case "info":
            return .event(.message(level: .info, text: raw.msg ?? ""))
        case "warn":
            return .event(.message(level: .warning, text: raw.msg ?? ""))
        case "error":
            return .event(.message(level: .error, text: raw.msg ?? ""))
        case "done":
            return .event(.toolReportedCompletion(
                ok: raw.ok ?? false,
                output: raw.output,
                error: raw.error
            ))
        default:
            return .protocolFailure("Progress event has an unknown or missing type.")
        }
    }
}
