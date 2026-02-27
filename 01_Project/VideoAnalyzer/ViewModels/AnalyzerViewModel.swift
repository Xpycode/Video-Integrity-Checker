import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class AnalyzerViewModel {
    private(set) var entries: [FileEntry] = []
    var selectedFileID: UUID?
    private(set) var isAnalyzing: Bool = false
    private(set) var ffmpegAvailable: Bool = false

    private let coordinator = AnalysisCoordinator()
    private var analysisTasks: [UUID: Task<Void, Never>] = [:]

    var selectedEntry: FileEntry? {
        guard let id = selectedFileID else { return nil }
        return entries.first { $0.id == id }
    }

    var overallProgress: String {
        let total = entries.count
        let done = entries.filter { $0.result != nil }.count
        let analyzing = entries.filter { $0.isAnalyzing }.count
        if analyzing > 0 { return "Analyzing \(analyzing) of \(total)..." }
        if done == total && total > 0 { return "All \(total) files analyzed" }
        return "\(done)/\(total) analyzed"
    }

    func setup() async {
        ffmpegAvailable = await coordinator.detectFFmpeg()
    }

    func addFiles(urls: [URL]) {
        let fm = FileManager.default
        for url in urls {
            guard !entries.contains(where: { $0.file.url == url }) else { continue }

            let attributes = try? fm.attributesOfItem(atPath: url.path)
            let fileSize = attributes?[.size] as? Int64 ?? 0
            let modDate = attributes?[.modificationDate] as? Date
            let formatInfo = url.pathExtension.uppercased()

            if fileSize == 0 {
                let file = MediaFile(url: url, fileSize: 0, formatInfo: formatInfo.isEmpty ? nil : formatInfo)
                let issue = MediaIssue(type: .other, severity: .error, description: "File is empty (0 bytes)")
                let result = AnalysisResult(fileID: file.id, status: .error, issues: [issue], duration: 0, engineUsed: .avFoundation)
                let entry = FileEntry(id: file.id, file: file, result: result, progress: nil, isAnalyzing: false)
                entries.append(entry)
                continue
            }

            if !FileManager.default.isReadableFile(atPath: url.path) {
                let file = MediaFile(url: url, fileSize: fileSize, formatInfo: formatInfo.isEmpty ? nil : formatInfo)
                let issue = MediaIssue(type: .other, severity: .error, description: "File is not readable — check permissions")
                let result = AnalysisResult(fileID: file.id, status: .error, issues: [issue], duration: 0, engineUsed: .avFoundation)
                let entry = FileEntry(id: file.id, file: file, result: result, progress: nil, isAnalyzing: false)
                entries.append(entry)
                continue
            }

            let file = MediaFile(
                url: url,
                fileSize: fileSize,
                modificationDate: modDate,
                formatInfo: formatInfo.isEmpty ? nil : formatInfo
            )
            let entry = FileEntry(id: file.id, file: file, result: nil, progress: nil, isAnalyzing: false)
            entries.append(entry)
        }

        analyzeAllPending()
    }

    func analyzeAllPending() {
        for i in entries.indices where entries[i].result == nil && !entries[i].isAnalyzing {
            let entry = entries[i]
            entries[i].isAnalyzing = true

            let task = Task { [weak self] in
                guard let self else { return }
                let result = await self.coordinator.analyzeFile(entry.file) { progress in
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        if let idx = self.entries.firstIndex(where: { $0.id == entry.id }) {
                            self.entries[idx].progress = progress
                        }
                    }
                }
                if let idx = self.entries.firstIndex(where: { $0.id == entry.id }) {
                    self.entries[idx].result = result
                    self.entries[idx].isAnalyzing = false
                    self.entries[idx].progress = nil
                }
                self.analysisTasks[entry.id] = nil
            }
            analysisTasks[entry.id] = task
        }
    }

    func cancelAnalysis(for id: UUID) {
        analysisTasks[id]?.cancel()
        analysisTasks[id] = nil
        if let idx = entries.firstIndex(where: { $0.id == id }) {
            entries[idx].isAnalyzing = false
            entries[idx].progress = nil
        }
    }

    func cancelAll() {
        for (id, task) in analysisTasks {
            task.cancel()
            if let idx = entries.firstIndex(where: { $0.id == id }) {
                entries[idx].isAnalyzing = false
                entries[idx].progress = nil
            }
        }
        analysisTasks.removeAll()
    }

    func reanalyze(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        cancelAnalysis(for: id)
        entries[idx].result = nil
        entries[idx].progress = nil
        analyzeAllPending()
    }

    func removeFile(id: UUID) {
        cancelAnalysis(for: id)
        entries.removeAll { $0.id == id }
        if selectedFileID == id { selectedFileID = nil }
    }

    func clearAll() {
        cancelAll()
        entries.removeAll()
        selectedFileID = nil
    }
}
