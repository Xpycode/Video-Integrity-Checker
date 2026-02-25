import Foundation

enum AnalysisStatus: String, Sendable, CaseIterable {
    case healthy
    case warning
    case error
}

enum AnalysisEngine: String, Sendable {
    case avFoundation = "AVFoundation"
    case ffmpeg = "ffmpeg"
}

struct AnalysisResult: Identifiable, Sendable {
    let id: UUID
    let fileID: UUID
    let status: AnalysisStatus
    let issues: [MediaIssue]
    let metadata: MediaMetadata?
    let analysisDate: Date
    let duration: TimeInterval
    let engineUsed: AnalysisEngine

    init(
        id: UUID = UUID(),
        fileID: UUID,
        status: AnalysisStatus,
        issues: [MediaIssue],
        metadata: MediaMetadata? = nil,
        analysisDate: Date = Date(),
        duration: TimeInterval,
        engineUsed: AnalysisEngine
    ) {
        self.id = id
        self.fileID = fileID
        self.status = status
        self.issues = issues
        self.metadata = metadata
        self.analysisDate = analysisDate
        self.duration = duration
        self.engineUsed = engineUsed
    }

    var errorCount: Int {
        issues.filter { $0.severity == .error }.count
    }

    var warningCount: Int {
        issues.filter { $0.severity == .warning }.count
    }

    var infoCount: Int {
        issues.filter { $0.severity == .info }.count
    }
}
