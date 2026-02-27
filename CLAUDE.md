# VideoAnalyzer

Native macOS app that analyzes media files for errors, corruption, and integrity issues.

## Tech Stack
- **Platform:** macOS 15+ (Sequoia)
- **UI:** SwiftUI
- **Language:** Swift 6 with strict concurrency
- **Primary engine:** AVFoundation (AVAssetReader frame-by-frame decode)
- **Secondary engine:** ffmpeg (optional, user-installed via Homebrew)
- **Architecture:** MVVM with async/await

## Key Architecture Decisions
- **AVFoundation first:** Covers ~75% of media files (MP4, MOV, M4V, HEVC, ProRes, MPEG-TS). Hardware-accelerated decode.
- **ffmpeg optional:** User points to their ffmpeg binary or we detect Homebrew install. Covers MKV, WebM, AVI, VP9, etc. Not bundled (LGPL licensing).
- **Non-App Store:** Direct distribution avoids sandbox/signing constraints for external tool integration.
- **Frame-by-frame validation:** AVAssetReader reads every sample buffer, checking for decode failures, timestamp gaps, and truncation.

## Project Structure
```
VideoAnalyzer/                     ← Repo root
├── 01_Project/                    ← All Xcode stuff
│   ├── VideoAnalyzer/             ← Source code
│   │   ├── App/                   # App entry point, window management
│   │   ├── Models/                # Data models (AnalysisResult, MediaFile, etc.)
│   │   ├── Views/                 # SwiftUI views
│   │   ├── ViewModels/            # ObservableObject view models
│   │   ├── Services/              # Analysis engines
│   │   └── Resources/             # Assets, localizations
│   ├── VideoAnalyzer.xcodeproj/
│   └── project.yml                # XcodeGen config
├── 02_Design/Exports/             ← Design files & exports
├── 03_Screenshots/                ← App Store / promotional
├── 04_Exports/                    ← Builds, DMGs (gitignored)
├── docs/                          ← Directions documentation
└── CLAUDE.md
```

## Directions
Full documentation system in `docs/`. Start with `docs/00_base.md`.
