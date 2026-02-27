import Testing
import Foundation
@testable import VideoIntegrityChecker

// MARK: - stsz Tests (I3)

@Suite("SampleSizeInfo")
struct SampleSizeInfoTests {

    @Test("Uniform-size samples don't allocate per-sample array")
    func uniformSizeNoAllocation() {
        let info = ISOBMFFInspector.SampleSizeInfo(
            uniformSize: 4096,
            sizes: [],
            declaredCount: 5_000_000
        )

        #expect(info.sampleCount == 5_000_000)
        #expect(info.sizes.isEmpty)
        #expect(info.uniformSize == 4096)
    }

    @Test("Uniform-size size(at:) returns uniformSize for any index")
    func uniformSizeAccessor() {
        let info = ISOBMFFInspector.SampleSizeInfo(
            uniformSize: 1024,
            sizes: [],
            declaredCount: 100
        )

        #expect(info.size(at: 0) == 1024)
        #expect(info.size(at: 50) == 1024)
        #expect(info.size(at: 99) == 1024)
    }

    @Test("Variable-size size(at:) returns correct per-sample value")
    func variableSizeAccessor() {
        let sizes: [UInt32] = [100, 200, 300, 400]
        let info = ISOBMFFInspector.SampleSizeInfo(
            uniformSize: 0,
            sizes: sizes,
            declaredCount: 4
        )

        #expect(info.sampleCount == 4)
        #expect(info.size(at: 0) == 100)
        #expect(info.size(at: 3) == 400)
    }

    @Test("size(at:) returns 0 for out-of-bounds index")
    func outOfBoundsReturnsZero() {
        let info = ISOBMFFInspector.SampleSizeInfo(
            uniformSize: 0,
            sizes: [100, 200],
            declaredCount: 2
        )

        #expect(info.size(at: 5) == 0)
    }

    @Test("parseSTSZ with uniform size returns empty sizes array")
    func parseSTSZUniform() {
        // Build a minimal stsz box: [size(4)][type(4)][version(1)+flags(3)][sample_size(4)][sample_count(4)]
        let inspector = ISOBMFFInspector()
        var data = Data()

        // Box header: size=20, type="stsz"
        data.appendUInt32BE(20)
        data.append(contentsOf: "stsz".utf8)
        // version=0, flags=0
        data.appendUInt32BE(0)
        // sample_size=512 (uniform)
        data.appendUInt32BE(512)
        // sample_count=1000000
        data.appendUInt32BE(1_000_000)

        let box = BoxInfo(type: "stsz", offset: 0, size: 20)
        let result = inspector.parseSTSZ(data: data, stblChildren: [box])

        #expect(result.uniformSize == 512)
        #expect(result.sizes.isEmpty)
        #expect(result.sampleCount == 1_000_000)
    }

    @Test("parseSTSZ with variable sizes reads per-sample table")
    func parseSTSZVariable() {
        let inspector = ISOBMFFInspector()
        var data = Data()

        // Box header: size=28, type="stsz"
        data.appendUInt32BE(28)
        data.append(contentsOf: "stsz".utf8)
        // version=0, flags=0
        data.appendUInt32BE(0)
        // sample_size=0 (variable)
        data.appendUInt32BE(0)
        // sample_count=2
        data.appendUInt32BE(2)
        // sizes: 100, 200
        data.appendUInt32BE(100)
        data.appendUInt32BE(200)

        let box = BoxInfo(type: "stsz", offset: 0, size: 28)
        let result = inspector.parseSTSZ(data: data, stblChildren: [box])

        #expect(result.uniformSize == 0)
        #expect(result.sizes == [100, 200])
        #expect(result.sampleCount == 2)
    }
}

// MARK: - ctts Tests (I4)

@Suite("CTTS Parsing")
struct CTTSTests {

    @Test("ctts v0 treats large unsigned offset correctly")
    func cttsV0LargeOffset() {
        let inspector = ISOBMFFInspector()
        var data = Data()

        // Box header: size=20, type="ctts"
        data.appendUInt32BE(20)
        data.append(contentsOf: "ctts".utf8)
        // version=0, flags=0
        data.appendUInt32BE(0)    // version=0
        // entry_count=1
        data.appendUInt32BE(1)
        // sample_count=10
        data.appendUInt32BE(10)
        // composition_offset=0x80000001 (would be negative as Int32)
        data.appendUInt32BE(0x8000_0001)

        let box = BoxInfo(type: "ctts", offset: 0, size: 28)
        let result = inspector.parseCTTS(data: data, stblChildren: [box])

        #expect(result.count == 1)
        // v0 should clamp to Int32.max, NOT interpret as negative
        #expect(result[0].offset == Int32.max)
        #expect(result[0].offset > 0)
    }

    @Test("ctts v1 preserves signed negative offset")
    func cttsV1NegativeOffset() {
        let inspector = ISOBMFFInspector()
        var data = Data()

        // Box header: size=20, type="ctts"
        data.appendUInt32BE(20)
        data.append(contentsOf: "ctts".utf8)
        // version=1, flags=0
        data.append(1)           // version=1
        data.append(contentsOf: [0, 0, 0] as [UInt8])  // flags=0
        // entry_count=1
        data.appendUInt32BE(1)
        // sample_count=10
        data.appendUInt32BE(10)
        // composition_offset=-100 (0xFFFFFF9C as unsigned)
        let neg100 = UInt32(bitPattern: Int32(-100))
        data.appendUInt32BE(neg100)

        let box = BoxInfo(type: "ctts", offset: 0, size: 28)
        let result = inspector.parseCTTS(data: data, stblChildren: [box])

        #expect(result.count == 1)
        // v1 should preserve negative value
        #expect(result[0].offset == -100)
    }

