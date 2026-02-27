# VideoAnalyzer

Native macOS app that detects errors, corruption, and integrity issues in media files.

Drop files in, get a detailed diagnostic report — decode failures, timestamp gaps, truncated streams, container structure problems, and more.

## Features

- **Frame-by-frame validation** — reads every sample buffer via AVAssetReader, catching issues that simple playback would miss
- **Container inspection** — parses MP4/MOV (ISO BMFF) and MXF container structure, validating box hierarchy, sample tables, NAL unit boundaries, and index consistency
- **Dual-engine analysis** — AVFoundation (hardware-accelerated) as primary engine, with optional ffmpeg support for formats Apple doesn't handle (MKV, WebM, AVI, VP9)
- **Drag-and-drop workflow** — drop individual files or entire folders for batch analysis
- **Detailed diagnostics** — every issue reported with type, severity, timestamp, and frame number
- **Metadata extraction** — codec, resolution, duration, bitrate, frame rate, track layout, audio channels

## What It Detects

| Category | Examples |
|----------|----------|
| Decode errors | Corrupted frames, unreadable samples |
| Timestamp gaps | Missing frames, PTS discontinuities |
| Truncation | File cut short, fewer frames than expected |
| Container issues | Malformed atoms/boxes, broken sample tables, invalid index entries |
| Missing tracks | Video without audio or vice versa |
| Header corruption | Unreadable metadata, damaged format descriptions |

## Requirements

- macOS 15.0+ (Sequoia)
- Xcode 16+ (to build from source)
- ffmpeg (optional) — install via Homebrew for MKV/WebM/AVI support:
  ```
  brew install ffmpeg
  ```

## Supported Formats

**AVFoundation (built-in):** MP4, MOV, M4V, HEVC, ProRes, MPEG-TS, AAC, ALAC, WAV, AIFF

**ffmpeg (optional):** MKV, WebM, AVI, VP8/VP9, AV1, FLV, WMV, Opus, Vorbis, and anything else ffmpeg supports

## Building

```bash
cd 01_Project
open VideoAnalyzer.xcodeproj
```

Build and run with Xcode (`Cmd+R`), or from the command line:

```bash
xcodebuild -scheme VideoAnalyzer -destination 'platform=macOS' build
```

## Project Structure

```
01_Project/                    Xcode project and source code
├── VideoAnalyzer/
│   ├── App/                   App entry point, window management
│   ├── Models/                Data models (AnalysisResult, MediaFile, MediaIssue, etc.)
│   ├── Views/                 SwiftUI views (drop zone, file list, detail panel)
│   ├── ViewModels/            Observable view models
│   ├── Services/              Analysis engines
│   │   ├── AVFoundationAnalyzer.swift
│   │   ├── FFmpegAnalyzer.swift
│   │   ├── AnalysisCoordinator.swift
│   │   └── ContainerInspection/    ISO BMFF + MXF parsers
│   └── Resources/
├── VideoAnalyzer.xcodeproj/
└── project.yml                XcodeGen config
02_Design/                     Design assets
03_Screenshots/                App screenshots
04_Exports/                    Builds and DMGs (gitignored)
docs/                          Project documentation
```

## Tech Stack

- **Swift 6** with strict concurrency
- **SwiftUI** for the interface
- **AVFoundation** (AVAssetReader) for frame-by-frame decode validation
- **MVVM** architecture with async/await

## License

This project is not currently published under an open-source license.
