import Foundation

/// Inspects ISO Base Media File Format containers (MP4, MOV, M4V, 3GP).
/// Parses the box/atom tree and validates structural integrity, edit lists,
/// sync sample tables, and composition time offsets.
struct ISOBMFFInspector: ContainerInspector {

    static let supportedExtensions: Set<String> = ["mp4", "mov", "m4v", "m4a", "3gp"]

    func canInspect(url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if Self.supportedExtensions.contains(ext) { return true }
        // Fallback: check magic bytes (ftyp box)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8) else { return false }
        return header.count >= 8 && String(data: header[4..<8], encoding: .ascii) == "ftyp"
    }

    func inspect(url: URL, depth: InspectionDepth) async throws -> ContainerReport {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let fileSize = UInt64(data.count)
        var issues: [ContainerDiagnostic] = []

        // Phase 1: Walk the top-level box tree
        let topBoxes = parseBoxes(data: data, offset: 0, end: fileSize, depth: 0, maxDepth: 0)

        // Phase 2: Validate top-level structure
        issues.append(contentsOf: validateTopLevel(boxes: topBoxes, fileSize: fileSize))

        // Phase 3: Find moov and parse deeper
        var editLists: [EditListInfo] = []
        var keyframeCounts: [Int: Int] = [:]
        var fullTree: [BoxInfo] = topBoxes

        if let moovBox = topBoxes.first(where: { $0.type == "moov" }) {
            let moovChildren = parseBoxes(
                data: data,
                offset: moovBox.offset + 8,
                end: moovBox.offset + moovBox.size,
                depth: 1,
                maxDepth: 4
            )
            fullTree = topBoxes.map { box in
                box.type == "moov" ? BoxInfo(id: box.id, type: box.type, offset: box.offset, size: box.size, children: moovChildren) : box
            }

            // Find all trak boxes
            let traks = moovChildren.filter { $0.type == "trak" }
            for (trackIndex, trak) in traks.enumerated() {
                let trakChildren = parseBoxes(
                    data: data,
                    offset: trak.offset + 8,
                    end: trak.offset + trak.size,
                    depth: 2,
                    maxDepth: 4
                )

                // Check edts → elst
                if let edts = trakChildren.first(where: { $0.type == "edts" }) {
                    let edtsChildren = parseBoxes(
                        data: data,
                        offset: edts.offset + 8,
                        end: edts.offset + edts.size,
                        depth: 3,
                        maxDepth: 4
                    )
                    if let elst = edtsChildren.first(where: { $0.type == "elst" }) {
                        let editList = parseEditList(data: data, box: elst)
                        editLists.append(EditListInfo(trackIndex: trackIndex, entries: editList))
                    }
                }

                // Check mdia → minf → stbl for stss, ctts, stts
                if let mdia = trakChildren.first(where: { $0.type == "mdia" }) {
                    let mdiaChildren = parseBoxes(data: data, offset: mdia.offset + 8, end: mdia.offset + mdia.size, depth: 3, maxDepth: 5)

                    // Get timescale from mdhd
                    let trackTimescale = parseMediaTimescale(data: data, mdiaChildren: mdiaChildren)

                    if let minf = mdiaChildren.first(where: { $0.type == "minf" }) {
                        let minfChildren = parseBoxes(data: data, offset: minf.offset + 8, end: minf.offset + minf.size, depth: 4, maxDepth: 6)
                        if let stbl = minfChildren.first(where: { $0.type == "stbl" }) {
                            let stblChildren = parseBoxes(data: data, offset: stbl.offset + 8, end: stbl.offset + stbl.size, depth: 5, maxDepth: 6)

                            // Parse stss (sync sample table)
                            let keyframes = parseSTSS(data: data, stblChildren: stblChildren)
                            keyframeCounts[trackIndex] = keyframes.count

                            // Parse stts (sample-to-time)
                            let sampleTimes = parseSTTS(data: data, stblChildren: stblChildren)

                            // Parse ctts (composition time offsets)
                            let compositionOffsets = parseCTTS(data: data, stblChildren: stblChildren)

                            // Parse sample table index tables
                            let chunkOffsets = parseSTCO(data: data, stblChildren: stblChildren)
                            let sampleToChunk = parseSTSC(data: data, stblChildren: stblChildren)
                            let sampleSizes = parseSTSZ(data: data, stblChildren: stblChildren)

                            // Validate edit list against keyframes
                            if let editListInfo = editLists.first(where: { $0.trackIndex == trackIndex }) {
                                issues.append(contentsOf: validateEditList(
                                    editList: editListInfo,
                                    keyframes: keyframes,
                                    sampleTimes: sampleTimes,
                                    compositionOffsets: compositionOffsets,
                                    trackTimescale: trackTimescale,
                                    trackIndex: trackIndex
                                ))
                            }

                            // Validate timing tables (stts / ctts)
                            issues.append(contentsOf: validateTimingTables(
                                sampleTimes: sampleTimes,
                                compositionOffsets: compositionOffsets,
                                sampleSizes: sampleSizes,
                                trackTimescale: trackTimescale,
                                trackIndex: trackIndex
                            ))

                            // Cross-validate sample tables for video tracks
                            let isVideo = isVideoTrack(data: data, trakChildren: trakChildren)
                            if isVideo {
                                let mdatBox = topBoxes.first(where: { $0.type == "mdat" })
                                issues.append(contentsOf: validateSampleTables(
                                    chunkOffsets: chunkOffsets,
                                    sampleToChunk: sampleToChunk,
                                    sampleSizes: sampleSizes,
                                    keyframes: keyframes,
                                    sampleTimes: sampleTimes,
                                    stblChildren: stblChildren,
                                    mdatBox: mdatBox,
                                    fileSize: fileSize,
                                    trackIndex: trackIndex
                                ))
                            }

                            // SPS/PPS presence validation
                            if isVideo {
                                issues.append(contentsOf: validateParameterSets(
                                    data: data,
                                    stblChildren: stblChildren,
                                    trackIndex: trackIndex
                                ))
                            }

                            // NAL unit boundary validation (Wave 2)
                            if isVideo && depth != .quick {
                                if let codecConfig = parseCodecConfig(data: data, stblChildren: stblChildren) {
                                    issues.append(contentsOf: validateNALBoundaries(
                                        data: data,
                                        chunkOffsets: chunkOffsets,
                                        sampleToChunk: sampleToChunk,
                                        sampleSizes: sampleSizes,
                                        keyframes: keyframes,
                                        codecConfig: codecConfig,
                                        depth: depth,
                                        trackIndex: trackIndex
                                    ))
                                }
                            }

                            // Validate stss presence for video tracks
                            if isVideo && keyframes.isEmpty {
                                let stssExists = stblChildren.contains { $0.type == "stss" }
                                if !stssExists {
                                    // No stss = every frame is a sync sample (all-intra). That's fine.
                                } else {
                                    issues.append(ContainerDiagnostic(
                                        category: .syncSampleTable,
                                        severity: .warning,
                                        title: "Empty Sync Sample Table",
                                        detail: "Track \(trackIndex) has an stss atom with no keyframes. Seeking will be unreliable.",
                                        remediation: .remux,
                                        playerNotes: "Seeking broken in all players; sequential playback may still work"
                                    ))
                                }
                            }
                        }
                    }
                }
            }
        }

        let metadata = ContainerMetadata(
            boxTree: fullTree,
            editLists: editLists.isEmpty ? nil : editLists,
            keyframeCounts: keyframeCounts.isEmpty ? nil : keyframeCounts,
            partitions: nil,
            operationalPattern: nil
        )

        return ContainerReport(
            containerType: .isobmff,
            issues: issues,
            metadata: metadata
        )
    }

