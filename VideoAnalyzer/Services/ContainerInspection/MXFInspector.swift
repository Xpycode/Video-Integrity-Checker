import Foundation

/// Inspects MXF (Material eXchange Format) containers — shallow parse.
///
/// Covers OP1a (single-item, single-package), the standard broadcast ingest
/// format used by MAMs (VPMS/Arvato), playout servers, and NLEs.
///
/// MXF uses KLV (Key-Length-Value) encoding per SMPTE ST 377-1.
/// Structure: Header Partition → Body Partitions → Footer Partition
///
/// **Approach:** Jump-based, not sequential walk. Reads the header partition
/// pack at byte 0, parses the RIP from the file's tail, then jumps to each
/// partition offset. Never touches essence payload — safe for multi-GB files.
struct MXFInspector: ContainerInspector {

    static let supportedExtensions: Set<String> = ["mxf"]

    // MARK: - SMPTE Universal Labels

    /// Partition pack key prefix (bytes 0–12).
    /// Full key: 06.0e.2b.34.02.05.01.01.0d.01.02.01.01.[type].[status].00
    private static let partitionKeyPrefix: [UInt8] = [
        0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01,
        0x0D, 0x01, 0x02, 0x01, 0x01
    ]

    /// Random Index Pack key (16 bytes).
    private static let ripKey: [UInt8] = [
        0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01,
        0x0D, 0x01, 0x02, 0x01, 0x01, 0x11, 0x01, 0x00
    ]

    /// Index Table Segment key prefix (bytes 0–13).
    private static let indexTableKeyPrefix: [UInt8] = [
        0x06, 0x0E, 0x2B, 0x34, 0x02, 0x53, 0x01, 0x01,
        0x0D, 0x01, 0x02, 0x01, 0x01, 0x10
    ]

    // MARK: - Parsed Types

    private struct PartitionPack {
        enum Kind: String { case header = "Header", body = "Body", footer = "Footer", unknown = "Unknown" }
        enum Status: String {
            case openIncomplete    = "Open & Incomplete"
            case closedIncomplete  = "Closed & Incomplete"
            case openComplete      = "Open & Complete"
            case closedComplete    = "Closed & Complete"
            case unknown           = "Unknown"
        }

        let kind: Kind
        let status: Status
        let fileOffset: UInt64
        let previousPartition: UInt64
        let footerPartition: UInt64
        let headerByteCount: UInt64
        let indexByteCount: UInt64
        let indexSID: UInt32
        let bodySID: UInt32
        let kagSize: UInt32
        let operationalPattern: [UInt8]      // 16-byte OP UL
        let essenceContainerULs: [[UInt8]]   // batch of 16-byte labels
        let klvValueEnd: UInt64              // byte after partition pack KLV value

        var label: String { "\(kind.rawValue) Partition (\(status.rawValue)) at byte \(fileOffset)" }

        /// Derive OP name from bytes 12–13 of the OP UL.
        var opName: String? {
            guard operationalPattern.count >= 14 else { return nil }
            let item = operationalPattern[12]
            let pkg  = operationalPattern[13]
            switch (item, pkg) {
            case (0x01, 0x01): return "OP1a"
            case (0x01, 0x02): return "OP1b"
            case (0x01, 0x03): return "OP1c"
            case (0x02, 0x01): return "OP2a"
            case (0x02, 0x02): return "OP2b"
            case (0x02, 0x03): return "OP2c"
            case (0x03, 0x01): return "OP3a"
            case (0x03, 0x02): return "OP3b"
            case (0x03, 0x03): return "OP3c"
            case (0x10, _):    return "OPAtom"
            default:           return nil
            }
        }
    }

    private struct RIPEntry {
        let bodySID: UInt32
        let byteOffset: UInt64
    }

    private struct IndexTableInfo {
        let fileOffset: UInt64
        let klvLength: UInt64
    }

    // MARK: - ContainerInspector

