import Foundation

enum IssueType: String, Sendable, CaseIterable {
    case decodeError
    case timestampGap
    case truncation
    case missingTrack
    case corruptHeader
    case unsupportedCodec
    case containerMetadata   // Edit list, index table, keyframe alignment issues
    case containerStructure  // Malformed boxes/atoms, truncated atoms, missing required atoms
    case engineMismatch      // AVFoundation fails but ffmpeg succeeds (or vice versa)
    case other
}

enum IssueSeverity: String, Sendable, CaseIterable, Comparable {
    case info
    case warning
    case error

    private var sortOrder: Int {
        switch self {
        case .info: return 0
        case .warning: return 1
        case .error: return 2
        }
    }

    static func < (lhs: IssueSeverity, rhs: IssueSeverity) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

struct MediaIssue: Identifiable, Hashable, Sendable {
    let id: UUID
    let type: IssueType
    let severity: IssueSeverity
    let timestamp: Double?
    let frameNumber: Int?
    let description: String

    init(
        id: UUID = UUID(),
        type: IssueType,
        severity: IssueSeverity,
        timestamp: Double? = nil,
        frameNumber: Int? = nil,
        description: String
    ) {
        self.id = id
        self.type = type
        self.severity = severity
        self.timestamp = timestamp
        self.frameNumber = frameNumber
        self.description = description
    }
}
