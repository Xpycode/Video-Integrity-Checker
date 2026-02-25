# Project State

> **Size limit: <100 lines.** This is a digest, not an archive. Details go in session logs.

## Identity
- **Project:** VideoAnalyzer
- **One-liner:** Native macOS app that analyzes media files for errors and corruption
- **Tags:** macOS, SwiftUI, AVFoundation, media, video, audio, validation
- **Started:** 2026-02-25

## Current Position
- **Funnel:** define
- **Phase:** discovery
- **Focus:** Architecture decisions — AVFoundation primary, optional ffmpeg
- **Status:** ready
- **Last updated:** 2026-02-25

## Funnel Progress

| Funnel | Status | Gate |
|--------|--------|------|
| **Define** | active | Interview done, spec reviewed |
| **Plan** | pending | Tasks <30min, backpressure defined |
| **Build** | pending | Tests pass, review done |

## Phase Progress
```
[##..................] 10% - Discovery complete, planning next
```

| Phase | Status | Tasks |
|-------|--------|-------|
| Discovery | **active** | Architecture decided |
| Planning | pending | Implementation plan |
| Implementation | pending | — |
| Polish | pending | — |

## Readiness

| Dimension | Status | Notes |
|-----------|--------|-------|
| Features | — | Not started |
| UI/Polish | — | Not started |
| Testing | — | Not started |
| Docs | — | Directions set up |
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
