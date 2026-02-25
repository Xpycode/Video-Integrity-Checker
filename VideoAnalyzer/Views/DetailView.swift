import SwiftUI

struct DetailView: View {
    let entry: FileEntry?

    var body: some View {
        if let entry {
            VStack(spacing: 0) {
                StatusBannerView(entry: entry)
                    .padding(.horizontal)
                    .padding(.top, 12)
                    .padding(.bottom, 8)

                Divider()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let result = entry.result, !result.issues.isEmpty {
                            IssuesSection(issues: result.issues)
                        }

                        HStack(alignment: .top, spacing: 12) {
                            FileInfoSection(file: entry.file, result: entry.result)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            if let metadata = entry.result?.metadata {
                                MetadataSection(metadata: metadata)
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                if !metadata.tracks.isEmpty {
                                    TracksSection(tracks: metadata.tracks)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    .padding()
                }
            }
        } else {
            ContentUnavailableView(
                "No File Selected",
                systemImage: "doc.questionmark",
                description: Text("Select a file to view its analysis details.")
            )
        }
    }
}

private struct StatusBannerView: View {
    let entry: FileEntry

    var body: some View {
        HStack(spacing: 10) {
            bannerIcon
                .font(.title2)
                .foregroundStyle(bannerColor)
            Text(bannerText)
                .font(.headline)
                .foregroundStyle(bannerColor)
            Spacer()
            if entry.isAnalyzing {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(bannerColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    private var bannerText: String {
        if entry.isAnalyzing {
            return "Analyzing..."
        }
        guard let result = entry.result else {
            return "Queued for Analysis"
        }
        switch result.status {
        case .healthy:
            return "Healthy"
        case .warning:
            let w = result.warningCount
            return "\(w) Warning\(w == 1 ? "" : "s")"
        case .error:
            let e = result.errorCount
            let w = result.warningCount
            if w > 0 {
                return "\(e) Error\(e == 1 ? "" : "s"), \(w) Warning\(w == 1 ? "" : "s")"
            }
            return "\(e) Error\(e == 1 ? "" : "s")"
        }
    }

    private var bannerIcon: Image {
        if entry.isAnalyzing {
            return Image(systemName: "magnifyingglass")
        }
        guard let result = entry.result else {
            return Image(systemName: "clock")
        }
        switch result.status {
        case .healthy:
            return Image(systemName: "checkmark.circle.fill")
        case .warning:
            return Image(systemName: "exclamationmark.triangle.fill")
        case .error:
            return Image(systemName: "xmark.circle.fill")
        }
    }

    private var bannerColor: Color {
        if entry.isAnalyzing {
            return .blue
        }
        guard let result = entry.result else {
            return .secondary
        }
        switch result.status {
        case .healthy: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

private struct FileInfoSection: View {
    let file: MediaFile
    let result: AnalysisResult?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Name", value: file.fileName)
                LabeledContent("Size", value: file.fileSizeFormatted)
                LabeledContent("Format", value: file.formatInfo ?? "Unknown")
                LabeledContent("Path") {
                    Text(file.url.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                if let engine = result?.engineUsed.rawValue {
                    LabeledContent("Analysis Engine", value: engine)
                }
                if let duration = result?.duration {
                    LabeledContent("Analysis Time", value: formattedDuration(duration))
                }
            }
        } label: {
            Text("File Info")
                .font(.headline)
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            return String(format: "%.0f ms", duration * 1000)
        }
        return String(format: "%.1f s", duration)
    }
}

private struct MetadataSection: View {
    let metadata: MediaMetadata

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                if let codec = metadata.videoCodec {
                    LabeledContent("Video Codec", value: codec)
                }
                if let codec = metadata.audioCodec {
                    LabeledContent("Audio Codec", value: codec)
                }
                if let res = metadata.resolutionString {
                    LabeledContent("Resolution", value: res)
                }
                if let dur = metadata.durationFormatted {
                    LabeledContent("Duration", value: dur)
                }
                if let bitrate = metadata.bitrateFormatted {
                    LabeledContent("Bitrate", value: bitrate)
                }
                if let fps = metadata.frameRate {
                    LabeledContent("Frame Rate", value: formattedFrameRate(fps))
                }
                if let channels = metadata.audioChannels {
                    LabeledContent("Audio", value: formattedAudio(channels: channels, sampleRate: metadata.audioSampleRate))
                }
            }
        } label: {
            Text("Media Info")
                .font(.headline)
        }
    }

    private func formattedFrameRate(_ fps: Double) -> String {
        let rounded = (fps * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return "\(Int(rounded)) fps"
        }
        return String(format: "%.2f fps", rounded)
    }

    private func formattedAudio(channels: Int, sampleRate: Double?) -> String {
        let channelStr = "\(channels)ch"
        if let rate = sampleRate {
            return "\(channelStr) @ \(String(format: "%.1f", rate / 1000)) kHz"
        }
        return channelStr
    }
}

private struct TracksSection: View {
    let tracks: [TrackInfo]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(tracks) { track in
                    TrackRowView(track: track)
                }
            }
        } label: {
            Text("Tracks")
                .font(.headline)
        }
    }
}

private struct TrackRowView: View {
    let track: TrackInfo

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: trackIcon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            if let codec = track.codec {
                Text(codec)
                    .font(.body)
            } else {
                Text(track.type.rawValue.capitalized)
                    .font(.body)
            }
            if let lang = track.language {
                Text(lang.uppercased())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.leading, 4)
    }

    private var trackIcon: String {
        switch track.type {
        case .video: return "film"
        case .audio: return "waveform"
        case .subtitle: return "captions.bubble"
        case .other: return "questionmark.circle"
        }
    }
}

private struct IssuesSection: View {
    let issues: [MediaIssue]

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(issues) { issue in
                    IssueRowView(issue: issue)
                    if issue.id != issues.last?.id {
                        Divider()
                    }
                }
            }
        } label: {
            Text("Issues (\(issues.count))")
                .font(.headline)
        }
    }
}

