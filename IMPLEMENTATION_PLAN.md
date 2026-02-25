# Implementation Plan — VideoAnalyzer

> **Persists across sessions.** Regenerate when wrong rather than patching.

## Goal
Build a native macOS app that analyzes media files for errors and corruption using AVFoundation (primary) and optional ffmpeg (secondary), with a drag-and-drop SwiftUI interface.

## Acceptance Criteria
- [ ] User can drag-and-drop or open media files for analysis
- [ ] App performs frame-by-frame decode validation using AVFoundation
- [ ] App detects: decode failures, timestamp gaps, truncation, missing tracks
- [ ] App shows clear results: healthy/warnings/errors with details
- [ ] App displays file metadata (codec, resolution, duration, bitrate, tracks)
- [ ] App optionally uses ffmpeg for unsupported formats (MKV, WebM, AVI, VP9)
- [ ] App auto-detects ffmpeg installation or lets user point to binary
- [ ] Batch analysis: user can drop a folder and scan all media files
- [ ] Progress reporting during analysis (per-file and overall)
- [ ] Analysis runs async, UI stays responsive

---

## Tasks

### Wave 1: Foundation (parallel — no dependencies)

- [ ] **1.1**: Create Xcode project with SwiftUI lifecycle → `VideoAnalyzer.xcodeproj`
  - macOS 15+, Swift 6, strict concurrency
  - Single window, app icon placeholder
  - Success: App launches with empty window
  - Backpressure: `xcodebuild build`

- [ ] **1.2**: Define data models → `Models/`
  - `MediaFile` — URL, file size, modification date, format info
  - `AnalysisResult` — overall status (healthy/warning/error), issues list, metadata
  - `MediaIssue` — type (decodeError, timestampGap, truncation, etc.), timestamp, severity, description
  - `MediaMetadata` — codec, resolution, duration, bitrate, frame rate, tracks, audio channels
  - `AnalysisProgress` — current frame, total frames, percentage, current phase
  - Success: Models compile, cover all analysis output needs
  - Backpressure: `swift build`

### Wave 2: Analysis Engines (depends on Wave 1)

- [ ] **2.1**: AVFoundation analyzer → `Services/AVFoundationAnalyzer.swift`
  - Load AVAsset, check `isReadable`, `isPlayable`
  - Load tracks, extract metadata (codec via `formatDescriptions`, resolution, duration, frame rate)
  - Read video track frame-by-frame via AVAssetReader + AVAssetReaderTrackOutput
  - Read audio track sample-by-sample
  - Detect errors:
    - `.failed` status → decode error (capture AVError code)
    - Timestamp gaps → compare consecutive PTS against expected frame duration
    - Truncation → compare decoded frame count vs expected (duration × frame rate)
    - Missing tracks → file has video but no audio or vice versa (informational)
  - Report progress via AsyncStream or callback (frame count / estimated total)
  - Handle known hang issue: timeout via Task.sleep + cancellation
  - Use `-nostdin` equivalent: configure output settings for optimal decode performance
  - Success: Can analyze an MP4/MOV and report errors or clean bill of health
  - Backpressure: Unit test with known-good and known-bad test files

