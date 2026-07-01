import Foundation
import vMLXEngine

enum ImageHistoryRecordState {
    enum Tone: Equatable {
        case active
        case success
        case warning
        case danger
        case muted
    }

    struct Summary: Equatable {
        var label: String
        var systemImage: String
        var tone: Tone
    }

    static func summary(
        for record: ImageGenerationRecord,
        outputExists explicitOutputExists: Bool? = nil
    ) -> Summary {
        let outputExists = explicitOutputExists ?? recordOutputExists(record)
        if record.status == .completed, !outputExists {
            return Summary(
                label: "Missing file",
                systemImage: "doc.badge.exclamationmark",
                tone: .warning
            )
        }

        switch record.status {
        case .pending:
            return Summary(label: "Rendering", systemImage: "circle.dotted", tone: .active)
        case .completed:
            return Summary(label: "Ready output", systemImage: "checkmark.circle.fill", tone: .success)
        case .failed:
            return Summary(label: "Failed output", systemImage: "exclamationmark.triangle.fill", tone: .danger)
        case .cancelled:
            return Summary(label: "Cancelled", systemImage: "xmark.circle", tone: .muted)
        }
    }

    private static func recordOutputExists(_ record: ImageGenerationRecord) -> Bool {
        guard let outputPath = record.outputPath else { return false }
        return FileManager.default.fileExists(atPath: outputPath)
    }
}