    func canInspect(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if Self.supportedExtensions.contains(ext) { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16) else { return false }
        return header.count >= 13 && Array(header[0..<13]) == Self.partitionKeyPrefix
    }

    func inspect(url: URL, depth: InspectionDepth) async throws -> ContainerReport {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let fileSize = UInt64(data.count)
        var issues: [ContainerDiagnostic] = []
        var partitions: [PartitionPack] = []
        var indexTables: [IndexTableInfo] = []

        // ── Step 1: Parse header partition at byte 0 ──────────────────────
        if let header = parsePartitionAt(data: data, offset: 0, fileSize: fileSize) {
            partitions.append(header)

            // Scan header partition's index area for index table segments
            let indexAreaStart = header.klvValueEnd + header.headerByteCount
            let indexAreaEnd = indexAreaStart + header.indexByteCount
            if header.indexByteCount > 0 {
                indexTables.append(contentsOf:
                    scanForIndexTables(data: data, from: indexAreaStart, to: min(indexAreaEnd, fileSize))
                )
            }
        }

        // ── Step 2: Parse RIP from tail of file ──────────────────────────
        let rip = parseRIP(data: data, fileSize: fileSize)

        // ── Step 3: Discover remaining partitions ────────────────────────
        // Strategy: use RIP entries if available, otherwise use footer offset from header.
        var additionalOffsets: [UInt64] = []

        if let rip {
            // RIP lists every partition; skip offset 0 (we already parsed the header)
            additionalOffsets = rip.map(\.byteOffset).filter { $0 != 0 && $0 < fileSize }
        } else if let header = partitions.first, header.footerPartition > 0, header.footerPartition < fileSize {
            additionalOffsets = [header.footerPartition]
        }

        for offset in additionalOffsets.sorted() {
            guard !partitions.contains(where: { $0.fileOffset == offset }) else { continue }
            if let pack = parsePartitionAt(data: data, offset: offset, fileSize: fileSize) {
                partitions.append(pack)

                // Scan this partition's index area too
                if pack.indexByteCount > 0 {
                    let start = pack.klvValueEnd + pack.headerByteCount
                    let end = start + pack.indexByteCount
                    indexTables.append(contentsOf:
                        scanForIndexTables(data: data, from: start, to: min(end, fileSize))
                    )
                }
            }
        }

        // Sort partitions by file offset for consistent validation
        partitions.sort { $0.fileOffset < $1.fileOffset }

        // ── Step 4: Validate ─────────────────────────────────────────────
        issues.append(contentsOf: validatePartitionStructure(partitions: partitions, fileSize: fileSize))
        issues.append(contentsOf: validateOPConformance(partitions: partitions))
        issues.append(contentsOf: validateIndexTables(indexTables: indexTables, partitions: partitions))
        issues.append(contentsOf: validateRIP(rip: rip, partitions: partitions, fileSize: fileSize))
        issues.append(contentsOf: detectTruncation(partitions: partitions, fileSize: fileSize))
        issues.append(contentsOf: validateKLVIntegrity(data: data, partitions: partitions, fileSize: fileSize))
        issues.append(contentsOf: validateEssenceConsistency(partitions: partitions))

        // ── Step 5: Extract informational metadata ───────────────────────
        let codecNames = partitions.first.map { identifyCodecs(from: $0.essenceContainerULs) } ?? []
        if !codecNames.isEmpty {
            issues.append(ContainerDiagnostic(
                category: .essenceDescriptor,
                severity: .info,
                title: "Essence Containers",
                detail: "Declared essence: \(codecNames.joined(separator: ", "))"
            ))
        }

        let metadata = ContainerMetadata(
            boxTree: nil,
            editLists: nil,
            keyframeCounts: nil,
            partitions: partitions.isEmpty ? nil : partitions.map(\.label),
            operationalPattern: partitions.first?.opName
        )

        return ContainerReport(containerType: .mxf, issues: issues, metadata: metadata)
    }

