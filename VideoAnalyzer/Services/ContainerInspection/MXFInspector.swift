import Foundation

/// Inspects MXF (Material eXchange Format) containers.
/// Currently supports OP1a (single-item, single-package) — the standard
/// broadcast ingest format used by MAMs, playout servers, and NLEs.
///
/// MXF uses KLV (Key-Length-Value) encoding per SMPTE 377M.
/// Structure: Header Partition → Body Partitions → Footer Partition
///
/// Future: OPAtom (Avid-style separate essence), OP1b (ganged).
struct MXFInspector: ContainerInspector {

    static let supportedExtensions: Set<String> = ["mxf"]

    // MXF files start with the partition pack key prefix
    private static let mxfPartitionKeyPrefix: [UInt8] = [
        0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01,
        0x0D, 0x01, 0x02, 0x01, 0x01
    ]

    func canInspect(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if Self.supportedExtensions.contains(ext) { return true }
        // Check MXF magic bytes (partition pack UL prefix)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16) else { return false }
        return header.count >= 13 && Array(header[0..<13]) == Self.mxfPartitionKeyPrefix
    }

    func inspect(url: URL) async throws -> ContainerReport {
        // TODO: Implement MXF OP1a inspection
        // Phase 1: Parse partition packs (header, body, footer)
        // Phase 2: Validate header metadata (preface, content storage, essence descriptors)
        // Phase 3: Check index table segments (offsets, edit unit byte counts)
        // Phase 4: Verify essence container data alignment
        // Phase 5: OP1a-specific: single essence container, single package

        return ContainerReport(
            containerType: .mxf,
            issues: [
                ContainerDiagnostic(
                    category: .other,
                    severity: .info,
                    title: "MXF Inspection Not Yet Implemented",
                    detail: "MXF container analysis is planned. Currently only structure detection is available."
                )
            ],
            metadata: ContainerMetadata(
                boxTree: nil,
                editLists: nil,
                keyframeCounts: nil,
                partitions: nil,
                operationalPattern: detectOP(url: url)
            )
        )
    }

    // MARK: - OP Detection (preliminary)

    private func detectOP(url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        // Read enough to find the header partition pack
        guard let data = try? handle.read(upToCount: 65536) else { return nil }

        // Search for Operational Pattern UL in header metadata
        // OP1a: 06.0e.2b.34.04.01.01.01.0d.01.02.01.01.01.09.00
        let op1aPattern: [UInt8] = [0x06, 0x0E, 0x2B, 0x34, 0x04, 0x01, 0x01]
        for i in 0..<(data.count - op1aPattern.count) {
            if Array(data[i..<(i + op1aPattern.count)]) == op1aPattern {
                // Found a SMPTE UL — check the specific OP bytes
                if i + 16 <= data.count {
                    let opByte = data[i + 13]
                    switch opByte {
                    case 0x01: return "OP1a"
                    case 0x02: return "OP1b"
                    case 0x03: return "OP1c"
                    case 0x11: return "OPAtom"
                    default: break
                    }
                }
            }
        }
        return nil
    }
}
