import SwiftUI

struct FileEntry: Identifiable {
    let id: UUID
    let file: MediaFile
    var result: AnalysisResult?
    var progress: AnalysisProgress?
    var isAnalyzing: Bool
}

struct FileListView: View {
    let entries: [FileEntry]
    @Binding var selectedFileID: UUID?
    let onRemove: (UUID) -> Void

    var body: some View {
        Table(entries, selection: $selectedFileID) {
            TableColumn("") { entry in
                StatusIconView(entry: entry)
            }
            .width(min: 30, ideal: 30, max: 30)

            TableColumn("Name", value: \.file.fileName)
                .width(min: 120, ideal: 300)

            TableColumn("Format") { entry in
                Text(entry.file.formatInfo ?? "—")
            }
            .width(min: 50, ideal: 70, max: 90)

            TableColumn("Duration") { entry in
                Text(entry.result?.metadata?.durationFormatted ?? "—")
            }
            .width(min: 70, ideal: 85, max: 100)

            TableColumn("Size") { entry in
                Text(entry.file.fileSizeFormatted)
            }
            .width(min: 60, ideal: 80, max: 100)

            TableColumn("Issues") { entry in
                if let result = entry.result {
                    IssuesBadgeView(result: result)
                } else if entry.isAnalyzing {
                    if let pct = entry.progress?.percentage {
                        ProgressView(value: pct)
                            .frame(width: 60)
                    } else {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                } else {
                    Text("—")
                }
            }
            .width(min: 60, ideal: 80, max: 100)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            if let id = ids.first {
                Button("Remove", role: .destructive) { onRemove(id) }
            }
        } primaryAction: { _ in
        }
    }
}

private struct StatusIconView: View {
    let entry: FileEntry

    var body: some View {
        if entry.isAnalyzing {
            ProgressView()
                .scaleEffect(0.5)
        } else if let result = entry.result {
            switch result.status {
            case .healthy:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .warning:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .error:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        } else {
            Image(systemName: "minus.circle")
                .foregroundStyle(.secondary)
        }
    }
}

private struct IssuesBadgeView: View {
    let result: AnalysisResult

    var body: some View {
        HStack(spacing: 4) {
            if result.errorCount > 0 {
                Label("\(result.errorCount)", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
            if result.warningCount > 0 {
                Label("\(result.warningCount)", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if result.errorCount == 0 && result.warningCount == 0 {
                Text("Clean")
                    .foregroundStyle(.green)
            }
        }
        .font(.caption)
    }
}
