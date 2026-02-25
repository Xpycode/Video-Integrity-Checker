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
        "mkv", "webm", "avi", "flv", "wmv", "ogg", "ogv", "vob",
        "mxf"
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

        // Phase 1: Container inspection (pre-pass)
        var containerIssues: [MediaIssue] = []
        do {
            if let report = try await ContainerInspectorRegistry.inspect(url: file.url) {
                // report.metadata will be used for container detail display in a future update
                containerIssues = report.issues.map { $0.toMediaIssue() }
            }
        } catch {
            containerIssues.append(MediaIssue(
                type: .containerStructure,
                severity: .warning,
                description: "Container inspection failed: \(error.localizedDescription)"
            ))
        }

        // Phase 2: Decode analysis
        guard let engine = await engineFor(url: file.url) else {
            let issue = MediaIssue(
                type: .unsupportedCodec,
                severity: .error,
                description: "ffmpeg not found — install via Homebrew to analyze this file type"
            )
            return AnalysisResult(
                fileID: file.id,
                status: .error,
                issues: containerIssues + [issue],
                duration: Date().timeIntervalSince(start),
                engineUsed: .ffmpeg
            )
        }

        do {
            var result: AnalysisResult
            switch engine {
            case .avFoundation:
                result = try await avAnalyzer.analyze(file: file, progressHandler: progressHandler)
            case .ffmpeg:
                result = try await ffmpegAnalyzer.analyze(file: file)
            }

            // Merge container issues with decode issues, correlating causes
            if !containerIssues.isEmpty {
                let hasDecodeError = result.issues.contains { $0.type == .decodeError && $0.severity == .error }

                let escalatedContainerIssues: [MediaIssue] = containerIssues.map { issue in
                    // Escalate container metadata warnings to errors when they caused a decode failure
                    if hasDecodeError && issue.type == .containerMetadata && issue.severity == .warning {
                        return MediaIssue(
                            type: issue.type,
                            severity: .error,
                            timestamp: issue.timestamp,
                            frameNumber: issue.frameNumber,
                            description: issue.description + " — This is the likely cause of the decode failure below."
                        )
                    }
                    return issue
                }

                let mergedIssues = escalatedContainerIssues + result.issues

                // Recalculate status with merged issues
                let status: AnalysisStatus
                if mergedIssues.contains(where: { $0.severity == .error }) {
                    status = .error
                } else if mergedIssues.contains(where: { $0.severity == .warning }) {
                    status = .warning
                } else {
                    status = .healthy
                }

                result = AnalysisResult(
                    fileID: result.fileID,
                    status: status,
                    issues: mergedIssues,
                    metadata: result.metadata,
                    analysisDate: result.analysisDate,
                    duration: Date().timeIntervalSince(start),
                    engineUsed: result.engineUsed
                )
            }

            return result
        } catch {
            let issue = MediaIssue(
                type: .other,
                severity: .error,
                description: error.localizedDescription
            )
            return AnalysisResult(
                fileID: file.id,
                status: .error,
                issues: containerIssues + [issue],
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
