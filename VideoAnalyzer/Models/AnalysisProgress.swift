import Foundation

enum AnalysisPhase: String, Sendable {
    case loading = "Loading"
    case analyzingVideo = "Analyzing Video"
    case analyzingAudio = "Analyzing Audio"
    case complete = "Complete"
}

struct AnalysisProgress: Sendable {
    let currentFrame: Int
    let estimatedTotalFrames: Int?
    let phase: AnalysisPhase
    let startTime: Date

    init(
        currentFrame: Int,
        estimatedTotalFrames: Int? = nil,
        phase: AnalysisPhase,
        startTime: Date = Date()
    ) {
        self.currentFrame = currentFrame
        self.estimatedTotalFrames = estimatedTotalFrames
        self.phase = phase
        self.startTime = startTime
    }

    var percentage: Double? {
        guard let total = estimatedTotalFrames, total > 0 else { return nil }
        return Double(currentFrame) / Double(total)
    }

    var elapsed: TimeInterval {
        Date().timeIntervalSince(startTime)
    }

    var framesPerSecond: Double {
        let elapsedTime = elapsed
        guard elapsedTime > 0 else { return 0 }
        return Double(currentFrame) / elapsedTime
    }
}