private struct IssueRowView: View {
    let issue: MediaIssue

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: severityIcon)
                .foregroundStyle(severityColor)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(issueTypeDisplayName)
                    .font(.body)
                    .fontWeight(.medium)
                Text(issue.description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    if let ts = issue.timestamp {
                        Text("at \(formattedTimestamp(ts))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if let frame = issue.frameNumber {
                        Text("Frame #\(frame)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }

    private var severityIcon: String {
        switch issue.severity {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private var severityColor: Color {
        switch issue.severity {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var issueTypeDisplayName: String {
        switch issue.type {
        case .decodeError: return "Decode Error"
        case .timestampGap: return "Timestamp Gap"
        case .truncation: return "Truncation"
        case .missingTrack: return "Missing Track"
        case .corruptHeader: return "Corrupt Header"
        case .unsupportedCodec: return "Unsupported Codec"
        case .other: return "Other"
        }
    }

    private func formattedTimestamp(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
}

#Preview("With Result") {
    let file = MediaFile(
        url: URL(fileURLWithPath: "/Users/sim/Movies/sample.mp4"),
        fileSize: 524_288_000,
        modificationDate: Date(),
        formatInfo: "MP4"
    )
    let issues: [MediaIssue] = [
        MediaIssue(
            type: .decodeError,
            severity: .error,
            timestamp: 5023,
            frameNumber: 125_450,
            description: "Failed to decode frame at GOP boundary."
        ),
        MediaIssue(
            type: .timestampGap,
            severity: .warning,
            timestamp: 120,
            description: "PTS gap of 2 frames detected in video track."
        ),
    ]
    let metadata = MediaMetadata(
        videoCodec: "H.264",
        audioCodec: "AAC",
        resolution: CGSize(width: 1920, height: 1080),
        duration: 5400,
        bitrate: 8_500_000,
        frameRate: 29.97,
        totalFrames: 161_838,
        audioChannels: 2,
        audioSampleRate: 48_000,
        containerFormat: "QuickTime",
        tracks: [
            TrackInfo(type: .video, codec: "H.264", language: "und"),
            TrackInfo(type: .audio, codec: "AAC", language: "eng"),
        ]
    )
    let result = AnalysisResult(
        fileID: file.id,
        status: .error,
        issues: issues,
        metadata: metadata,
        duration: 2.3,
        engineUsed: .avFoundation
    )
    let entry = FileEntry(
        id: UUID(),
        file: file,
        result: result,
        progress: nil,
        isAnalyzing: false
    )
    return DetailView(entry: entry)
        .frame(width: 340, height: 700)
}

#Preview("Analyzing") {
    let file = MediaFile(
        url: URL(fileURLWithPath: "/Users/sim/Movies/sample.mp4"),
        fileSize: 524_288_000,
        formatInfo: "MP4"
    )
    let entry = FileEntry(
        id: UUID(),
        file: file,
        result: nil,
        progress: AnalysisProgress(currentFrame: 4200, estimatedTotalFrames: 10000, phase: .analyzingVideo),
        isAnalyzing: true
    )
    return DetailView(entry: entry)
        .frame(width: 340, height: 400)
}

#Preview("Empty State") {
    DetailView(entry: nil)
        .frame(width: 340, height: 400)
}
