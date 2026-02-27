import Foundation

// MARK: - Inspection Depth

enum InspectionDepth: Sendable {
    case quick      // Box structure + index table consistency only (no NAL parsing)
    case standard   // + NAL sampling (~50 frames, keyframes prioritized)
    case thorough   // + NAL check on all keyframes + every 10th frame (no upper cap)
}

// MARK: - Protocol

protocol ContainerInspector: Sendable {
    /// File extensions this inspector handles (lowercase, no dot)
    static var supportedExtensions: Set<String> { get }

    /// Quick check if this inspector can handle the file (magic bytes, extension, etc.)
    func canInspect(url: URL) -> Bool

    /// Run container-level inspection, returning diagnostics
    func inspect(url: URL, depth: InspectionDepth) async throws -> ContainerReport
}

extension ContainerInspector {
    /// Default convenience — runs at `.standard` depth.
    func inspect(url: URL) async throws -> ContainerReport {
        try await inspect(url: url, depth: .standard)
    }
}

// MARK: - Report

struct ContainerReport: Sendable {
    let containerType: ContainerType
    let issues: [ContainerDiagnostic]
    let metadata: ContainerMetadata

    var hasErrors: Bool {
        issues.contains { $0.severity == .error }
    }

    var hasWarnings: Bool {
        issues.contains { $0.severity == .warning }
    }

    var isRemuxFixable: Bool {
        issues.allSatisfy { $0.remediation == .remux }
    }
}

// MARK: - Container Types

enum ContainerType: String, Sendable {
    case isobmff = "ISO Base Media File Format"  // MP4, MOV, M4V, 3GP
    case mxf = "Material eXchange Format"        // MXF OP1a, OPAtom
    case mpegts = "MPEG Transport Stream"        // TS, MTS
    case unknown = "Unknown"

    var shortName: String {
        switch self {
        case .isobmff: return "ISOBMFF"
        case .mxf: return "MXF"
        case .mpegts: return "MPEG-TS"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Diagnostic

struct ContainerDiagnostic: Identifiable, Sendable {
    let id: UUID
    let category: DiagnosticCategory
    let severity: IssueSeverity
    let title: String
    let detail: String
    let byteOffset: UInt64?
    let remediation: Remediation
    let playerNotes: String?

    init(
        id: UUID = UUID(),
        category: DiagnosticCategory,
        severity: IssueSeverity,
        title: String,
        detail: String,
        byteOffset: UInt64? = nil,
        remediation: Remediation = .none,
        playerNotes: String? = nil
    ) {
        self.id = id
        self.category = category
        self.severity = severity
        self.title = title
        self.detail = detail
        self.byteOffset = byteOffset
        self.remediation = remediation
        self.playerNotes = playerNotes
    }
}

enum DiagnosticCategory: String, Sendable {
    case editList           // elst atom issues
    case syncSampleTable    // stss keyframe alignment
    case compositionTime    // ctts offset problems
    case boxStructure       // malformed or overlapping boxes
    case truncatedAtom      // atom extends past EOF
    case missingAtom        // required atom not present
    case sampleTable        // stco/stsz/stsc cross-validation issues
    case nalStructure       // NAL unit boundary / type issues
    case indexTable          // MXF index segment issues
    case partitionStructure  // MXF partition pack problems
    case essenceDescriptor   // MXF essence descriptor issues
    case continuityCounter   // MPEG-TS continuity counter errors
    case programTable        // MPEG-TS PAT/PMT issues
    case other
}

enum Remediation: String, Sendable {
    case remux      // Stream copy to new container fixes this
    case reencode   // Must re-encode to fix
    case none       // Informational, no fix needed
}

// MARK: - Container Metadata

struct ContainerMetadata: Sendable {
    let boxTree: [BoxInfo]?           // ISOBMFF box hierarchy
    let editLists: [EditListInfo]?    // Parsed edit lists per track
    let keyframeCounts: [Int: Int]?   // Track index → keyframe count
    let partitions: [String]?         // MXF partition descriptions
    let operationalPattern: String?   // MXF OP (e.g., "OP1a")

    static let empty = ContainerMetadata(
        boxTree: nil,
        editLists: nil,
        keyframeCounts: nil,
        partitions: nil,
        operationalPattern: nil
    )
}

// MARK: - ISOBMFF-specific metadata types

struct BoxInfo: Sendable, Identifiable {
    let id: UUID
    let type: String        // FourCC: "moov", "mdat", "trak", etc.
    let offset: UInt64      // Byte offset in file
    let size: UInt64        // Total box size
    let children: [BoxInfo]

    init(id: UUID = UUID(), type: String, offset: UInt64, size: UInt64, children: [BoxInfo] = []) {
        self.id = id
        self.type = type
        self.offset = offset
        self.size = size
        self.children = children
    }
}

struct EditListInfo: Sendable {
    let trackIndex: Int
    let entries: [EditListEntry]
}

struct EditListEntry: Sendable {
    let segmentDuration: Int64  // in movie timescale
    let mediaTime: Int64        // in track timescale (-1 = empty edit)
    let mediaRateInteger: Int16
    let mediaRateFraction: Int16
}

// MARK: - Conversion to MediaIssue

extension ContainerDiagnostic {
    func toMediaIssue() -> MediaIssue {
        let issueType: IssueType
        switch category {
        case .editList, .syncSampleTable, .compositionTime:
            issueType = .containerMetadata
        case .boxStructure, .truncatedAtom, .missingAtom, .sampleTable, .nalStructure:
            issueType = .containerStructure
        case .indexTable, .partitionStructure, .essenceDescriptor:
            issueType = .containerMetadata
        case .continuityCounter, .programTable:
            issueType = .containerMetadata
        case .other:
            issueType = .other
        }

        var desc = detail
        if remediation == .remux {
            desc += " [Fixable by remux]"
        } else if remediation == .reencode {
            desc += " [Requires re-encode to fix]"
        }
        if let notes = playerNotes {
            desc += " [\(notes)]"
        }

        return MediaIssue(
            type: issueType,
            severity: severity,
            description: desc
        )
    }
}
