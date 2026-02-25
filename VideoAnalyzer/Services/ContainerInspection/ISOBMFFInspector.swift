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

    func inspect(url: URL) async throws -> ContainerReport {
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

                            // Validate stss presence for video tracks
                            if isVideoTrack(data: data, trakChildren: trakChildren) && keyframes.isEmpty {
                                let stssExists = stblChildren.contains { $0.type == "stss" }
                                if !stssExists {
                                    // No stss = every frame is a sync sample (all-intra). That's fine.
                                } else {
                                    issues.append(ContainerDiagnostic(
                                        category: .syncSampleTable,
                                        severity: .warning,
                                        title: "Empty Sync Sample Table",
                                        detail: "Track \(trackIndex) has an stss atom with no keyframes. Seeking will be unreliable.",
                                        remediation: .remux
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

        while pos + 8 <= end {
            let size32 = data.readUInt32BE(at: pos)
            let typeBytes = data[Int(pos + 4)..<Int(pos + 8)]
            let type = String(data: typeBytes, encoding: .ascii) ?? "????"

            var boxSize: UInt64
            var headerSize: UInt64 = 8

            if size32 == 1 {
                // 64-bit extended size
                guard pos + 16 <= end else { break }
                boxSize = data.readUInt64BE(at: pos + 8)
                headerSize = 16
            } else if size32 == 0 {
                // Box extends to end of file
                boxSize = end - pos
            } else {
                boxSize = UInt64(size32)
            }

            guard boxSize >= headerSize else { break }
            guard pos + boxSize <= end else {
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

    private func isContainerBox(_ type: String) -> Bool {
        let containers: Set<String> = [
            "moov", "trak", "mdia", "minf", "stbl", "udta", "meta",
            "edts", "dinf", "sinf", "mvex", "moof", "traf", "schi"
        ]
        return containers.contains(type)
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
        guard bodyStart + 8 <= box.offset + box.size else { return [] }

        let version = data[Int(bodyStart)]
        let entryCount = data.readUInt32BE(at: bodyStart + 4)
        var entries: [EditListEntry] = []
        var pos = bodyStart + 8

        for _ in 0..<entryCount {
            if version == 0 {
                guard pos + 12 <= box.offset + box.size else { break }
                let duration = Int64(data.readUInt32BE(at: pos))
                let mediaTime = Int64(Int32(bitPattern: data.readUInt32BE(at: pos + 4)))
                let rateInt = Int16(bitPattern: data.readUInt16BE(at: pos + 8))
                let rateFrac = Int16(bitPattern: data.readUInt16BE(at: pos + 10))
                entries.append(EditListEntry(segmentDuration: duration, mediaTime: mediaTime, mediaRateInteger: rateInt, mediaRateFraction: rateFrac))
                pos += 12
            } else {
                guard pos + 20 <= box.offset + box.size else { break }
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
        guard bodyStart + 8 <= stss.offset + stss.size else { return [] }

        // version(1) + flags(3) + entry_count(4)
        let entryCount = data.readUInt32BE(at: bodyStart + 4)
        var samples: [UInt32] = []
        samples.reserveCapacity(Int(entryCount))
        var pos = bodyStart + 8

        for _ in 0..<entryCount {
            guard pos + 4 <= stss.offset + stss.size else { break }
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
        guard bodyStart + 8 <= stts.offset + stts.size else { return [] }

        let entryCount = data.readUInt32BE(at: bodyStart + 4)
        var entries: [(count: UInt32, delta: UInt32)] = []
        var pos = bodyStart + 8

        for _ in 0..<entryCount {
            guard pos + 8 <= stts.offset + stts.size else { break }
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
        guard bodyStart + 8 <= ctts.offset + ctts.size else { return [] }

        let version = data[Int(bodyStart)]
        let entryCount = data.readUInt32BE(at: bodyStart + 4)
        var entries: [(count: UInt32, offset: Int32)] = []
        var pos = bodyStart + 8

        for _ in 0..<entryCount {
            guard pos + 8 <= ctts.offset + ctts.size else { break }
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

    // MARK: - mdhd (Media Header) Timescale

    private func parseMediaTimescale(data: Data, mdiaChildren: [BoxInfo]) -> UInt32 {
        guard let mdhd = mdiaChildren.first(where: { $0.type == "mdhd" }) else { return 0 }
        let bodyStart = mdhd.offset + 8
        let version = data[Int(bodyStart)]

        if version == 0 {
            // version 0: skip version(1)+flags(3)+creation(4)+modification(4) = 12, then timescale(4)
            guard bodyStart + 16 <= mdhd.offset + mdhd.size else { return 0 }
            return data.readUInt32BE(at: bodyStart + 12)
        } else {
            // version 1: skip version(1)+flags(3)+creation(8)+modification(8) = 20, then timescale(4)
            guard bodyStart + 24 <= mdhd.offset + mdhd.size else { return 0 }
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
        guard bodyStart + 12 <= hdlr.offset + hdlr.size else { return false }
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