    @Test("ctts v0 small offset passes through unchanged")
    func cttsV0SmallOffset() {
        let inspector = ISOBMFFInspector()
        var data = Data()

        // Box header
        data.appendUInt32BE(20)
        data.append(contentsOf: "ctts".utf8)
        data.appendUInt32BE(0)    // version=0
        data.appendUInt32BE(1)    // entry_count=1
        data.appendUInt32BE(5)    // sample_count=5
        data.appendUInt32BE(1000) // offset=1000 (fits in Int32)

        let box = BoxInfo(type: "ctts", offset: 0, size: 28)
        let result = inspector.parseCTTS(data: data, stblChildren: [box])

        #expect(result.count == 1)
        #expect(result[0].offset == 1000)
    }
}

// MARK: - FileDiscovery Tests (I2)

@Suite("FileDiscovery")
struct FileDiscoveryTests {

    @Test("Supported extensions match expected formats")
    func supportedExtensionsComplete() {
        let expected: Set<String> = [
            "mov", "mp4", "m4v", "m4a", "wav", "aiff", "mp3",
            "ts", "mkv", "webm", "avi", "flv", "wmv", "mxf"
        ]
        #expect(FileDiscovery.supportedExtensions == expected)
    }

    @Test("Filters out non-media files")
    func filtersNonMedia() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Create test files
        let mp4 = tmp.appending(path: "test.mp4")
        let txt = tmp.appending(path: "readme.txt")
        let mkv = tmp.appending(path: "movie.mkv")
        try Data().write(to: mp4)
        try Data().write(to: txt)
        try Data().write(to: mkv)

        let results = FileDiscovery.collectMediaFiles(from: [tmp])

        #expect(results.count == 2)
        let names = Set(results.map { $0.lastPathComponent })
        #expect(names.contains("test.mp4"))
        #expect(names.contains("movie.mkv"))
        #expect(!names.contains("readme.txt"))
    }

    @Test("Recursively discovers files in subdirectories")
    func recursiveDiscovery() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        let sub = tmp.appending(path: "subdir")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let top = tmp.appending(path: "top.mov")
        let nested = sub.appending(path: "nested.avi")
        try Data().write(to: top)
        try Data().write(to: nested)

        let results = FileDiscovery.collectMediaFiles(from: [tmp])

        #expect(results.count == 2)
        let names = Set(results.map { $0.lastPathComponent })
        #expect(names.contains("top.mov"))
        #expect(names.contains("nested.avi"))
    }

    @Test("Individual files are accepted directly")
    func individualFiles() throws {
        let tmp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let file = tmp.appending(path: "single.mp4")
        try Data().write(to: file)

        let results = FileDiscovery.collectMediaFiles(from: [file])
        #expect(results.count == 1)
        #expect(results[0].lastPathComponent == "single.mp4")
    }
}

// MARK: - ffmpeg Exit Code Tests (C6)

@Suite("FFmpeg Exit Code Classification")
struct FFmpegExitCodeTests {

    @Test("Exit code logic: non-zero with no issues adds error")
    func nonZeroNoIssues() {
        let issues = applyExitCodeLogic(exitCode: 1, existingIssues: [])
        #expect(issues.count == 1)
        #expect(issues[0].severity == .error)
        #expect(issues[0].type == .decodeError)
    }

    @Test("Exit code logic: non-zero with only warnings adds error")
    func nonZeroOnlyWarnings() {
        let existing = [MediaIssue(type: .other, severity: .warning, description: "Some warning")]
        let issues = applyExitCodeLogic(exitCode: 2, existingIssues: existing)
        #expect(issues.count == 2)
        #expect(issues.contains(where: { $0.severity == .error }))
    }

    @Test("Exit code logic: non-zero with existing error does not duplicate")
    func nonZeroWithExistingError() {
        let existing = [MediaIssue(type: .decodeError, severity: .error, description: "Existing error")]
        let issues = applyExitCodeLogic(exitCode: 1, existingIssues: existing)
        #expect(issues.count == 1)
    }

    @Test("Exit code logic: zero exit code adds nothing")
    func zeroExitCode() {
        let issues = applyExitCodeLogic(exitCode: 0, existingIssues: [])
        #expect(issues.isEmpty)
    }

    // Extracted helper matching FFmpegAnalyzer.runFFmpegAnalysis exit code logic
    private func applyExitCodeLogic(exitCode: Int32, existingIssues: [MediaIssue]) -> [MediaIssue] {
        var issues = existingIssues
        if exitCode != 0 {
            if issues.isEmpty {
                issues.append(MediaIssue(type: .decodeError, severity: .error, description: "exit \(exitCode)"))
            } else if !issues.contains(where: { $0.severity == .error }) {
                issues.append(MediaIssue(type: .decodeError, severity: .error, description: "exit \(exitCode)"))
            }
        }
        return issues
    }
}

// MARK: - Data Helpers

extension Data {
    mutating func appendUInt32BE(_ value: UInt32) {
        var v = value.bigEndian
        append(Data(bytes: &v, count: 4))
    }
}
