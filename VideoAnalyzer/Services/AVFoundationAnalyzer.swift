import AVFoundation
import CoreMedia
import CoreGraphics

actor AVFoundationAnalyzer {

    func analyze(file: MediaFile, progressHandler: @Sendable (AnalysisProgress) -> Void) async throws -> AnalysisResult {
        let startTime = Date()

        progressHandler(AnalysisProgress(currentFrame: 0, phase: .loading, startTime: startTime))

        let asset = AVURLAsset(url: file.url)

        let isReadable = try await asset.load(.isReadable)
        guard isReadable else {
            let issue = MediaIssue(
                type: .other,
                severity: .error,
                description: "File is not readable by AVFoundation"
            )
            return AnalysisResult(
                fileID: file.id,
                status: .error,
                issues: [issue],
                duration: Date().timeIntervalSince(startTime),
                engineUsed: .avFoundation
            )
        }

        let metadata: MediaMetadata
        do {
            metadata = try await extractMetadata(from: asset)
        } catch {
            let issue = MediaIssue(
                type: .other,
                severity: .error,
                description: "Failed to load asset metadata: \(error.localizedDescription)"
            )
            return AnalysisResult(
                fileID: file.id,
                status: .error,
                issues: [issue],
                duration: Date().timeIntervalSince(startTime),
                engineUsed: .avFoundation
            )
        }

        var allIssues: [MediaIssue] = []

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        for track in videoTracks {
            let issues = try await analyzeVideoTrack(track, asset: asset, metadata: metadata, progressHandler: progressHandler, startTime: startTime)
            allIssues.append(contentsOf: issues)
        }

        for track in audioTracks {
            let issues = try await analyzeAudioTrack(track, asset: asset, startTime: startTime, progressHandler: progressHandler)
            allIssues.append(contentsOf: issues)
        }

        if videoTracks.isEmpty && audioTracks.isEmpty {
            allIssues.append(MediaIssue(
                type: .missingTrack,
                severity: .error,
                description: "No video or audio tracks found in file"
            ))
        }

        let status: AnalysisStatus
        if allIssues.contains(where: { $0.severity == .error }) {
            status = .error
        } else if allIssues.contains(where: { $0.severity == .warning }) {
            status = .warning
        } else {
            status = .healthy
        }

        return AnalysisResult(
            fileID: file.id,
            status: status,
            issues: allIssues,
            metadata: metadata,
            duration: Date().timeIntervalSince(startTime),
            engineUsed: .avFoundation
        )
    }

    private func extractMetadata(from asset: AVAsset) async throws -> MediaMetadata {
        let tracks = try await asset.load(.tracks)
        let duration = try await asset.load(.duration)
        let durationSeconds = CMTimeGetSeconds(duration)

        var videoCodec: String?
        var audioCodec: String?
        var resolution: CGSize?
        var frameRate: Double?
        var audioChannels: Int?
        var audioSampleRate: Double?
        var trackInfos: [TrackInfo] = []

        for track in tracks {
            let mediaType = track.mediaType
            let formatDescriptions = try await track.load(.formatDescriptions)
            let language = try await track.load(.languageCode)

            switch mediaType {
            case .video:
                let naturalSize = try await track.load(.naturalSize)
                let nominalFrameRate = try await track.load(.nominalFrameRate)
                resolution = naturalSize
                frameRate = Double(nominalFrameRate)

                if let desc = formatDescriptions.first {
                    let fourCC = CMFormatDescriptionGetMediaSubType(desc)
                    videoCodec = fourCCString(fourCC)
                }

                trackInfos.append(TrackInfo(
                    type: .video,
                    codec: videoCodec,
                    language: language
                ))

            case .audio:
                if let desc = formatDescriptions.first {
                    let fourCC = CMFormatDescriptionGetMediaSubType(desc)
                    audioCodec = fourCCString(fourCC)

                    if let audioDesc = CMAudioFormatDescriptionGetStreamBasicDescription(desc) {
                        audioChannels = Int(audioDesc.pointee.mChannelsPerFrame)
                        audioSampleRate = audioDesc.pointee.mSampleRate
                    }
                }

                trackInfos.append(TrackInfo(
                    type: .audio,
                    codec: audioCodec,
                    language: language
                ))

            case .text, .closedCaption, .subtitle:
                trackInfos.append(TrackInfo(
                    type: .subtitle,
                    codec: nil,
                    language: language
                ))

            default:
                trackInfos.append(TrackInfo(
                    type: .other,
                    codec: nil,
                    language: language
                ))
            }
        }

        let totalFrames: Int?
        if let fr = frameRate, fr > 0, durationSeconds > 0 {
            totalFrames = Int(durationSeconds * fr)
        } else {
            totalFrames = nil
        }

        return MediaMetadata(
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            resolution: resolution,
            duration: durationSeconds > 0 ? durationSeconds : nil,
            frameRate: frameRate,
            totalFrames: totalFrames,
            audioChannels: audioChannels,
            audioSampleRate: audioSampleRate,
            tracks: trackInfos
        )
    }

    private func analyzeVideoTrack(
        _ track: AVAssetTrack,
        asset: AVAsset,
        metadata: MediaMetadata,
        progressHandler: @Sendable (AnalysisProgress) -> Void,
        startTime: Date
    ) async throws -> [MediaIssue] {
        var issues: [MediaIssue] = []

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            return [MediaIssue(
                type: .decodeError,
                severity: .error,
                description: "Failed to create AVAssetReader: \(error.localizedDescription)"
            )]
        }

        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr8
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.supportsRandomAccess = false

        guard reader.canAdd(output) else {
            return [MediaIssue(
                type: .decodeError,
                severity: .error,
                description: "Cannot add track output to AVAssetReader"
            )]
        }
        reader.add(output)

        guard reader.startReading() else {
            let desc = reader.error?.localizedDescription ?? "Unknown error"
            return [MediaIssue(
                type: .decodeError,
                severity: .error,
                description: "AVAssetReader failed to start: \(desc)"
            )]
        }

        let frameRate = metadata.frameRate ?? 30.0
        let expectedFrameDuration = 1.0 / frameRate
        let totalFrames = metadata.totalFrames

        var frameCount = 0
        var lastPTS = CMTime.invalid
        let timeoutThreshold: TimeInterval = 10.0

        var frameStartTime = Date()

        while let sampleBuffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()

            let elapsed = Date().timeIntervalSince(frameStartTime)
            if elapsed > timeoutThreshold {
                reader.cancelReading()
                issues.append(MediaIssue(
                    type: .decodeError,
                    severity: .error,
                    timestamp: CMTimeGetSeconds(lastPTS).isNaN ? nil : CMTimeGetSeconds(lastPTS),
                    frameNumber: frameCount,
                    description: "Frame decode timed out after \(Int(elapsed)) seconds at frame \(frameCount)"
                ))
                return issues
            }

            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

            if lastPTS.isValid && pts.isValid {
                let gap = CMTimeGetSeconds(pts) - CMTimeGetSeconds(lastPTS)
                if gap > expectedFrameDuration * 1.5 {
                    issues.append(MediaIssue(
                        type: .timestampGap,
                        severity: .warning,
                        timestamp: CMTimeGetSeconds(lastPTS),
                        frameNumber: frameCount,
                        description: String(format: "Timestamp gap of %.3fs detected at frame %d (expected %.3fs)", gap, frameCount, expectedFrameDuration)
                    ))
                }
            }

            lastPTS = pts
            frameCount += 1
            frameStartTime = Date()

            if frameCount % 100 == 0 {
                progressHandler(AnalysisProgress(
                    currentFrame: frameCount,
                    estimatedTotalFrames: totalFrames,
                    phase: .analyzingVideo,
                    startTime: startTime
                ))
            }
        }

        switch reader.status {
        case .failed:
            let desc = reader.error?.localizedDescription ?? "Unknown decode error"
            let errorCode = (reader.error as? NSError)?.code
            let lastTimestamp = lastPTS.isValid ? CMTimeGetSeconds(lastPTS) : nil

            var detail = "Decode failed after \(frameCount) frame\(frameCount == 1 ? "" : "s")"
            if let total = totalFrames, total > 0 {
                let pct = Int(Double(frameCount) / Double(total) * 100)
                detail += " (\(pct)% of file)"
            }
            if let ts = lastTimestamp, !ts.isNaN {
                let h = Int(ts) / 3600
                let m = (Int(ts) % 3600) / 60
                let s = Int(ts) % 60
                detail += " at \(String(format: "%02d:%02d:%02d", h, m, s))"
            }
            detail += ". \(desc)"
            if let code = errorCode {
                detail += " (error \(code))"
            }

            issues.append(MediaIssue(
                type: .decodeError,
                severity: .error,
                timestamp: lastTimestamp,
                frameNumber: frameCount,
                description: detail
            ))
        case .completed:
            if let total = totalFrames, total > 0 {
                let ratio = Double(frameCount) / Double(total)
                if ratio < 0.95 {
                    issues.append(MediaIssue(
                        type: .truncation,
                        severity: .warning,
                        frameNumber: frameCount,
                        description: "File may be truncated: decoded \(frameCount) of ~\(total) expected frames (\(Int(ratio * 100))%)"
                    ))
                }
            }
        default:
            break
        }

        return issues
    }

    private func analyzeAudioTrack(
        _ track: AVAssetTrack,
        asset: AVAsset,
        startTime: Date,
        progressHandler: @Sendable (AnalysisProgress) -> Void
    ) async throws -> [MediaIssue] {
        var issues: [MediaIssue] = []

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            return [MediaIssue(
                type: .decodeError,
                severity: .error,
                description: "Failed to create AVAssetReader for audio: \(error.localizedDescription)"
            )]
        }

        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)

        guard reader.canAdd(output) else {
            return [MediaIssue(
                type: .decodeError,
                severity: .error,
                description: "Cannot add audio track output to AVAssetReader"
            )]
        }
        reader.add(output)

        guard reader.startReading() else {
            let desc = reader.error?.localizedDescription ?? "Unknown error"
            return [MediaIssue(
                type: .decodeError,
                severity: .error,
                description: "AVAssetReader failed to start for audio: \(desc)"
            )]
        }

        progressHandler(AnalysisProgress(
            currentFrame: 0,
            phase: .analyzingAudio,
            startTime: startTime
        ))

        var sampleCount = 0
        while let _ = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            sampleCount += 1
        }

        if reader.status == .failed {
            let desc = reader.error?.localizedDescription ?? "Unknown audio decode error"
            issues.append(MediaIssue(
                type: .decodeError,
                severity: .error,
                description: "Audio track decode failed: \(desc)"
            ))
        }

        return issues
    }

    private func fourCCString(_ fourCC: FourCharCode) -> String {
        let bytes: [CChar] = [
            CChar(bitPattern: UInt8((fourCC >> 24) & 0xFF)),
            CChar(bitPattern: UInt8((fourCC >> 16) & 0xFF)),
            CChar(bitPattern: UInt8((fourCC >> 8) & 0xFF)),
            CChar(bitPattern: UInt8(fourCC & 0xFF)),
            0
        ]
        return String(decoding: bytes.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self).trimmingCharacters(in: .whitespaces)
    }
}
