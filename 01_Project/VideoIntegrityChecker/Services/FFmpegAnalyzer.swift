import Foundation
import CoreGraphics

final class FFmpegAnalyzer: @unchecked Sendable {
    private let lock = NSLock()
    private var _ffmpegPath: String?
    private var _ffprobePath: String?

    private var ffmpegPath: String? {
        lock.withLock { _ffmpegPath }
    }

    private var ffprobePath: String? {
        lock.withLock { _ffprobePath }
    }

    var isAvailable: Bool { ffmpegPath != nil }

    @discardableResult
    func detectInstallation() -> Bool {
        let candidates = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg"
        ]

        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                let dir = URL(fileURLWithPath: candidate).deletingLastPathComponent().path
                let probe = dir + "/ffprobe"
                lock.withLock {
                    _ffmpegPath = candidate
                    _ffprobePath = FileManager.default.isExecutableFile(atPath: probe) ? probe : nil
                }
                return true
            }
        }

        if let found = resolveWhich("ffmpeg") {
            let dir = URL(fileURLWithPath: found).deletingLastPathComponent().path
            let probe = dir + "/ffprobe"
            lock.withLock {
                _ffmpegPath = found
                _ffprobePath = FileManager.default.isExecutableFile(atPath: probe) ? probe : nil
            }
            return true
        }

        return false
    }

    func setCustomPath(_ path: String) {
        guard FileManager.default.isExecutableFile(atPath: path) else { return }
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let probe = dir + "/ffprobe"
        lock.withLock {
            _ffmpegPath = path
            _ffprobePath = FileManager.default.isExecutableFile(atPath: probe) ? probe : nil
        }
    }

    func analyze(file: MediaFile) async throws -> AnalysisResult {
        guard let ffmpegBin = ffmpegPath else {
            throw FFmpegError.notInstalled
        }

        let start = Date()

        var metadata: MediaMetadata?
        if let probeBin = ffprobePath {
            metadata = try? await runFFprobeMetadata(url: file.url, probePath: probeBin)
        }

        let issues = try await runFFmpegAnalysis(url: file.url, ffmpegPath: ffmpegBin)

        let elapsed = Date().timeIntervalSince(start)

        let status: AnalysisStatus
        if issues.contains(where: { $0.severity == .error }) {
            status = .error
        } else if issues.contains(where: { $0.severity == .warning }) {
            status = .warning
        } else {
            status = .healthy
        }

        return AnalysisResult(
            fileID: file.id,
            status: status,
            issues: issues,
            metadata: metadata,
            duration: elapsed,
            engineUsed: .ffmpeg
        )
    }

    private func runFFmpegAnalysis(url: URL, ffmpegPath: String) async throws -> [MediaIssue] {
        let arguments = ["-nostdin", "-v", "error", "-i", url.path, "-f", "null", "-"]

        let result = try await runProcess(ffmpegPath, arguments: arguments)

        let stderr = String(data: result.stderr, encoding: .utf8) ?? ""
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: true)

        var issues: [MediaIssue] = []
        for line in lines {
            let text = String(line).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            let lower = text.lowercased()

            let issueType: IssueType
            let severity: IssueSeverity

            if lower.contains("error") {
                issueType = .decodeError
                severity = .error
            } else if lower.contains("corrupt") {
                issueType = .corruptHeader
                severity = .error
            } else if lower.contains("missing") {
                issueType = .missingTrack
                severity = .warning
            } else if lower.contains("invalid") {
                issueType = .other
                severity = .warning
            } else {
                issueType = .other
                severity = .warning
            }

            issues.append(MediaIssue(type: issueType, severity: severity, description: text))
        }

        // C6: Check ffmpeg exit code — a non-zero exit with no parsed issues means failure
        if result.exitCode != 0 {
            if issues.isEmpty {
                issues.append(MediaIssue(
                    type: .decodeError,
                    severity: .error,
                    description: "ffmpeg exited with code \(result.exitCode) \u{2014} file may be corrupt or unsupported"
                ))
            } else if !issues.contains(where: { $0.severity == .error }) {
                issues.append(MediaIssue(
                    type: .decodeError,
                    severity: .error,
                    description: "ffmpeg exited with non-zero code \(result.exitCode)"
                ))
            }
        }

        return issues
    }

    private func runFFprobeMetadata(url: URL, probePath: String) async throws -> MediaMetadata {
        let arguments = ["-v", "quiet", "-print_format", "json", "-show_format", "-show_streams", url.path]

        let result = try await runProcess(probePath, arguments: arguments)

        guard let json = try? JSONSerialization.jsonObject(with: result.stdout) as? [String: Any] else {
            return MediaMetadata()
        }

        let streams = json["streams"] as? [[String: Any]] ?? []
        let format = json["format"] as? [String: Any] ?? [:]

        var videoCodec: String?
        var audioCodec: String?
        var resolution: CGSize?
        var frameRate: Double?
        var audioChannels: Int?
        var audioSampleRate: Double?
        var tracks: [TrackInfo] = []

        for stream in streams {
            let codecType = stream["codec_type"] as? String ?? ""
            let codecName = stream["codec_name"] as? String
            let language = (stream["tags"] as? [String: Any])?["language"] as? String

            let trackType: TrackType
            switch codecType {
            case "video":
                trackType = .video
                if videoCodec == nil { videoCodec = codecName }
                if resolution == nil,
                   let w = stream["width"] as? Int,
                   let h = stream["height"] as? Int {
                    resolution = CGSize(width: w, height: h)
                }
                if frameRate == nil, let rStr = stream["r_frame_rate"] as? String {
                    frameRate = parseRationalFrameRate(rStr)
                }
            case "audio":
                trackType = .audio
                if audioCodec == nil { audioCodec = codecName }
                if audioChannels == nil, let ch = stream["channels"] as? Int {
                    audioChannels = ch
                }
                if audioSampleRate == nil, let srStr = stream["sample_rate"] as? String, let sr = Double(srStr) {
                    audioSampleRate = sr
                }
            case "subtitle":
                trackType = .subtitle
            default:
                trackType = .other
            }

            tracks.append(TrackInfo(type: trackType, codec: codecName, language: language))
        }

        let durationValue: TimeInterval?
        if let dStr = format["duration"] as? String, let d = Double(dStr) {
            durationValue = d
        } else {
            durationValue = nil
        }

        let bitrateValue: Int64?
        if let bStr = format["bit_rate"] as? String, let b = Int64(bStr) {
            bitrateValue = b
        } else {
            bitrateValue = nil
        }

        let containerFormat = format["format_name"] as? String

        return MediaMetadata(
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            resolution: resolution,
            duration: durationValue,
            bitrate: bitrateValue,
            frameRate: frameRate,
            audioChannels: audioChannels,
            audioSampleRate: audioSampleRate,
            containerFormat: containerFormat,
            tracks: tracks
        )
    }

    // Process execution off the cooperative thread pool to avoid blocking Swift Concurrency.
    // Uses Thread.detachNewThread + continuation so waitUntilExit and pipe reads
    // happen on a POSIX thread, not a cooperative executor thread.
    private func runProcess(_ path: String, arguments: [String]) async throws -> (stdout: Data, stderr: Data, exitCode: Int32) {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = arguments
                    process.standardInput = FileHandle.nullDevice
                    let stdoutPipe = Pipe()
                    let stderrPipe = Pipe()
                    process.standardOutput = stdoutPipe
                    process.standardError = stderrPipe

                    try process.run()

                    // Read both pipes concurrently via GCD to avoid deadlock
                    // when a pipe buffer fills before the other is drained.
                    // nonisolated(unsafe): safe because DispatchGroup.wait() synchronizes.
                    let group = DispatchGroup()
                    nonisolated(unsafe) var stdoutData = Data()
                    nonisolated(unsafe) var stderrData = Data()

                    group.enter()
                    DispatchQueue.global().async {
                        stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }

                    group.enter()
                    DispatchQueue.global().async {
                        stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }

                    group.wait()
                    process.waitUntilExit()

                    continuation.resume(returning: (stdoutData, stderrData, process.terminationStatus))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func resolveWhich(_ command: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [command]
        process.standardOutput = pipe
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func parseRationalFrameRate(_ rational: String) -> Double? {
        let parts = rational.split(separator: "/")
        guard parts.count == 2,
              let num = Double(parts[0]),
              let den = Double(parts[1]),
              den != 0 else { return nil }
        return num / den
    }
}

enum FFmpegError: LocalizedError {
    case notInstalled

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "ffmpeg is not installed. Install via Homebrew: brew install ffmpeg"
        }
    }
}
