import Foundation
import UniformTypeIdentifiers

actor AnalysisCoordinator {
    private let avAnalyzer = AVFoundationAnalyzer()
    private let ffmpegAnalyzer = FFmpegAnalyzer()
    private var concurrencyLimit: Int = 2

    private static let avFoundationExtensions: Set<String> = [
        "mov", "mp4", "m4v", "m4a", "wav", "aiff", "aif", "mp3", "ts", "mts", "aac"
    ]

    private static let ffmpegExtensions: Set<String> = [
        "mkv", "webm", "avi", "flv", "wmv", "ogg", "ogv", "vob"
    ]

    func setConcurrencyLimit(_ limit: Int) {
        concurrencyLimit = limit
    }

    func detectFFmpeg() async -> Bool {
        await ffmpegAnalyzer.detectInstallation()
    }

    func setFFmpegPath(_ path: String) async {
        await ffmpegAnalyzer.setCustomPath(path)
    }

    func engineFor(url: URL) async -> AnalysisEngine? {
        let ext = url.pathExtension.lowercased()
        if Self.avFoundationExtensions.contains(ext) {
            return .avFoundation
        }
        if Self.ffmpegExtensions.contains(ext) {
            let available = await ffmpegAnalyzer.isAvailable
            return available ? .ffmpeg : nil
        }
        return .avFoundation
    }

    func analyzeFile(_ file: MediaFile, progressHandler: @Sendable (AnalysisProgress) -> Void) async -> AnalysisResult {
        let start = Date()

        guard let engine = await engineFor(url: file.url) else {
            let issue = MediaIssue(
                type: .unsupportedCodec,
                severity: .error,
                description: "ffmpeg not found — install via Homebrew to analyze this file type"
            )
            return AnalysisResult(
                fileID: file.id,
                status: .error,
                issues: [issue],
                duration: Date().timeIntervalSince(start),
                engineUsed: .ffmpeg
            )
        }

        do {
            switch engine {
            case .avFoundation:
                return try await avAnalyzer.analyze(file: file, progressHandler: progressHandler)
            case .ffmpeg:
                return try await ffmpegAnalyzer.analyze(file: file)
            }
        } catch {
            let issue = MediaIssue(
                type: .other,
                severity: .error,
                description: error.localizedDescription
            )
            return AnalysisResult(
                fileID: file.id,
                status: .error,
                issues: [issue],
                duration: Date().timeIntervalSince(start),
                engineUsed: engine
            )
        }
    }

    func analyzeFiles(_ files: [MediaFile], progressHandler: @escaping @Sendable (MediaFile, AnalysisProgress) -> Void) async -> [AnalysisResult] {
        var results: [AnalysisResult] = []

        await withTaskGroup(of: AnalysisResult.self) { group in
            var index = 0

            for _ in 0..<min(concurrencyLimit, files.count) {
                let file = files[index]
                index += 1
                group.addTask { [self] in
                    await self.analyzeFile(file) { progress in
                        progressHandler(file, progress)
                    }
                }
            }

            for await result in group {
                results.append(result)
                if index < files.count {
                    let file = files[index]
                    index += 1
                    group.addTask { [self] in
                        await self.analyzeFile(file) { progress in
                            progressHandler(file, progress)
                        }
                    }
                }
            }
        }

        return results
    }
}
