import Foundation
import CoreGraphics

enum TrackType: String, Sendable {
    case video
    case audio
    case subtitle
    case other
}

struct TrackInfo: Identifiable, Sendable {
    let id: UUID
    let type: TrackType
    let codec: String?
    let language: String?

    init(
        id: UUID = UUID(),
        type: TrackType,
        codec: String? = nil,
        language: String? = nil
    ) {
        self.id = id
        self.type = type
        self.codec = codec
        self.language = language
    }
}

struct MediaMetadata: Sendable {
    let videoCodec: String?
    let audioCodec: String?
    let resolution: CGSize?
    let duration: TimeInterval?
    let bitrate: Int64?
    let frameRate: Double?
    let totalFrames: Int?
    let audioChannels: Int?
    let audioSampleRate: Double?
    let containerFormat: String?
    let tracks: [TrackInfo]

    init(
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        resolution: CGSize? = nil,
        duration: TimeInterval? = nil,
        bitrate: Int64? = nil,
        frameRate: Double? = nil,
        totalFrames: Int? = nil,
        audioChannels: Int? = nil,
        audioSampleRate: Double? = nil,
        containerFormat: String? = nil,
        tracks: [TrackInfo] = []
    ) {
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.resolution = resolution
        self.duration = duration
        self.bitrate = bitrate
        self.frameRate = frameRate
        self.totalFrames = totalFrames
        self.audioChannels = audioChannels
        self.audioSampleRate = audioSampleRate
        self.containerFormat = containerFormat
        self.tracks = tracks
    }

    var resolutionString: String? {
        guard let resolution else { return nil }
        return "\(Int(resolution.width))\u{00D7}\(Int(resolution.height))"
    }

    var durationFormatted: String? {
        guard let duration else { return nil }
        let total = Int(duration)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    var bitrateFormatted: String? {
        guard let bitrate else { return nil }
        let mbps = Double(bitrate) / 1_000_000
        return String(format: "%.1f Mbps", mbps)
    }
}