    // MARK: - KLV Reading

    private struct KLVHeader {
        let valueOffset: UInt64   // first byte of value
        let length: UInt64        // value length
    }

    /// Read a KLV triplet starting at `offset`. Returns nil if data is insufficient.
    private func readKLV(data: Data, offset: UInt64, fileSize: UInt64) -> KLVHeader? {
        guard offset + 17 <= fileSize else { return nil }
        let lengthOffset = offset + 16
        let (length, consumed) = readBERLength(data: data, offset: lengthOffset, fileSize: fileSize)
        guard consumed > 0 else { return nil }
        return KLVHeader(valueOffset: lengthOffset + UInt64(consumed), length: length)
    }

    /// Decode a BER (Basic Encoding Rules) length per SMPTE ST 379-2.
    ///
    /// - Short form: first byte < 0x80 → that byte IS the length.
    /// - Long form:  first byte ≥ 0x80 → low 7 bits = N, then N bytes big-endian = length.
    private func readBERLength(data: Data, offset: UInt64, fileSize: UInt64) -> (length: UInt64, bytesConsumed: Int) {
        guard offset < fileSize else { return (0, 0) }
        let first = data[Int(offset)]

        if first < 0x80 {
            return (UInt64(first), 1)
        }

        let n = Int(first & 0x7F)
        guard n > 0, n <= 8, offset + 1 + UInt64(n) <= fileSize else { return (0, 0) }

        var length: UInt64 = 0
        for i in 0..<n {
            length = (length << 8) | UInt64(data[Int(offset) + 1 + i])
        }
        return (length, 1 + n)
    }

    // MARK: - Key Identification

    private func isPartitionPack(_ key: UnsafeBufferPointer<UInt8>) -> Bool {
        guard key.count >= 16 else { return false }
        for i in 0..<13 where key[i] != Self.partitionKeyPrefix[i] { return false }
        return key[13] >= 0x02 && key[13] <= 0x04
    }

    private func isIndexTable(_ key: UnsafeBufferPointer<UInt8>) -> Bool {
        guard key.count >= 14 else { return false }
        for i in 0..<14 where key[i] != Self.indexTableKeyPrefix[i] { return false }
        return true
    }

    // MARK: - Partition Pack Parsing

