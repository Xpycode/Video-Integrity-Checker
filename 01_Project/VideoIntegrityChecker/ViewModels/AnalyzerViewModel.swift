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
    private var batchTask: Task<Void, Never>?

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
        // C5: Wire stored settings into the coordinator
        let storedPath = UserDefaults.standard.string(forKey: "ffmpegPath") ?? ""
        let storedLimit = UserDefaults.standard.integer(forKey: "concurrencyLimit")

        if !storedPath.isEmpty {
            coordinator.setFFmpegPath(storedPath)
        }

        let limit = max(1, min(storedLimit == 0 ? 2 : storedLimit, 8))
        coordinator.setConcurrencyLimit(limit)

        ffmpegAvailable = coordinator.detectFFmpeg()
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

    // C1: Use the coordinator's sliding-window batch API instead of spawning one Task per file
    func analyzeAllPending() {
        let pendingFiles = entries.compactMap { entry -> MediaFile? in
            guard entry.result == nil && !entry.isAnalyzing else { return nil }
            return entry.file
        }
        guard !pendingFiles.isEmpty else { return }

        for file in pendingFiles {
            if let idx = entries.firstIndex(where: { $0.id == file.id }) {
                entries[idx].isAnalyzing = true
            }
        }
        isAnalyzing = true

        batchTask = Task { [weak self] in
            guard let self else { return }

            let results = await self.coordinator.analyzeFiles(pendingFiles) { file, progress in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let idx = self.entries.firstIndex(where: { $0.id == file.id }) {
                        self.entries[idx].progress = progress
                    }
                }
            }

            for result in results {
                if let idx = self.entries.firstIndex(where: { $0.id == result.fileID }) {
                    self.entries[idx].result = result
                    self.entries[idx].isAnalyzing = false
                    self.entries[idx].progress = nil
                }
            }

            self.isAnalyzing = false
            self.batchTask = nil
        }
    }

    func cancelAnalysis(for id: UUID) {
        cancelAll()
    }

    func cancelAll() {
        batchTask?.cancel()
        batchTask = nil
        for i in entries.indices where entries[i].isAnalyzing {
            entries[i].isAnalyzing = false
            entries[i].progress = nil
        }
        isAnalyzing = false
    }

    func reanalyze(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        cancelAll()
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