    // MARK: - Box Parsing

    private func parseBoxes(data: Data, offset: UInt64, end: UInt64, depth: Int, maxDepth: Int) -> [BoxInfo] {
        var boxes: [BoxInfo] = []
        var pos = offset
        let safeEnd = min(end, UInt64(data.count))

        while pos + 8 <= safeEnd {
            let size32 = data.readUInt32BE(at: pos)
            let typeBytes = data[Int(pos + 4)..<Int(pos + 8)]
            let type = String(data: typeBytes, encoding: .ascii) ?? "????"

            var boxSize: UInt64
            var headerSize: UInt64 = 8

            if size32 == 1 {
                // 64-bit extended size
                guard pos + 16 <= safeEnd else { break }
                boxSize = data.readUInt64BE(at: pos + 8)
                headerSize = 16
            } else if size32 == 0 {
                // Box extends to end of file
                boxSize = safeEnd - pos
            } else {
                boxSize = UInt64(size32)
            }

            guard boxSize >= headerSize else { break }
            guard pos + boxSize <= safeEnd else {
                // Truncated box — record what we have
                boxes.append(BoxInfo(type: type, offset: pos, size: boxSize))
                break
            }

            var children: [BoxInfo] = []
            if depth < maxDepth && isContainerBox(type) {
                children = parseBoxes(data: data, offset: pos + headerSize, end: pos + boxSize, depth: depth + 1, maxDepth: maxDepth)
            }

            boxes.append(BoxInfo(type: type, offset: pos, size: boxSize, children: children))
            pos += boxSize
        }

        return boxes
    }