    /// Parse a partition pack KLV at the given file offset.
    private func parsePartitionAt(data: Data, offset: UInt64, fileSize: UInt64) -> PartitionPack? {
        // Verify this is actually a partition pack key
        guard offset + 16 <= fileSize else { return nil }
        let keyOK = data.withUnsafeBytes { buf -> Bool in
            guard let base = buf.baseAddress else { return false }
            let ptr = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self) + Int(offset), count: 16)
            return isPartitionPack(ptr)
        }
        guard keyOK else { return nil }

        guard let klv = readKLV(data: data, offset: offset, fileSize: fileSize) else { return nil }
        let v = klv.valueOffset

        // Partition pack fixed fields: 88 bytes minimum before the essence container batch
        guard v + 88 <= fileSize else { return nil }

        let kagSize           = data.readUInt32BE(at: v + 4)
        // v + 8: thisPartition (we already know it — it's `offset`)
        let previousPartition = data.readUInt64BE(at: v + 16)
        let footerPartition   = data.readUInt64BE(at: v + 24)
        let headerByteCount   = data.readUInt64BE(at: v + 32)
        let indexByteCount    = data.readUInt64BE(at: v + 40)
        let indexSID          = data.readUInt32BE(at: v + 48)
        // v + 52: bodyOffset
        let bodySID           = data.readUInt32BE(at: v + 60)
        let opUL              = Array(data[Int(v + 64)..<Int(v + 80)])

        // Essence Container ULs batch at v + 80
        var essenceULs: [[UInt8]] = []
        let batchCount      = data.readUInt32BE(at: v + 80)
        let batchItemLength = data.readUInt32BE(at: v + 84)
        if batchItemLength == 16 {
            for i in 0..<batchCount {
                let ulStart = Int(v + 88) + Int(i) * 16
                guard ulStart + 16 <= data.count else { break }
                essenceULs.append(Array(data[ulStart..<(ulStart + 16)]))
            }
        }

        // Decode kind and status from key bytes 13–14
        let kind: PartitionPack.Kind
        switch data[Int(offset + 13)] {
        case 0x02: kind = .header
        case 0x03: kind = .body
        case 0x04: kind = .footer
        default:   kind = .unknown
        }

        let status: PartitionPack.Status
        switch data[Int(offset + 14)] {
        case 0x01: status = .openIncomplete
        case 0x02: status = .closedIncomplete
        case 0x03: status = .openComplete
        case 0x04: status = .closedComplete
        default:   status = .unknown
        }

        return PartitionPack(
            kind: kind,
            status: status,
            fileOffset: offset,
            previousPartition: previousPartition,
            footerPartition: footerPartition,
            headerByteCount: headerByteCount,
            indexByteCount: indexByteCount,
            indexSID: indexSID,
            bodySID: bodySID,
            kagSize: kagSize,
            operationalPattern: opUL,
            essenceContainerULs: essenceULs,
            klvValueEnd: klv.valueOffset + klv.length
        )
    }

    // MARK: - Index Table Scanning

    /// Walk KLVs within a byte range looking for index table segments.
    private func scanForIndexTables(data: Data, from start: UInt64, to end: UInt64) -> [IndexTableInfo] {
        var results: [IndexTableInfo] = []
        var pos = start

        while pos + 20 <= end {
            guard let klv = readKLV(data: data, offset: pos, fileSize: end) else { break }

            let isIndex = data.withUnsafeBytes { buf -> Bool in
                guard let base = buf.baseAddress else { return false }
                let ptr = UnsafeBufferPointer(start: base.assumingMemoryBound(to: UInt8.self) + Int(pos), count: 16)
                return isIndexTable(ptr)
            }

            if isIndex {
                results.append(IndexTableInfo(fileOffset: pos, klvLength: klv.length))
            }

            let next = klv.valueOffset + klv.length
            guard next > pos else { break }
            pos = next
        }

        return results
    }

    // MARK: - RIP Parsing

    /// Parse the Random Index Pack from the last bytes of the file.
    /// RIP layout: KLV key(16) + BER length + [BodySID(4) + ByteOffset(8)]... + OverallLength(4)
    private func parseRIP(data: Data, fileSize: UInt64) -> [RIPEntry]? {
        guard fileSize >= 33 else { return nil }  // 16 key + 1 BER + 12 entry + 4 overall

        // Last 4 bytes = overall RIP length (includes key + BER + entries + this 4-byte field)
        let ripTotalLength = UInt64(data.readUInt32BE(at: fileSize - 4))
        guard ripTotalLength >= 33, ripTotalLength <= fileSize else { return nil }

        let ripOffset = fileSize - ripTotalLength

        // Verify RIP key
        guard ripOffset + 16 <= fileSize else { return nil }
        for i in 0..<16 {
            guard data[Int(ripOffset) + i] == Self.ripKey[i] else { return nil }
        }

        let (berLength, berConsumed) = readBERLength(data: data, offset: ripOffset + 16, fileSize: fileSize)
        guard berConsumed > 0 else { return nil }

        let entriesStart = ripOffset + 16 + UInt64(berConsumed)
        // BER value covers entries + 4-byte overall length
        let entriesBytes = berLength >= 4 ? berLength - 4 : 0
        let entryCount = entriesBytes / 12

        var entries: [RIPEntry] = []
        entries.reserveCapacity(Int(entryCount))

        for i in 0..<entryCount {
            let pos = entriesStart + i * 12
            guard pos + 12 <= fileSize else { break }
            entries.append(RIPEntry(
                bodySID: data.readUInt32BE(at: pos),
                byteOffset: data.readUInt64BE(at: pos + 4)
            ))
        }

        return entries.isEmpty ? nil : entries
    }

    // MARK: - Validation: Partition Structure

    private func validatePartitionStructure(partitions: [PartitionPack], fileSize: UInt64) -> [ContainerDiagnostic] {
        var issues: [ContainerDiagnostic] = []

        // ── Must have a header partition ─────────────────────────────────
        guard let header = partitions.first(where: { $0.kind == .header }) else {
            issues.append(ContainerDiagnostic(
                category: .partitionStructure,
                severity: .error,
                title: "Missing Header Partition",
                detail: "No header partition pack found. File is severely corrupt or not a valid MXF file.",
                remediation: .reencode
            ))
            return issues
        }

        // ── Header should be at byte 0 ──────────────────────────────────
        if header.fileOffset != 0 {
            issues.append(ContainerDiagnostic(
                category: .partitionStructure,
                severity: .error,
                title: "Header Partition Not at Start",
                detail: "Header partition is at byte \(header.fileOffset), expected byte 0.",
                byteOffset: header.fileOffset,
                remediation: .reencode
            ))
        }

        // ── Check for footer ────────────────────────────────────────────
        let hasFooter = partitions.contains { $0.kind == .footer }
        if !hasFooter {
            let allClosed = partitions.allSatisfy { $0.status == .closedComplete || $0.status == .closedIncomplete }
            let isClosedComplete = header.status == .closedComplete
            let severity: IssueSeverity = isClosedComplete ? .error : .warning
            let detail = isClosedComplete
                ? "Closed & Complete file must have a footer partition. File is corrupt."
                : "No footer partition found. File may be truncated (incomplete recording) or not finalized. Some MAMs (e.g. VPMS) may reject this file."
            issues.append(ContainerDiagnostic(
                category: .partitionStructure,
                severity: severity,
                title: "Missing Footer Partition",
                detail: detail,
                remediation: .remux,
                playerNotes: allClosed ? "Avid Media Composer and DaVinci Resolve may reject this file; ffmpeg plays it" : nil
            ))
        }

        // ── Footer offset agreement ──────────────────────────────────────
        let footerOffsets = Set(partitions.compactMap { $0.footerPartition > 0 ? $0.footerPartition : nil })
        if footerOffsets.count > 1 {
            issues.append(ContainerDiagnostic(
                category: .partitionStructure,
                severity: .warning,
                title: "Footer Offset Disagreement",
                detail: "Partitions disagree on footer location: \(footerOffsets.sorted().map { "byte \($0)" }.joined(separator: ", ")).",
                remediation: .remux
            ))
        }

        // ── Header partition status ─────────────────────────────────────
        switch header.status {
        case .openIncomplete:
            issues.append(ContainerDiagnostic(
                category: .partitionStructure,
                severity: .warning,
                title: "Open & Incomplete Header",
                detail: "Header partition was never finalized. Header metadata and index tables may be incomplete.",
                byteOffset: 0,
                remediation: .remux
            ))
        case .openComplete:
            issues.append(ContainerDiagnostic(
                category: .partitionStructure,
                severity: .info,
                title: "Open Header Partition",
                detail: "Header is Open (body offsets may change). Normal for growing files, unusual for finalized content."
            ))
        case .closedIncomplete:
            issues.append(ContainerDiagnostic(
                category: .partitionStructure,
                severity: .info,
                title: "Closed & Incomplete Header",
                detail: "Header is closed but marked incomplete. Footer may contain updated metadata."
            ))
        case .closedComplete, .unknown:
            break
        }

        // ── Validate partition chain ────────────────────────────────────
        for i in 1..<partitions.count {
            let current  = partitions[i]
            let previous = partitions[i - 1]
            if current.previousPartition != previous.fileOffset {
                issues.append(ContainerDiagnostic(
                    category: .partitionStructure,
                    severity: .warning,
                    title: "Broken Partition Chain",
                    detail: "\(current.kind.rawValue) partition at byte \(current.fileOffset) declares previous at \(current.previousPartition), actual is \(previous.fileOffset).",
                    byteOffset: current.fileOffset,
                    remediation: .remux
                ))
            }
        }

        // ── KAG alignment check ──────────────────────────────────────────
        if header.kagSize > 1 {
            for pack in partitions where pack.fileOffset > 0 {
                if pack.fileOffset % UInt64(header.kagSize) != 0 {
                    issues.append(ContainerDiagnostic(
                        category: .partitionStructure,
                        severity: .info,
                        title: "KAG Misalignment",
                        detail: "Partition at byte \(pack.fileOffset) is not aligned to KAG boundary of \(header.kagSize) bytes.",
                        byteOffset: pack.fileOffset
                    ))
                }
            }
        }

        return issues
    }

    // MARK: - Validation: OP Conformance

    private func validateOPConformance(partitions: [PartitionPack]) -> [ContainerDiagnostic] {
        var issues: [ContainerDiagnostic] = []
        guard let header = partitions.first(where: { $0.kind == .header }) else { return issues }

        if let opName = header.opName {
            if opName != "OP1a" {
                issues.append(ContainerDiagnostic(
                    category: .partitionStructure,
                    severity: .info,
                    title: "Non-OP1a File",
                    detail: "File declares \(opName). This inspector is optimized for OP1a; some checks may not apply."
                ))
            }
        } else {
            issues.append(ContainerDiagnostic(
                category: .partitionStructure,
                severity: .warning,
                title: "Unknown Operational Pattern",
                detail: "Could not identify the operational pattern from the header partition. OP UL bytes 12–13: 0x\(String(format: "%02X%02X", header.operationalPattern.count > 12 ? header.operationalPattern[12] : 0, header.operationalPattern.count > 13 ? header.operationalPattern[13] : 0)).",
                byteOffset: header.fileOffset
            ))
        }

        // OP1a: single interleaved essence container → one body SID
        let essenceSIDs = Set(partitions.compactMap { $0.bodySID != 0 ? $0.bodySID : nil })
        if essenceSIDs.count > 1 {
            issues.append(ContainerDiagnostic(
                category: .partitionStructure,
                severity: .warning,
                title: "Multiple Essence Streams",
                detail: "Found \(essenceSIDs.count) distinct body SIDs (\(essenceSIDs.sorted().map(String.init).joined(separator: ", "))). OP1a expects a single interleaved essence container.",
                remediation: .remux
            ))
        }

        if header.essenceContainerULs.isEmpty {
            issues.append(ContainerDiagnostic(
                category: .essenceDescriptor,
                severity: .warning,
                title: "No Essence Container Labels",
                detail: "Header partition declares no essence container ULs. Players may not identify the codec."
            ))
        }

        return issues
    }

    // MARK: - Validation: Index Tables

    private func validateIndexTables(indexTables: [IndexTableInfo], partitions: [PartitionPack]) -> [ContainerDiagnostic] {
        var issues: [ContainerDiagnostic] = []

        let declaredIndexBytes = partitions.reduce(UInt64(0)) { $0 + $1.indexByteCount }

        if declaredIndexBytes > 0 && indexTables.isEmpty {
            issues.append(ContainerDiagnostic(
                category: .indexTable,
                severity: .warning,
                title: "Declared Index Not Found",
                detail: "Partition packs declare \(declaredIndexBytes) bytes of index data, but no index table segments were parsed. Seeking may be unreliable.",
                remediation: .remux
            ))
        }

        let hasEssence = partitions.contains { $0.bodySID != 0 }
        if hasEssence && indexTables.isEmpty && declaredIndexBytes == 0 {
            issues.append(ContainerDiagnostic(
                category: .indexTable,
                severity: .info,
                title: "No Index Table",
                detail: "File contains essence but no index table. Frame-accurate seeking requires a sequential scan, which may be slow for large files."
            ))
        }

        return issues
    }

    // MARK: - Validation: RIP

    private func validateRIP(rip: [RIPEntry]?, partitions: [PartitionPack], fileSize: UInt64) -> [ContainerDiagnostic] {
        var issues: [ContainerDiagnostic] = []

        if rip == nil && fileSize > 1_000_000 {
            issues.append(ContainerDiagnostic(
                category: .partitionStructure,
                severity: .info,
                title: "No Random Index Pack",
                detail: "No RIP at end of file. Random access to partitions requires a sequential scan."
            ))
        }

        if let rip {
            let partitionOffsets = Set(partitions.map(\.fileOffset))
            for entry in rip {
                if entry.byteOffset >= fileSize {
                    issues.append(ContainerDiagnostic(
                        category: .partitionStructure,
                        severity: .error,
                        title: "RIP Entry Beyond EOF",
                        detail: "RIP entry (SID \(entry.bodySID)) points to byte \(entry.byteOffset) but file is \(fileSize) bytes.",
                        remediation: .remux
                    ))
                } else if !partitionOffsets.contains(entry.byteOffset) {
                    issues.append(ContainerDiagnostic(
                        category: .partitionStructure,
                        severity: .warning,
                        title: "RIP/Partition Mismatch",
                        detail: "RIP entry (SID \(entry.bodySID)) points to byte \(entry.byteOffset) but no partition pack was found there.",
                        remediation: .remux
                    ))
                }
            }
        }

        return issues
    }

    // MARK: - Truncation Detection

    private func detectTruncation(partitions: [PartitionPack], fileSize: UInt64) -> [ContainerDiagnostic] {
        var issues: [ContainerDiagnostic] = []

        // If header says footer is at offset X, but X ≥ fileSize → truncated
        if let header = partitions.first(where: { $0.kind == .header }),
           header.footerPartition > 0, header.footerPartition >= fileSize {
            issues.append(ContainerDiagnostic(
                category: .partitionStructure,
                severity: .error,
                title: "Truncated File",
                detail: "Header declares footer at byte \(header.footerPartition) but file is only \(fileSize) bytes. Recording may have been interrupted.",
                byteOffset: header.footerPartition,
                remediation: .remux
            ))
        }

        // If any partition's declared metadata/index sizes extend past EOF
        for pack in partitions {
            let dataStart = pack.klvValueEnd
            let dataEnd = dataStart + pack.headerByteCount + pack.indexByteCount
            if dataEnd > fileSize && (pack.headerByteCount + pack.indexByteCount) > 0 {
                issues.append(ContainerDiagnostic(
                    category: .partitionStructure,
                    severity: .error,
                    title: "Truncated \(pack.kind.rawValue) Partition",
                    detail: "\(pack.kind.rawValue) partition at byte \(pack.fileOffset) declares \(pack.headerByteCount) metadata + \(pack.indexByteCount) index bytes, extending to byte \(dataEnd), but file ends at \(fileSize).",
                    byteOffset: pack.fileOffset,
                    remediation: .reencode
                ))
            }
        }

        return issues
    }

    // MARK: - Validation: KLV Integrity

    /// Scan KLVs in each partition's metadata/index area and check for length overflows.
    private func validateKLVIntegrity(data: Data, partitions: [PartitionPack], fileSize: UInt64) -> [ContainerDiagnostic] {
        var issues: [ContainerDiagnostic] = []

        for pack in partitions {
            let metadataAndIndexBytes = pack.headerByteCount + pack.indexByteCount
            guard metadataAndIndexBytes > 0 else { continue }

            let areaStart = pack.klvValueEnd
            let areaEnd = min(areaStart + metadataAndIndexBytes, fileSize)
            var pos = areaStart

            while pos + 20 <= areaEnd {
                guard let klv = readKLV(data: data, offset: pos, fileSize: areaEnd) else { break }

                let klvEnd = klv.valueOffset + klv.length
                if klvEnd > areaEnd {
                    issues.append(ContainerDiagnostic(
                        category: .partitionStructure,
                        severity: .warning,
                        title: "KLV Length Overflow",
                        detail: "KLV at byte \(pos) declares \(klv.length) bytes, exceeding \(pack.kind.rawValue) partition boundary at byte \(areaEnd).",
                        byteOffset: pos,
                        remediation: .remux
                    ))
                    break // Can't trust further KLVs in this area
                }

                let next = klv.valueOffset + klv.length
                guard next > pos else { break }
                pos = next
            }
        }

        return issues
    }

    // MARK: - Validation: Essence Container Consistency

    /// Compare header partition's declared essence container ULs against body partitions.
    private func validateEssenceConsistency(partitions: [PartitionPack]) -> [ContainerDiagnostic] {
        var issues: [ContainerDiagnostic] = []
        guard let header = partitions.first(where: { $0.kind == .header }) else { return issues }
        let headerULs = Set(header.essenceContainerULs.map { $0.map { String(format: "%02X", $0) }.joined() })
        guard !headerULs.isEmpty else { return issues }

        for pack in partitions where pack.kind == .body {
            guard !pack.essenceContainerULs.isEmpty else { continue }
            let bodyULs = Set(pack.essenceContainerULs.map { $0.map { String(format: "%02X", $0) }.joined() })

            if bodyULs != headerULs {
                let headerOnly = headerULs.subtracting(bodyULs)
                let bodyOnly = bodyULs.subtracting(headerULs)
                var detail = "Body partition at byte \(pack.fileOffset) declares different essence container ULs than header."
                if !headerOnly.isEmpty {
                    detail += " Header-only: \(headerOnly.count) label(s)."
                }
                if !bodyOnly.isEmpty {
                    detail += " Body-only: \(bodyOnly.count) label(s)."
                }
                issues.append(ContainerDiagnostic(
                    category: .essenceDescriptor,
                    severity: .warning,
                    title: "Essence Container Mismatch",
                    detail: detail,
                    byteOffset: pack.fileOffset
                ))
            }
        }

        return issues
    }

    // MARK: - Codec Identification

    /// Map MXF-GC essence container ULs to human-readable codec names.
    /// These ULs come from the partition pack's essence container batch.
    private func identifyCodecs(from essenceULs: [[UInt8]]) -> [String] {
        essenceULs.compactMap { ul -> String? in
            guard ul.count >= 16 else { return nil }
            // MXF-GC labels: 06.0e.2b.34.04.01.01.XX.0d.01.03.01.02.YY.ZZ.WW
            guard ul[0] == 0x06, ul[1] == 0x0E, ul[2] == 0x2B, ul[3] == 0x34,
                  ul[8] == 0x0D, ul[9] == 0x01, ul[10] == 0x03, ul[11] == 0x01 else { return nil }

            let codecByte = ul[13]
            switch codecByte {
            case 0x01: return "D-10 (MPEG-2 IMX)"
            case 0x04: return "MPEG-2 Video"
            case 0x05: return "MPEG-2 Long GOP"
            case 0x06: return "AES3/PCM Audio"
            case 0x07: return "MPEG-2 Audio (Layer 1)"
            case 0x08: return "MPEG-2 Audio (Layer 2)"
            case 0x0A: return "A-law Audio"
            case 0x0C: return "JPEG 2000"
            case 0x10: return "AVC (H.264)"
            case 0x11: return "VC-3 (DNxHD/DNxHR)"
            case 0x12: return "VC-1"
            case 0x13: return "Timed Text"
            case 0x15: return "AVC-Intra"
            case 0x17: return "HEVC (H.265)"
            case 0x1C: return "ProRes"
            case 0x24: return "FFV1"
            default:   return "Essence 0x\(String(format: "%02X", codecByte))"
            }
        }
    }
}
