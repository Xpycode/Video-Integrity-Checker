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
VideoAnalyzer/
├── App/                    # App entry point, window management
├── Models/                 # Data models (AnalysisResult, MediaFile, etc.)
├── Views/                  # SwiftUI views
├── ViewModels/             # ObservableObject view models
├── Services/               # Analysis engines
│   ├── AVFoundationAnalyzer.swift
│   ├── FFmpegAnalyzer.swift
│   └── AnalysisCoordinator.swift
├── Utilities/              # Helpers, extensions
└── Resources/              # Assets, localizations
```

## Directions
Full documentation system in `docs/`. Start with `docs/00_base.md`.