    private static let containerTypes: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "udta", "meta",
        "edts", "dinf", "sinf", "mvex", "moof", "traf", "schi"
    ]

    private func isContainerBox(_ type: String) -> Bool {
        Self.containerTypes.contains(type)
    }

    // MARK: - Top-level Validation

    private func validateTopLevel(boxes: [BoxInfo], fileSize: UInt64) -> [ContainerDiagnostic] {
        var issues: [ContainerDiagnostic] = []

        // Check ftyp is first box
        if let first = boxes.first, first.type != "ftyp" {
            issues.append(ContainerDiagnostic(
                category: .boxStructure,
                severity: .info,
                title: "Non-standard Box Order",
                detail: "First box is '\(first.type)', expected 'ftyp'. Some players may have trouble identifying this file.",
                byteOffset: 0
            ))
        }

        // Check moov exists
        let hasMoov = boxes.contains { $0.type == "moov" }
        if !hasMoov {
            issues.append(ContainerDiagnostic(
                category: .missingAtom,
                severity: .error,
                title: "Missing moov Atom",
                detail: "No movie header (moov) found. File is severely corrupt or incomplete.",
                remediation: .reencode
            ))
        }

        // Check mdat exists
        let hasMdat = boxes.contains { $0.type == "mdat" }
        if !hasMdat && hasMoov {
            issues.append(ContainerDiagnostic(
                category: .missingAtom,
                severity: .warning,
                title: "Missing mdat Atom",
                detail: "No media data (mdat) found. File may use fragmented MP4 (fMP4) with moof/mdat segments."
            ))
        }

        // Check for truncated boxes
        let totalCovered = boxes.reduce(UInt64(0)) { $0 + $1.size }
        if totalCovered > fileSize {
            issues.append(ContainerDiagnostic(
                category: .truncatedAtom,
                severity: .error,
                title: "Truncated Container",
                detail: "Box sizes total \(totalCovered) bytes but file is only \(fileSize) bytes. File appears truncated.",
                remediation: .reencode
            ))
        }

        // Check for invalid box sizes
        for (idx, box) in boxes.enumerated() {
            // Size < 8 is impossible (except size=0 meaning "to end" and size=1 meaning extended)
            if box.size > 0 && box.size < 8 {
                issues.append(ContainerDiagnostic(
                    category: .boxStructure,
                    severity: .error,
                    title: "Invalid Box Size",
                    detail: "Box '\(box.type)' at offset \(box.offset) has size \(box.size) — less than the 8-byte minimum header. Container is corrupt.",
                    byteOffset: box.offset,
                    remediation: .reencode,
                    playerNotes: "Most players abort parsing at this point; all subsequent boxes are unreachable"
                ))
            }
            // Size extends beyond file
            if box.offset + box.size > fileSize && box.size != 0 {
                issues.append(ContainerDiagnostic(
                    category: .boxStructure,
                    severity: .error,
                    title: "Box Extends Beyond EOF",
                    detail: "Box '\(box.type)' at offset \(box.offset) declares size \(box.size) but file is only \(fileSize) bytes. Box is truncated.",
                    byteOffset: box.offset,
                    remediation: .reencode
                ))
            }
            // Overlapping: this box's range overlaps with the next
            if idx + 1 < boxes.count {
                let thisEnd = box.offset + box.size
                let nextStart = boxes[idx + 1].offset
                if thisEnd > nextStart {
                    issues.append(ContainerDiagnostic(
                        category: .boxStructure,
                        severity: .error,
                        title: "Overlapping Boxes",
                        detail: "Box '\(box.type)' (offset \(box.offset), size \(box.size)) overlaps with '\(boxes[idx + 1].type)' at offset \(nextStart). File structure is corrupt.",
                        byteOffset: box.offset,
                        remediation: .reencode
                    ))
                }
            }
        }

        // Check moov position (before or after mdat)
        if let moovIdx = boxes.firstIndex(where: { $0.type == "moov" }),
           let mdatIdx = boxes.firstIndex(where: { $0.type == "mdat" }) {
            if moovIdx > mdatIdx {
                issues.append(ContainerDiagnostic(
                    category: .boxStructure,
                    severity: .info,
                    title: "moov After mdat",
                    detail: "Movie header is after media data. Streaming playback requires downloading the entire file first. Use 'faststart' to move moov before mdat.",
                    remediation: .remux
                ))
            }
        }

        return issues
    }

    // MARK: - Edit List Parsing

    private func parseEditList(data: Data, box: BoxInfo) -> [EditListEntry] {
        let bodyStart = box.offset + 8
        let boxEnd = min(box.offset + box.size, UInt64(data.count))
        guard bodyStart + 8 <= boxEnd else { return [] }

        let version = data[Int(bodyStart)]
        let entryCount = data.readUInt32BE(at: bodyStart + 4)
        var entries: [EditListEntry] = []
        var pos = bodyStart + 8

        for _ in 0..<entryCount {
            if version == 0 {
                guard pos + 12 <= boxEnd else { break }
                let duration = Int64(data.readUInt32BE(at: pos))
                let mediaTime = Int64(Int32(bitPattern: data.readUInt32BE(at: pos + 4)))
                let rateInt = Int16(bitPattern: data.readUInt16BE(at: pos + 8))
                let rateFrac = Int16(bitPattern: data.readUInt16BE(at: pos + 10))
                entries.append(EditListEntry(segmentDuration: duration, mediaTime: mediaTime, mediaRateInteger: rateInt, mediaRateFraction: rateFrac))
                pos += 12
            } else {
                guard pos + 20 <= boxEnd else { break }
                let duration = Int64(bitPattern: data.readUInt64BE(at: pos))
                let mediaTime = Int64(bitPattern: data.readUInt64BE(at: pos + 8))
                let rateInt = Int16(bitPattern: data.readUInt16BE(at: pos + 16))
                let rateFrac = Int16(bitPattern: data.readUInt16BE(at: pos + 18))
                entries.append(EditListEntry(segmentDuration: duration, mediaTime: mediaTime, mediaRateInteger: rateInt, mediaRateFraction: rateFrac))
                pos += 20
            }
        }
        return entries
    }

    // MARK: - stss (Sync Sample Table)

    private func parseSTSS(data: Data, stblChildren: [BoxInfo]) -> [UInt32] {
        guard let stss = stblChildren.first(where: { $0.type == "stss" }) else { return [] }
        let bodyStart = stss.offset + 8
        let stssEnd = min(stss.offset + stss.size, UInt64(data.count))
        guard bodyStart + 8 <= stssEnd else { return [] }

        // version(1) + flags(3) + entry_count(4)
        let entryCount = data.readUInt32BE(at: bodyStart + 4)
        var samples: [UInt32] = []
        samples.reserveCapacity(Int(min(entryCount, 1_000_000)))
        var pos = bodyStart + 8

        for _ in 0..<entryCount {
            guard pos + 4 <= stssEnd else { break }
            samples.append(data.readUInt32BE(at: pos))
            pos += 4
        }
        return samples
    }

    // MARK: - stts (Sample-to-Time Table)

    /// Returns array of (sampleCount, sampleDelta) tuples
    private func parseSTTS(data: Data, stblChildren: [BoxInfo]) -> [(count: UInt32, delta: UInt32)] {
        guard let stts = stblChildren.first(where: { $0.type == "stts" }) else { return [] }
        let bodyStart = stts.offset + 8
        let sttsEnd = min(stts.offset + stts.size, UInt64(data.count))
        guard bodyStart + 8 <= sttsEnd else { return [] }

        let entryCount = data.readUInt32BE(at: bodyStart + 4)
        var entries: [(count: UInt32, delta: UInt32)] = []
        var pos = bodyStart + 8

        for _ in 0..<entryCount {
            guard pos + 8 <= sttsEnd else { break }
            let count = data.readUInt32BE(at: pos)
            let delta = data.readUInt32BE(at: pos + 4)
            entries.append((count: count, delta: delta))
            pos += 8
        }
        return entries
    }

    // MARK: - ctts (Composition Time Offsets)

    /// Returns array of (sampleCount, compositionOffset) tuples
    private func parseCTTS(data: Data, stblChildren: [BoxInfo]) -> [(count: UInt32, offset: Int32)] {
        guard let ctts = stblChildren.first(where: { $0.type == "ctts" }) else { return [] }
        let bodyStart = ctts.offset + 8
        let cttsEnd = min(ctts.offset + ctts.size, UInt64(data.count))
        guard bodyStart + 8 <= cttsEnd else { return [] }

        let version = data[Int(bodyStart)]
        let entryCount = data.readUInt32BE(at: bodyStart + 4)
        var entries: [(count: UInt32, offset: Int32)] = []
        var pos = bodyStart + 8

        for _ in 0..<entryCount {
            guard pos + 8 <= cttsEnd else { break }
            let count = data.readUInt32BE(at: pos)
            let offset: Int32
            if version == 0 {
                // unsigned offset
                offset = Int32(bitPattern: data.readUInt32BE(at: pos + 4))
            } else {
                // signed offset (version 1)
                offset = Int32(bitPattern: data.readUInt32BE(at: pos + 4))
            }
            entries.append((count: count, offset: offset))
            pos += 8
        }
        return entries
    }

    // MARK: - stco / co64 (Chunk Offset Table)

    /// Parse chunk offsets from stco (32-bit) or co64 (64-bit).
    /// Returns absolute file offsets of each chunk.
    private func parseSTCO(data: Data, stblChildren: [BoxInfo]) -> [UInt64] {
        // Prefer co64 for large files
        if let co64 = stblChildren.first(where: { $0.type == "co64" }) {
            return parseChunkOffsets64(data: data, box: co64)
        }
        if let stco = stblChildren.first(where: { $0.type == "stco" }) {
            return parseChunkOffsets32(data: data, box: stco)
        }
        return []
    }

    private func parseChunkOffsets32(data: Data, box: BoxInfo) -> [UInt64] {
        let bodyStart = box.offset + 8
        let boxEnd = min(box.offset + box.size, UInt64(data.count))
        guard bodyStart + 8 <= boxEnd else { return [] }

        let entryCount = data.readUInt32BE(at: bodyStart + 4)
        var offsets: [UInt64] = []
        offsets.reserveCapacity(Int(min(entryCount, 1_000_000)))
        var pos = bodyStart + 8

        for _ in 0..<entryCount {
            guard pos + 4 <= boxEnd else { break }
            offsets.append(UInt64(data.readUInt32BE(at: pos)))
            pos += 4
        }
        return offsets
    }

    private func parseChunkOffsets64(data: Data, box: BoxInfo) -> [UInt64] {
        let bodyStart = box.offset + 8
        let boxEnd = min(box.offset + box.size, UInt64(data.count))
        guard bodyStart + 8 <= boxEnd else { return [] }

        let entryCount = data.readUInt32BE(at: bodyStart + 4)
        var offsets: [UInt64] = []
        offsets.reserveCapacity(Int(min(entryCount, 1_000_000)))
        var pos = bodyStart + 8

        for _ in 0..<entryCount {
            guard pos + 8 <= boxEnd else { break }
            offsets.append(data.readUInt64BE(at: pos))
            pos += 8
        }
        return offsets
    }

    // MARK: - stsc (Sample-to-Chunk Table)

    private struct SampleToChunkEntry {
        let firstChunk: UInt32
        let samplesPerChunk: UInt32
        let sampleDescIndex: UInt32
    }

    private func parseSTSC(data: Data, stblChildren: [BoxInfo]) -> [SampleToChunkEntry] {
        guard let stsc = stblChildren.first(where: { $0.type == "stsc" }) else { return [] }
        let bodyStart = stsc.offset + 8
        let boxEnd = min(stsc.offset + stsc.size, UInt64(data.count))
        guard bodyStart + 8 <= boxEnd else { return [] }

        let entryCount = data.readUInt32BE(at: bodyStart + 4)
        var entries: [SampleToChunkEntry] = []
        entries.reserveCapacity(Int(min(entryCount, 1_000_000)))
        var pos = bodyStart + 8

        for _ in 0..<entryCount {
            guard pos + 12 <= boxEnd else { break }
            entries.append(SampleToChunkEntry(
                firstChunk: data.readUInt32BE(at: pos),
                samplesPerChunk: data.readUInt32BE(at: pos + 4),
                sampleDescIndex: data.readUInt32BE(at: pos + 8)
            ))
            pos += 12
        }
        return entries
    }

    // MARK: - stsz (Sample Size Table)

    private struct SampleSizeInfo {
        let uniformSize: UInt32     // If > 0, all samples are this size
        let sizes: [UInt32]         // Per-sample sizes (empty if uniformSize > 0)
        var sampleCount: UInt32 {
            uniformSize > 0 ? UInt32(sizes.count == 0 ? 0 : UInt32(sizes.count)) : UInt32(sizes.count)
        }
    }

    private func parseSTSZ(data: Data, stblChildren: [BoxInfo]) -> SampleSizeInfo {
        guard let stsz = stblChildren.first(where: { $0.type == "stsz" }) else {
            return SampleSizeInfo(uniformSize: 0, sizes: [])
        }
        let bodyStart = stsz.offset + 8
        let boxEnd = min(stsz.offset + stsz.size, UInt64(data.count))
        guard bodyStart + 12 <= boxEnd else { return SampleSizeInfo(uniformSize: 0, sizes: []) }

        // version(1) + flags(3) + sample_size(4) + sample_count(4)
        let uniformSize = data.readUInt32BE(at: bodyStart + 4)
        let sampleCount = data.readUInt32BE(at: bodyStart + 8)

        if uniformSize > 0 {
            // All samples are the same size — no per-sample table
            return SampleSizeInfo(uniformSize: uniformSize, sizes: Array(repeating: uniformSize, count: Int(min(sampleCount, 10_000_000))))
        }

        var sizes: [UInt32] = []
        sizes.reserveCapacity(Int(min(sampleCount, 10_000_000)))
        var pos = bodyStart + 12

        for _ in 0..<sampleCount {
            guard pos + 4 <= boxEnd else { break }
            sizes.append(data.readUInt32BE(at: pos))
            pos += 4
        }
        return SampleSizeInfo(uniformSize: 0, sizes: sizes)
    }

    // MARK: - Timing Table Validation (stts / ctts)

    private func validateTimingTables(
        sampleTimes: [(count: UInt32, delta: UInt32)],
        compositionOffsets: [(count: UInt32, offset: Int32)],
        sampleSizes: SampleSizeInfo,
        trackTimescale: UInt32,
        trackIndex: Int
    ) -> [ContainerDiagnostic] {
        var issues: [ContainerDiagnostic] = []
        guard !sampleTimes.isEmpty else { return issues }

        let sttsTotalSamples = sampleTimes.reduce(UInt64(0)) { $0 + UInt64($1.count) }

        // ── stts Check 1: Zero deltas (non-monotonic DTS) ─────────────────
        var zeroDeltas: UInt64 = 0
        for entry in sampleTimes {
            if entry.delta == 0 && entry.count > 0 {
                zeroDeltas += UInt64(entry.count)
            }
        }
        if zeroDeltas > 0 {
            issues.append(ContainerDiagnostic(
                category: .sampleTable,
                severity: .warning,
                title: "Zero Duration Samples in stts",
                detail: "Track \(trackIndex): \(zeroDeltas) samples have delta=0 in the decode time table. These frames share the same DTS, causing non-monotonic decode timestamps.",
                remediation: .remux,
                playerNotes: "May cause A/V desync; ffmpeg warns 'non-monotonous DTS'; some players drop duplicates"
            ))
        }

        // ── stts Check 2: Extremely large deltas ──────────────────────────
        if trackTimescale > 0 {
            let maxReasonableDelta = UInt32(trackTimescale * 10) // 10 seconds
            for entry in sampleTimes {
                if entry.delta > maxReasonableDelta && entry.count > 0 {
                    let seconds = Double(entry.delta) / Double(trackTimescale)
                    issues.append(ContainerDiagnostic(
                        category: .sampleTable,
                        severity: .warning,
                        title: "Abnormal Frame Duration in stts",
                        detail: "Track \(trackIndex): \(entry.count) samples have delta=\(entry.delta) (\(String(format: "%.1f", seconds))s per frame). This suggests corrupt timing data or a non-standard encoding.",
                        remediation: .remux
                    ))
                    break // One diagnostic is enough
                }
            }
        }

        // ── stts Check 3: Sample count consistency with stsz ──────────────
        let stszCount = UInt64(sampleSizes.sizes.count)
        if stszCount > 0 && sttsTotalSamples > 0 && sttsTotalSamples != stszCount {
            issues.append(ContainerDiagnostic(
                category: .sampleTable,
                severity: .error,
                title: "Sample Count Mismatch (stts vs stsz)",
                detail: "Track \(trackIndex): stts declares \(sttsTotalSamples) samples but stsz contains \(stszCount) entries. Sample table is inconsistent.",
                remediation: .reencode,
                playerNotes: "Most players use the smaller count; tail frames may be lost or garbled"
            ))
        }

        // ── ctts Check 1: Total sample count matches stts ─────────────────
        if !compositionOffsets.isEmpty {
            let cttsTotalSamples = compositionOffsets.reduce(UInt64(0)) { $0 + UInt64($1.count) }
            if cttsTotalSamples != sttsTotalSamples && sttsTotalSamples > 0 {
                issues.append(ContainerDiagnostic(
                    category: .compositionTime,
                    severity: .warning,
                    title: "Composition Offset Count Mismatch",
                    detail: "Track \(trackIndex): ctts covers \(cttsTotalSamples) samples but stts declares \(sttsTotalSamples). Tail frames will have undefined presentation times.",
                    remediation: .remux,
                    playerNotes: "A/V desync worsens over playback; QuickTime may freeze near end"
                ))
            }

            // ── ctts Check 2: Extreme composition offsets ─────────────────
            if trackTimescale > 0 {
                let maxReasonableOffset = Int32(trackTimescale * 5) // 5 seconds
                var extremeCount = 0
                for entry in compositionOffsets {
                    if abs(entry.offset) > maxReasonableOffset {
                        extremeCount += Int(entry.count)
                    }
                }
                if extremeCount > 0 {
                    issues.append(ContainerDiagnostic(
                        category: .compositionTime,
                        severity: .warning,
                        title: "Extreme Composition Offsets in ctts",
                        detail: "Track \(trackIndex): \(extremeCount) samples have composition offsets exceeding 5 seconds. This suggests corrupt ctts data or an unusual GOP structure.",
                        remediation: .remux
                    ))
                }
            }
        }

        return issues
    }

    // MARK: - Sample Table Cross-Validation

    private func validateSampleTables(
        chunkOffsets: [UInt64],
        sampleToChunk: [SampleToChunkEntry],
        sampleSizes: SampleSizeInfo,
        keyframes: [UInt32],
        sampleTimes: [(count: UInt32, delta: UInt32)],
        stblChildren: [BoxInfo],
        mdatBox: BoxInfo?,
        fileSize: UInt64,
        trackIndex: Int
    ) -> [ContainerDiagnostic] {
        var issues: [ContainerDiagnostic] = []
        let totalSampleCount = sampleTimes.reduce(UInt64(0)) { $0 + UInt64($1.count) }

        // ── Check 0: stco overflow for >4GB files ─────────────────────────
        let fourGB: UInt64 = 4_294_967_296
        let usesStco = stblChildren.contains { $0.type == "stco" }
        let usesCo64 = stblChildren.contains { $0.type == "co64" }
        if fileSize > fourGB && usesStco && !usesCo64 {
            issues.append(ContainerDiagnostic(
                category: .sampleTable,
                severity: .error,
                title: "32-bit Chunk Offsets on >4GB File",
                detail: "Track \(trackIndex): file is \(fileSize / (1024*1024))MB but uses 32-bit stco (max 4GB). Chunk offsets above 4GB will wrap around, making the second half of the video inaccessible.",
                remediation: .remux,
                playerNotes: "Playback fails or loops after ~4GB mark; remux with co64 support fixes this"
            ))
        }

        // ── Check 1: stco offsets within mdat bounds ─────────────────────
        if let mdat = mdatBox {
            let mdatDataStart = mdat.offset + 8  // 8-byte header (size + type)
            let mdatEnd = mdat.offset + mdat.size
            var outOfBounds = 0
            var borderline = 0
            let borderlineThreshold = mdatEnd - (mdat.size / 100) // last 1%

            for offset in chunkOffsets {
                if offset < mdatDataStart || offset >= mdatEnd {
                    outOfBounds += 1
                } else if offset >= borderlineThreshold {
                    borderline += 1
                }
            }

            if outOfBounds > 0 {
                issues.append(ContainerDiagnostic(
                    category: .sampleTable,
                    severity: .error,
                    title: "Chunk Offsets Outside mdat",
                    detail: "Track \(trackIndex): \(outOfBounds) of \(chunkOffsets.count) chunk offsets point outside the mdat atom. File is truncated or index is corrupt.",
                    remediation: .reencode,
                    playerNotes: "VLC may still play (high tolerance); QuickTime and AVFoundation will fail"
                ))
            } else if borderline > 0 {
                issues.append(ContainerDiagnostic(
                    category: .sampleTable,
                    severity: .warning,
                    title: "Chunk Offsets Near mdat Boundary",
                    detail: "Track \(trackIndex): \(borderline) chunk offsets are in the last 1% of mdat. File may be borderline truncated.",
                    remediation: .reencode
                ))
            }
        }

        // ── Check 2: stss indices within sample count ────────────────────
        if totalSampleCount > 0 {
            let outOfRange = keyframes.filter { $0 < 1 || UInt64($0) > totalSampleCount }
            if !outOfRange.isEmpty {
                issues.append(ContainerDiagnostic(
                    category: .syncSampleTable,
                    severity: .error,
                    title: "Invalid Keyframe Indices",
                    detail: "Track \(trackIndex): \(outOfRange.count) sync sample entries reference samples outside valid range (1–\(totalSampleCount)).",
                    remediation: .reencode
                ))
            }
        }

        // ── Check 3: Total sample data fits within mdat ──────────────────
        if let mdat = mdatBox {
            let mdatPayload = mdat.size >= 8 ? mdat.size - 8 : 0
            let totalSampleBytes: UInt64
            if sampleSizes.uniformSize > 0 {
                totalSampleBytes = UInt64(sampleSizes.uniformSize) * totalSampleCount
            } else {
                totalSampleBytes = sampleSizes.sizes.reduce(UInt64(0)) { $0 + UInt64($1) }
            }

            if totalSampleBytes > mdatPayload && mdatPayload > 0 {
                issues.append(ContainerDiagnostic(
                    category: .sampleTable,
                    severity: .error,
                    title: "Sample Sizes Exceed Media Data",
                    detail: "Track \(trackIndex): sample table declares \(totalSampleBytes) bytes of samples but mdat contains only \(mdatPayload) bytes. File is truncated.",
                    remediation: .reencode,
                    playerNotes: "VLC may still play (high tolerance); QuickTime and AVFoundation will fail"
                ))
            }
        }

        // ── Check 4: First video sample is a keyframe ────────────────────
        if !keyframes.isEmpty && !keyframes.contains(1) {
            issues.append(ContainerDiagnostic(
                category: .syncSampleTable,
                severity: .warning,
                title: "First Frame Not a Keyframe",
                detail: "Track \(trackIndex): sample 1 is not in the sync sample table. Playback may start with artifacts.",
                remediation: .remux,
                playerNotes: "AVFoundation shows green/black frames until first keyframe; VLC and mpv recover faster"
            ))
        }

        // ── Check 5: Zero-size video samples ─────────────────────────────
        if sampleSizes.uniformSize == 0 {
            let zeroCount = sampleSizes.sizes.filter { $0 == 0 }.count
            if zeroCount > 0 {
                issues.append(ContainerDiagnostic(
                    category: .sampleTable,
                    severity: .warning,
                    title: "Zero-Size Samples Detected",
                    detail: "Track \(trackIndex): \(zeroCount) video samples have size 0. These may represent dropped frames or encoding errors."
                ))
            }
        }

        // ── Check 6: Chunk offset ordering ───────────────────────────────
        if chunkOffsets.count > 1 {
            var outOfOrder = 0
            for i in 1..<chunkOffsets.count {
                if chunkOffsets[i] <= chunkOffsets[i - 1] {
                    outOfOrder += 1
                }
            }
            if outOfOrder > 0 {
                issues.append(ContainerDiagnostic(
                    category: .sampleTable,
                    severity: .warning,
                    title: "Non-Monotonic Chunk Offsets",
                    detail: "Track \(trackIndex): \(outOfOrder) chunk offsets are out of order. File may have been incorrectly muxed.",
                    remediation: .remux,
                    playerNotes: "Some players recover with sequential scan; seeking will be incorrect"
                ))
            }
        }

        return issues
    }

    // MARK: - Codec Config (avcC / hvcC)

    private enum VideoCodecType { case h264, h265, other }

    private struct CodecConfig {
        let codecType: VideoCodecType
        let nalLengthSize: Int  // 1, 2, or 4 bytes
    }

    /// Extract NAL length size from the avcC or hvcC box within stsd.
    private func parseCodecConfig(data: Data, stblChildren: [BoxInfo]) -> CodecConfig? {
        guard let stsd = stblChildren.first(where: { $0.type == "stsd" }) else { return nil }
        let bodyStart = stsd.offset + 8
        let stsdEnd = min(stsd.offset + stsd.size, UInt64(data.count))
        // stsd: version(1) + flags(3) + entry_count(4) + first sample entry
        guard bodyStart + 16 <= stsdEnd else { return nil }

        // First sample entry starts at bodyStart + 8
        let entryStart = bodyStart + 8
        guard entryStart + 8 <= stsdEnd else { return nil }
        let entrySize = UInt64(data.readUInt32BE(at: entryStart))
        let entryEnd = min(entryStart + entrySize, stsdEnd)

        // Video sample entry: 8-byte header + 70 bytes fixed fields = 78 bytes before child boxes
        guard entryStart + 78 <= entryEnd else { return nil }

        // Scan child boxes within the sample entry (after the 78-byte fixed header)
        let childrenStart = entryStart + 78
        var pos = childrenStart
        while pos + 8 <= entryEnd {
            let boxSize = UInt64(data.readUInt32BE(at: pos))
            guard boxSize >= 8, pos + boxSize <= entryEnd else { break }
            let typeBytes = data[Int(pos + 4)..<Int(pos + 8)]
            let type = String(data: typeBytes, encoding: .ascii) ?? ""

            if type == "avcC" {
                // avcC: configurationVersion(1) + profile(1) + compat(1) + level(1) + lengthSizeMinusOne(1)
                let configStart = pos + 8
                guard configStart + 5 <= pos + boxSize else { break }
                let lengthSizeMinusOne = Int(data[Int(configStart + 4)] & 0x03)
                return CodecConfig(codecType: .h264, nalLengthSize: lengthSizeMinusOne + 1)
            }

            if type == "hvcC" {
                // hvcC: many fields... lengthSizeMinusOne is at byte 21
                let configStart = pos + 8
                guard configStart + 22 <= pos + boxSize else { break }
                let lengthSizeMinusOne = Int(data[Int(configStart + 21)] & 0x03)
                return CodecConfig(codecType: .h265, nalLengthSize: lengthSizeMinusOne + 1)
            }

            pos += boxSize
        }

        return nil
    }

    // MARK: - SPS/PPS Parameter Set Validation

    /// Validate that avcC or hvcC contains required parameter sets (SPS, PPS, VPS).
    private func validateParameterSets(
        data: Data,
        stblChildren: [BoxInfo],
        trackIndex: Int
    ) -> [ContainerDiagnostic] {
        guard let stsd = stblChildren.first(where: { $0.type == "stsd" }) else { return [] }
        let bodyStart = stsd.offset + 8
        let stsdEnd = min(stsd.offset + stsd.size, UInt64(data.count))
        guard bodyStart + 16 <= stsdEnd else { return [] }

        let entryStart = bodyStart + 8
        guard entryStart + 8 <= stsdEnd else { return [] }
        let entrySize = UInt64(data.readUInt32BE(at: entryStart))
        let entryEnd = min(entryStart + entrySize, stsdEnd)
        guard entryStart + 78 <= entryEnd else { return [] }

        // Scan child boxes within the video sample entry
        var pos = entryStart + 78
        while pos + 8 <= entryEnd {
            let boxSize = UInt64(data.readUInt32BE(at: pos))
            guard boxSize >= 8, pos + boxSize <= entryEnd else { break }
            let typeBytes = data[Int(pos + 4)..<Int(pos + 8)]
            let type = String(data: typeBytes, encoding: .ascii) ?? ""

            if type == "avcC" {
                return validateAvcC(data: data, boxStart: pos, boxSize: boxSize, trackIndex: trackIndex)
            }
            if type == "hvcC" {
                return validateHvcC(data: data, boxStart: pos, boxSize: boxSize, trackIndex: trackIndex)
            }
            pos += boxSize
        }
        return []
    }

    /// Validate H.264 avcC: must contain at least 1 SPS and 1 PPS.
    private func validateAvcC(data: Data, boxStart: UInt64, boxSize: UInt64, trackIndex: Int) -> [ContainerDiagnostic] {
        var issues: [ContainerDiagnostic] = []
        let configStart = boxStart + 8
        let configEnd = boxStart + boxSize
        // avcC layout: configVersion(1) + profile(1) + compat(1) + level(1) + lengthSizeMinusOne(1) + numSPS(1)
        guard configStart + 6 <= configEnd else {
            issues.append(ContainerDiagnostic(
                category: .nalStructure,
                severity: .error,
                title: "Truncated avcC Box",
                detail: "Track \(trackIndex): avcC configuration box is too small to contain valid decoder parameters.",
                byteOffset: boxStart,
                remediation: .reencode,
                playerNotes: "Decoder cannot initialize; file is unplayable"
            ))
            return issues
        }

        let numSPS = Int(data[Int(configStart + 5)] & 0x1F)
        if numSPS == 0 {
            issues.append(ContainerDiagnostic(
                category: .nalStructure,
                severity: .error,
                title: "Missing SPS in avcC",
                detail: "Track \(trackIndex): avcC contains 0 Sequence Parameter Sets. H.264 decoder cannot initialize without SPS.",
                byteOffset: configStart + 5,
                remediation: .reencode,
                playerNotes: "File is unplayable in all players; decoder cannot determine resolution, profile, or reference frame count"
            ))
        }

        // Skip past SPS entries to find PPS count
        var readPos = configStart + 6
        for _ in 0..<numSPS {
            guard readPos + 2 <= configEnd else { return issues }
            let spsLen = UInt64(data.readUInt16BE(at: readPos))
            readPos += 2 + spsLen
        }

        guard readPos + 1 <= configEnd else { return issues }
        let numPPS = Int(data[Int(readPos)])
        if numPPS == 0 {
            issues.append(ContainerDiagnostic(
                category: .nalStructure,
                severity: .error,
                title: "Missing PPS in avcC",
                detail: "Track \(trackIndex): avcC contains 0 Picture Parameter Sets. H.264 decoder cannot decode frames without PPS.",
                byteOffset: readPos,
                remediation: .reencode,
                playerNotes: "File is unplayable; PPS defines entropy coding mode and quantization parameters"
            ))
        }

        return issues
    }

    /// Validate H.265 hvcC: must contain VPS, SPS, and PPS NAL unit arrays.
    private func validateHvcC(data: Data, boxStart: UInt64, boxSize: UInt64, trackIndex: Int) -> [ContainerDiagnostic] {
        var issues: [ContainerDiagnostic] = []
        let configStart = boxStart + 8
        let configEnd = boxStart + boxSize
        // hvcC has a 22-byte fixed header, then numOfArrays(1), then NAL unit arrays
        guard configStart + 23 <= configEnd else {
            issues.append(ContainerDiagnostic(
                category: .nalStructure,
                severity: .error,
                title: "Truncated hvcC Box",
                detail: "Track \(trackIndex): hvcC configuration box is too small to contain valid HEVC decoder parameters.",
                byteOffset: boxStart,
                remediation: .reencode,
                playerNotes: "Decoder cannot initialize; file is unplayable"
            ))
            return issues
        }

        let numArrays = Int(data[Int(configStart + 22)])
        var hasVPS = false
        var hasSPS = false
        var hasPPS = false
        var readPos = configStart + 23

        for _ in 0..<numArrays {
            guard readPos + 3 <= configEnd else { break }
            let nalType = data[Int(readPos)] & 0x3F
            let numNALUs = Int(data.readUInt16BE(at: readPos + 1))
            readPos += 3

            if nalType == 32 && numNALUs > 0 { hasVPS = true }
            if nalType == 33 && numNALUs > 0 { hasSPS = true }
            if nalType == 34 && numNALUs > 0 { hasPPS = true }

            for _ in 0..<numNALUs {
                guard readPos + 2 <= configEnd else { break }
                let naluLen = UInt64(data.readUInt16BE(at: readPos))
                readPos += 2 + naluLen
            }
        }

        if !hasVPS {
            issues.append(ContainerDiagnostic(
                category: .nalStructure,
                severity: .error,
                title: "Missing VPS in hvcC",
                detail: "Track \(trackIndex): hvcC contains no Video Parameter Set (NAL type 32). HEVC decoder cannot initialize.",
                byteOffset: boxStart,
                remediation: .reencode,
                playerNotes: "File is unplayable in all players"
            ))
        }
        if !hasSPS {
            issues.append(ContainerDiagnostic(
                category: .nalStructure,
                severity: .error,
                title: "Missing SPS in hvcC",
                detail: "Track \(trackIndex): hvcC contains no Sequence Parameter Set (NAL type 33). HEVC decoder cannot initialize.",
                byteOffset: boxStart,
                remediation: .reencode,
                playerNotes: "File is unplayable in all players"
            ))
        }
        if !hasPPS {
            issues.append(ContainerDiagnostic(
                category: .nalStructure,
                severity: .error,
                title: "Missing PPS in hvcC",
                detail: "Track \(trackIndex): hvcC contains no Picture Parameter Set (NAL type 34). HEVC decoder cannot decode any frames.",
                byteOffset: boxStart,
                remediation: .reencode,
                playerNotes: "File is unplayable in all players"
            ))
        }

        return issues
    }

    // MARK: - NAL Unit Boundary Validation

    /// Build a flat list of (fileOffset, size) for each sample, using stco + stsc + stsz.
    private func buildFrameMap(
        chunkOffsets: [UInt64],
        sampleToChunk: [SampleToChunkEntry],
        sampleSizes: SampleSizeInfo
    ) -> [(offset: UInt64, size: UInt32)] {
        guard !chunkOffsets.isEmpty, !sampleToChunk.isEmpty else { return [] }

        var frames: [(offset: UInt64, size: UInt32)] = []
        frames.reserveCapacity(sampleSizes.sizes.count)
        var sampleIndex = 0

        for chunkIndex in 0..<chunkOffsets.count {
            let chunk1Based = UInt32(chunkIndex + 1)

            // Find the stsc entry that applies to this chunk
            var samplesInChunk: UInt32 = 0
            for i in (0..<sampleToChunk.count).reversed() {
                if sampleToChunk[i].firstChunk <= chunk1Based {
                    samplesInChunk = sampleToChunk[i].samplesPerChunk
                    break
                }
            }

            var chunkPos = chunkOffsets[chunkIndex]
            for _ in 0..<samplesInChunk {
                guard sampleIndex < sampleSizes.sizes.count else { return frames }
                let size = sampleSizes.sizes[sampleIndex]
                frames.append((offset: chunkPos, size: size))
                chunkPos += UInt64(size)
                sampleIndex += 1
            }
        }

        return frames
    }

    /// Select which frame indices to check based on inspection depth.
    private func selectFramesToCheck(
        totalFrames: Int,
        keyframes: [UInt32],
        depth: InspectionDepth
    ) -> Set<Int> {
        guard totalFrames > 0 else { return [] }
        var indices = Set<Int>()

        switch depth {
        case .quick:
            return []  // No NAL validation at quick depth

        case .standard:
            // First 5 frames
            for i in 0..<min(5, totalFrames) {
                indices.insert(i)
            }
            // All keyframes (capped at 50)
            for kf in keyframes.prefix(50) {
                let idx = Int(kf) - 1  // 1-based to 0-based
                if idx >= 0 && idx < totalFrames { indices.insert(idx) }
            }
            // ~50 evenly spaced frames
            if totalFrames > 50 {
                let stride = max(1, totalFrames / 50)
                var i = 0
                while i < totalFrames {
                    indices.insert(i)
                    i += stride
                }
            }
            // Cap at 200
            if indices.count > 200 {
                indices = Set(indices.sorted().prefix(200))
            }

        case .thorough:
            // All keyframes (no cap)
            for kf in keyframes {
                let idx = Int(kf) - 1
                if idx >= 0 && idx < totalFrames { indices.insert(idx) }
            }
            // Every 10th frame
            var i = 0
            while i < totalFrames {
                indices.insert(i)
                i += 10
            }
        }

        return indices
    }

    /// Validate NAL unit structure within sampled video frames.
    private func validateNALBoundaries(
        data: Data,
        chunkOffsets: [UInt64],
        sampleToChunk: [SampleToChunkEntry],
        sampleSizes: SampleSizeInfo,
        keyframes: [UInt32],
        codecConfig: CodecConfig,
        depth: InspectionDepth,
        trackIndex: Int
    ) -> [ContainerDiagnostic] {
        var issues: [ContainerDiagnostic] = []
        let frameMap = buildFrameMap(chunkOffsets: chunkOffsets, sampleToChunk: sampleToChunk, sampleSizes: sampleSizes)
        guard !frameMap.isEmpty else { return [] }

        let framesToCheck = selectFramesToCheck(totalFrames: frameMap.count, keyframes: keyframes, depth: depth)
        guard !framesToCheck.isEmpty else { return [] }

        let nalLenSize = codecConfig.nalLengthSize
        let keyframeSet = Set(keyframes.map { Int($0) - 1 }) // 0-based
        var nalOverflowCount = 0
        var frameMismatchCount = 0
        var missingIDRKeyframes = 0
        var firstNALOverflowByte: UInt64?

        // Check first sample for IDR
        if let firstFrame = frameMap.first,
           firstFrame.size > 0,
           Int(firstFrame.offset) + Int(firstFrame.size) <= data.count {
            let hasIDR = checkForIDR(data: data, frameOffset: firstFrame.offset, frameSize: firstFrame.size, nalLenSize: nalLenSize, codec: codecConfig.codecType)
            if !hasIDR {
                issues.append(ContainerDiagnostic(
                    category: .nalStructure,
                    severity: .warning,
                    title: "First Frame Not IDR",
                    detail: "Track \(trackIndex): first video frame does not contain an IDR NAL unit. Playback requires random access point.",
                    playerNotes: "AVFoundation shows green/black frames until first keyframe; VLC and mpv recover faster"
                ))
            }
        }

        for frameIdx in framesToCheck.sorted() {
            guard frameIdx < frameMap.count else { continue }
            let frame = frameMap[frameIdx]
            guard frame.size > 0 else { continue }
            let frameEnd = frame.offset + UInt64(frame.size)
            guard Int(frameEnd) <= data.count else { continue }

            // Walk NAL units within this frame
            var pos = frame.offset
            var frameHasIDR = false

            while pos < frameEnd {
                let remaining = frameEnd - pos
                guard remaining >= UInt64(nalLenSize) else {
                    // Leftover bytes less than NAL length field
                    if remaining > 0 && remaining >= 4 {
                        frameMismatchCount += 1
                    }
                    break
                }

                // Read NAL length (big-endian)
                let nalLength: UInt64
                switch nalLenSize {
                case 4:
                    nalLength = UInt64(data.readUInt32BE(at: pos))
                case 2:
                    nalLength = UInt64(data.readUInt16BE(at: pos))
                case 1:
                    nalLength = UInt64(data[Int(pos)])
                default:
                    nalLength = UInt64(data.readUInt32BE(at: pos))
                }

                let nalStart = pos + UInt64(nalLenSize)
                let nalEnd = nalStart + nalLength

                // Check: NAL length overflow
                if nalLength == 0 || nalEnd > frameEnd {
                    nalOverflowCount += 1
                    if firstNALOverflowByte == nil { firstNALOverflowByte = pos }
                    break // Can't continue walking this frame
                }

                // Check NAL type for IDR detection
                if nalStart < UInt64(data.count) {
                    let nalHeader = data[Int(nalStart)]
                    switch codecConfig.codecType {
                    case .h264:
                        let nalType = nalHeader & 0x1F
                        if nalType == 5 { frameHasIDR = true }
                    case .h265:
                        let nalType = (nalHeader >> 1) & 0x3F
                        if nalType >= 16 && nalType <= 21 { frameHasIDR = true }
                    case .other:
                        break
                    }
                }

                pos = nalEnd
            }

            // Check frame end alignment
            if pos != frameEnd && pos < frameEnd {
                let leftover = frameEnd - pos
                if leftover >= 4 {
                    frameMismatchCount += 1
                }
            }

            // Check: keyframe should contain IDR
            if keyframeSet.contains(frameIdx) && !frameHasIDR && codecConfig.codecType == .h264 {
                missingIDRKeyframes += 1
            }
        }

        // Emit diagnostics
        if nalOverflowCount > 0 {
            issues.append(ContainerDiagnostic(
                category: .nalStructure,
                severity: .error,
                title: "NAL Unit Length Overflow",
                detail: "Track \(trackIndex): \(nalOverflowCount) frames have NAL units whose declared length exceeds frame boundaries.",
                byteOffset: firstNALOverflowByte,
                remediation: .reencode,
                playerNotes: "Most players skip corrupted frames; artifacts may cascade until next keyframe"
            ))
        }

        if frameMismatchCount > 0 {
            issues.append(ContainerDiagnostic(
                category: .nalStructure,
                severity: .warning,
                title: "Frame Size Mismatch",
                detail: "Track \(trackIndex): \(frameMismatchCount) frames have leftover bytes after parsing all NAL units."
            ))
        }

        if missingIDRKeyframes > 0 {
            issues.append(ContainerDiagnostic(
                category: .nalStructure,
                severity: .warning,
                title: "Keyframes Missing IDR NAL",
                detail: "Track \(trackIndex): \(missingIDRKeyframes) keyframes (per stss) contain no IDR NAL unit.",
                playerNotes: "AVFoundation shows green/black frames until first keyframe; VLC and mpv recover faster"
            ))
        }

        return issues
    }

    /// Check if a frame contains an IDR NAL unit.
    private func checkForIDR(data: Data, frameOffset: UInt64, frameSize: UInt32, nalLenSize: Int, codec: VideoCodecType) -> Bool {
        var pos = frameOffset
        let frameEnd = frameOffset + UInt64(frameSize)

        while pos + UInt64(nalLenSize) <= frameEnd {
            let nalLength: UInt64
            switch nalLenSize {
            case 4:  nalLength = UInt64(data.readUInt32BE(at: pos))
            case 2:  nalLength = UInt64(data.readUInt16BE(at: pos))
            case 1:  nalLength = UInt64(data[Int(pos)])
            default: nalLength = UInt64(data.readUInt32BE(at: pos))
            }

            let nalStart = pos + UInt64(nalLenSize)
            guard nalLength > 0, nalStart + nalLength <= frameEnd, nalStart < UInt64(data.count) else { break }

            let nalHeader = data[Int(nalStart)]
            switch codec {
            case .h264:
                if nalHeader & 0x1F == 5 { return true }
            case .h265:
                let nalType = (nalHeader >> 1) & 0x3F
                if nalType >= 16 && nalType <= 21 { return true }
            case .other:
                break
            }

            pos = nalStart + nalLength
        }
        return false
    }

    // MARK: - mdhd (Media Header) Timescale

    private func parseMediaTimescale(data: Data, mdiaChildren: [BoxInfo]) -> UInt32 {
        guard let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" }) else { return 0 }
        let bodyStart = mdhd.offset + 8
        let mdhdEnd = min(mdhd.offset + mdhd.size, UInt64(data.count))
        guard bodyStart < mdhdEnd else { return 0 }
        let version = data[Int(bodyStart)]

        if version == 0 {
            // version 0: skip version(1)+flags(3)+creation(4)+modification(4) = 12, then timescale(4)
            guard bodyStart + 16 <= mdhdEnd else { return 0 }
            return data.readUInt32BE(at: bodyStart + 12)
        } else {
            // version 1: skip version(1)+flags(3)+creation(8)+modification(8) = 20, then timescale(4)
            guard bodyStart + 24 <= mdhdEnd else { return 0 }
            return data.readUInt32BE(at: bodyStart + 20)
        }
    }

    // MARK: - Track Type Detection

    private func isVideoTrack(data: Data, trakChildren: [BoxInfo]) -> Bool {
        guard let mdia = trakChildren.first(where: { $0.type == "mdia" }) else { return false }
        let mdiaChildren = parseBoxes(data: data, offset: mdia.offset + 8, end: mdia.offset + mdia.size, depth: 0, maxDepth: 1)
        guard let hdlr = mdiaChildren.first(where: { $0.type == "hdlr" }) else { return false }

        let bodyStart = hdlr.offset + 8
        // version(1) + flags(3) + pre_defined(4) + handler_type(4)
        let hdlrEnd = min(hdlr.offset + hdlr.size, UInt64(data.count))
        guard bodyStart + 12 <= hdlrEnd else { return false }
        let handlerType = String(data: data[Int(bodyStart + 8)..<Int(bodyStart + 12)], encoding: .ascii)
        return handlerType == "vide"
    }

    // MARK: - Edit List Validation

    private func validateEditList(
        editList: EditListInfo,
        keyframes: [UInt32],
        sampleTimes: [(count: UInt32, delta: UInt32)],
        compositionOffsets: [(count: UInt32, offset: Int32)],
        trackTimescale: UInt32,
        trackIndex: Int
    ) -> [ContainerDiagnostic] {
        var issues: [ContainerDiagnostic] = []

        for (entryIdx, entry) in editList.entries.enumerated() {
            // Skip empty edits (media_time == -1)
            guard entry.mediaTime >= 0 else { continue }

            let mediaTime = UInt64(entry.mediaTime)

            // Check: does a keyframe exist at or before this media_time?
            if !keyframes.isEmpty {
                let keyframeTimestamps = computeKeyframeTimestamps(
                    keyframes: keyframes,
                    sampleTimes: sampleTimes
                )

                let hasKeyframeAtOrBefore = keyframeTimestamps.contains { $0 <= mediaTime }

                if !hasKeyframeAtOrBefore {
                    let mediaTimeSeconds: String
                    if trackTimescale > 0 {
                        mediaTimeSeconds = String(format: "%.3fs", Double(mediaTime) / Double(trackTimescale))
                    } else {
                        mediaTimeSeconds = "\(mediaTime) ticks"
                    }

                    issues.append(ContainerDiagnostic(
                        category: .editList,
                        severity: .error,
                        title: "Edit List References Missing Keyframe",
                        detail: "Track \(trackIndex) edit list entry \(entryIdx) has media_time=\(mediaTime) (\(mediaTimeSeconds)) but no keyframe exists at or before this timestamp. Decoders that honor the edit list (AVFoundation, AME, Compressor) will fail or produce green/corrupt frames. ffmpeg ignores this and decodes correctly.",
                        remediation: .remux
                    ))
                } else {
                    // Keyframe exists, but check if it's AT the media_time or before
                    let exactMatch = keyframeTimestamps.contains { $0 == mediaTime }
                    if !exactMatch && mediaTime > 0 {
                        let nearest = keyframeTimestamps.filter { $0 < mediaTime }.max() ?? 0
                        let gapTicks = mediaTime - nearest
                        let gapMs: String
                        if trackTimescale > 0 {
                            gapMs = String(format: "%.1fms", Double(gapTicks) / Double(trackTimescale) * 1000)
                        } else {
                            gapMs = "\(gapTicks) ticks"
                        }

                        issues.append(ContainerDiagnostic(
                            category: .editList,
                            severity: .warning,
                            title: "Edit List Start Not on Keyframe",
                            detail: "Track \(trackIndex) edit list entry \(entryIdx) starts at media_time=\(mediaTime) but nearest preceding keyframe is \(gapMs) earlier. Decoder must pre-roll from keyframe, which may cause initial frame artifacts.",
                            remediation: .remux
                        ))
                    }
                }
            }

            // Check: does the edit list reference a time beyond the track duration?
            let totalDuration = sampleTimes.reduce(UInt64(0)) { $0 + UInt64($1.count) * UInt64($1.delta) }
            if mediaTime > totalDuration && totalDuration > 0 {
                issues.append(ContainerDiagnostic(
                    category: .editList,
                    severity: .error,
                    title: "Edit List Beyond Track Duration",
                    detail: "Track \(trackIndex) edit list entry \(entryIdx) references media_time=\(mediaTime) but track duration is only \(totalDuration) ticks.",
                    remediation: .remux
                ))
            }
        }

        return issues
    }

    /// Convert 1-based sample numbers from stss to decode timestamps using stts
    private func computeKeyframeTimestamps(
        keyframes: [UInt32],
        sampleTimes: [(count: UInt32, delta: UInt32)]
    ) -> [UInt64] {
        // Build a cumulative timestamp lookup:
        // sampleTimes gives us runs of (count, delta), so sample N's DTS = sum of deltas for samples 0..<N
        // keyframes are 1-based sample numbers

        // For efficiency, iterate through stts entries alongside keyframe list
        var timestamps: [UInt64] = []
        timestamps.reserveCapacity(keyframes.count)

        guard !keyframes.isEmpty, !sampleTimes.isEmpty else { return [] }

        let sortedKeyframes = keyframes.sorted()
        var kfIdx = 0
        var currentSample: UInt32 = 1  // 1-based
        var currentDTS: UInt64 = 0

        for entry in sampleTimes {
            for _ in 0..<entry.count {
                if kfIdx < sortedKeyframes.count && currentSample == sortedKeyframes[kfIdx] {
                    timestamps.append(currentDTS)
                    kfIdx += 1
                    if kfIdx >= sortedKeyframes.count { return timestamps }
                }
                currentDTS += UInt64(entry.delta)
                currentSample += 1
            }
        }

        return timestamps
    }
}

// MARK: - Data Helpers

extension Data {
    func readUInt32BE(at offset: UInt64) -> UInt32 {
        let i = Int(offset)
        guard i + 4 <= count else { return 0 }
        return UInt32(self[i]) << 24 | UInt32(self[i+1]) << 16 | UInt32(self[i+2]) << 8 | UInt32(self[i+3])
    }

    func readUInt64BE(at offset: UInt64) -> UInt64 {
        let i = Int(offset)
        guard i + 8 <= count else { return 0 }
        return UInt64(self[i]) << 56 | UInt64(self[i+1]) << 48 | UInt64(self[i+2]) << 40 | UInt64(self[i+3]) << 32
             | UInt64(self[i+4]) << 24 | UInt64(self[i+5]) << 16 | UInt64(self[i+6]) << 8  | UInt64(self[i+7])
    }

    func readUInt16BE(at offset: UInt64) -> UInt16 {
        let i = Int(offset)
        guard i + 2 <= count else { return 0 }
        return UInt16(self[i]) << 8 | UInt16(self[i+1])
    }
}
