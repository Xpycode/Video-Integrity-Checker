# Project State

> **Size limit: <100 lines.** This is a digest, not an archive. Details go in session logs.

## Identity
- **Project:** VideoAnalyzer
- **One-liner:** Native macOS app that analyzes media files for errors and corruption
- **Tags:** macOS, SwiftUI, AVFoundation, media, video, audio, validation
- **Started:** 2026-02-25

## Current Position
- **Funnel:** build
- **Phase:** implementation
- **Focus:** Core implementation complete — needs real-file testing and polish
- **Status:** in progress
- **Last updated:** 2026-02-25

## Funnel Progress

| Funnel | Status | Gate |
|--------|--------|------|
| **Define** | done | Interview done, spec reviewed |
| **Plan** | done | Implementation plan created |
| **Build** | active | Waves 1-5 complete, verification next |

## Phase Progress
```
[################....] 80% - Core implementation done, testing/polish next
```

| Phase | Status | Tasks |
|-------|--------|-------|
| Discovery | done | Architecture decided |
| Planning | done | 6-wave implementation plan |
| Implementation | **active** | Waves 1-5 complete (13/13 tasks) |
| Polish | pending | Real-file testing, performance |

## Readiness

| Dimension | Status | Notes |
|-----------|--------|-------|
| Features | partial | Core analysis working, needs real-file testing |
| UI/Polish | partial | NavigationSplitView, toolbar, drop zone done |
| Testing | — | No unit tests yet |
| Docs | partial | Directions set up, CLAUDE.md current |
| Distribution | — | Direct download (non-App Store) |

## Architecture Decisions
- AVFoundation as primary analysis engine (covers MP4, MOV, HEVC, ProRes, etc.)
- Optional ffmpeg support for expanded format coverage (MKV, WebM, AVI, VP9)
- Detect user-installed ffmpeg (Homebrew) rather than bundling (avoids LGPL issues)
- SwiftUI for UI, single-window app with drag-and-drop
- Non-App Store distribution (direct download) for flexibility

## Blockers

---
*Updated by Claude. Source of truth for project position.*