- [ ] **2.2**: ffmpeg analyzer → `Services/FFmpegAnalyzer.swift`
  - Detect ffmpeg: check `/opt/homebrew/bin/ffmpeg`, `/usr/local/bin/ffmpeg`, user preference
  - Run via Process: `ffmpeg -nostdin -v error -i <file> -f null -`
  - Capture stderr, parse error lines
  - Run ffprobe for metadata: `ffprobe -v quiet -print_format json -show_format -show_streams <file>`
  - Parse JSON output into MediaMetadata
  - Report progress: parse ffmpeg stderr for frame count/duration (limited — ffmpeg doesn't report progress to null output well)
  - Success: Can analyze MKV/WebM files and report errors
  - Backpressure: Unit test with ffmpeg available and unavailable

- [ ] **2.3**: Analysis coordinator → `Services/AnalysisCoordinator.swift`
  - Decide which engine to use based on file format
  - AVFoundation-supported UTTypes: .mov, .mp4, .m4v, .m4a, .wav, .aiff, .mp3, .ts
  - ffmpeg fallback: everything else (if available)
  - Unsupported: report "cannot analyze — ffmpeg not found" for non-AVFoundation formats
  - Batch mode: analyze multiple files with concurrency limit (e.g., 2-3 simultaneous)
  - Success: Coordinator routes files to correct engine
  - Backpressure: Unit test routing logic

### Wave 3: UI (depends on Wave 1 models)

- [ ] **3.1**: Main window with drop zone → `Views/ContentView.swift`, `Views/DropZoneView.swift`
  - Large drop zone when no files loaded ("Drop media files here to analyze")
  - Accept media file UTTypes + folders
  - Also support File > Open menu and toolbar button
  - Success: Can drop files onto window, URLs are captured
  - Backpressure: Build + manual test

- [ ] **3.2**: File list / results table → `Views/FileListView.swift`
  - SwiftUI Table with columns: filename, status (icon), format, duration, size
  - Status icons: checkmark (green), warning (yellow), error (red), spinner (analyzing), dash (queued)
  - Row selection shows detail in sidebar/inspector
  - Sort by any column
  - Success: Files appear in table with status
  - Backpressure: Build + preview

- [ ] **3.3**: Detail inspector → `Views/DetailView.swift`
  - Metadata section: codec, resolution, duration, bitrate, frame rate, audio info
  - Issues section: list of issues with timestamps, severity, description
  - Overall verdict: banner at top (Healthy / X warnings / X errors)
  - Success: Selected file shows full analysis results
  - Backpressure: Build + preview

### Wave 4: ViewModel + Wiring (depends on Wave 2 + 3)

- [ ] **4.1**: Main view model → `ViewModels/AnalyzerViewModel.swift`
  - @Observable class
  - Holds list of MediaFile + AnalysisResult pairs
  - Triggers analysis on file add
  - Manages batch progress
  - Publishes per-file and overall progress
  - Success: Drop files → analysis runs → results appear in table
  - Backpressure: Build + end-to-end manual test

- [ ] **4.2**: Settings / preferences → `Views/SettingsView.swift`
  - ffmpeg path: auto-detect or manual browse
  - Concurrency limit (number of simultaneous analyses)
  - Analysis depth: quick (metadata only) vs deep (full decode)
  - Success: Settings persist via @AppStorage or UserDefaults
  - Backpressure: Build + verify persistence

### Wave 5: Polish + Integration (depends on Wave 4)

- [ ] **5.1**: Toolbar + menus → `App/VideoAnalyzerApp.swift`
  - Toolbar: Open, Analyze All, Clear, Settings
  - Menu bar: File > Open, Edit > Select All, View options
  - Keyboard shortcuts: Cmd+O (open), Cmd+Delete (remove selected)
  - Success: Standard macOS app feel
  - Backpressure: Build + manual test

- [ ] **5.2**: Progress and cancellation
  - Per-file progress bar in table row
  - Overall progress in toolbar or bottom bar
  - Cancel button per file and cancel all
  - Success: Can cancel running analysis
  - Backpressure: Manual test with large file

- [ ] **5.3**: Error states and edge cases
  - File not found / permission denied
  - Zero-byte files
  - Non-media files dropped
  - AVAssetReader hang timeout (10s per frame? configurable)
  - ffmpeg not found → graceful message with install instructions
  - Success: No crashes on bad input
  - Backpressure: Test with edge case files

### Wave 6: Verification

- [ ] **6.1**: Test with real media files (various formats, known-good, known-corrupt)
- [ ] **6.2**: Performance check — analyze a 1GB+ file, verify memory stays reasonable
- [ ] **6.3**: Adversarial review (code review, security check)

---

## Key Technical Notes

### AVAssetReader Error Detection Pattern
```swift
let reader = try AVAssetReader(asset: asset)
let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_422YpCbCr8  // optimal for macOS
])
reader.add(output)
reader.startReading()

var frameCount = 0
var lastPTS: CMTime = .zero
while let sampleBuffer = output.copyNextSampleBuffer() {
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    // Check for timestamp gaps
    if frameCount > 0 {
        let gap = CMTimeSubtract(pts, lastPTS)
        if CMTimeGetSeconds(gap) > expectedFrameDuration * 1.5 {
            // Timestamp gap detected
        }
    }
    lastPTS = pts
    frameCount += 1
}

// Check final status
switch reader.status {
case .completed: // All frames decoded successfully
case .failed: // reader.error has AVError details
case .cancelled: // Was cancelled
}
```

### ffmpeg Process Pattern
```swift
let process = Process()
process.executableURL = URL(fileURLWithPath: ffmpegPath)
process.arguments = ["-nostdin", "-v", "error", "-i", filePath, "-f", "null", "-"]
let errorPipe = Pipe()
process.standardError = errorPipe
try process.run()
process.waitUntilExit()
let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
// Empty errorData = file is clean
```

### ffmpeg Detection
Check in order:
1. User preference (stored path)
2. `/opt/homebrew/bin/ffmpeg` (Apple Silicon Homebrew)
3. `/usr/local/bin/ffmpeg` (Intel Homebrew)
4. `which ffmpeg` via Process (fallback)

---

## Operational Learnings
- AVFoundation's macOS decoder silently auto-corrects some H.264 bitstream errors — ffmpeg catches more
- `copyNextSampleBuffer()` can hang on malformed files — always use timeout
- ffmpeg requires `-nostdin` flag when run via Process to prevent hanging
- kCVPixelFormatType_422YpCbCr8 is optimal pixel format for macOS video decode performance

## Blocked Tasks


---

## Execution Log

| Wave | Started | Completed | Commits |
|------|---------|-----------|---------|
| 1 | | | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |
| 6 | | | |

---
*Delete this file when all tasks complete. Archive to sessions/ if needed for reference.*
