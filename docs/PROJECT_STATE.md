# Project State

> **Size limit: <100 lines.** This is a digest, not an archive. Details go in session logs.

## Identity
- **Project:** Video Integrity Checker
- **One-liner:** Native macOS app that analyzes media files for errors and corruption
- **Tags:** macOS, SwiftUI, AVFoundation, media, video, audio, validation
- **Started:** 2026-02-25

## Current Position
- **Funnel:** build
- **Phase:** polish
- **Focus:** UI polish, real-file testing, dual-engine cross-reference
- **Status:** renamed + polish in progress
- **Last session:** 2026-02-27

## Funnel Progress

| Funnel | Status | Gate |
|--------|--------|------|
| **Define** | done | Interview done, spec reviewed |
| **Plan** | done | Implementation plan created |
| **Build** | active | Implementation done, entering polish phase |

## Phase Progress
```
[###################.] 97% - Rename complete, button polish started
```

| Phase | Status | Tasks |
|-------|--------|-------|
| Discovery | done | Architecture decided |
| Planning | done | 6-wave implementation plan |
| Implementation | done | Waves 1-5 + ISOBMFF/MXF inspectors + deep validation + code review remediation (11/11 issues) |
| Polish | **active** | Real-file testing, dual-engine cross-reference, UI refinements |

## Readiness

| Dimension | Status | Notes |
|-----------|--------|-------|
| Features | partial | Core analysis + deep ISOBMFF/MXF inspection (sample tables, NAL boundaries, KLV integrity, timing tables, SPS/PPS validation, stco overflow, box size validation, player notes). Needs real corrupt/MXF test files. |
| UI/Polish | partial | NavigationSplitView, toolbar, drop zone done. Prominent button style in progress. |
| Testing | partial | 17 core tests (stsz, ctts, exit code, file discovery) |
| Docs | partial | Directions set up, CLAUDE.md current, README on GitHub |
| Distribution | — | Direct download (non-App Store), repo at github.com/Xpycode/Video-Integrity-Checker |

## Architecture Decisions
- AVFoundation as primary analysis engine (covers MP4, MOV, HEVC, ProRes, etc.)
- Optional ffmpeg support for expanded format coverage (MKV, WebM, AVI, VP9, MXF)
- Detect user-installed ffmpeg (Homebrew) rather than bundling (avoids LGPL issues)
- SwiftUI for UI, single-window app with drag-and-drop
- Non-App Store distribution (direct download) for flexibility
- Protocol-based container inspection: ISOBMFF (MP4/MOV), MXF OP1a, MPEG-TS stub — extensible
- Container inspection as pre-pass before frame decode (root cause appears first)
- Remediation tagging on diagnostics (remux vs re-encode vs informational)
- InspectionDepth (quick/standard/thorough) controls validation scope vs speed tradeoff
- Player-specific compatibility notes on diagnostics (VLC, QuickTime, AVFoundation, Avid, DaVinci Resolve)
- This app is analysis-only; repair/remux is a separate app project

## Blockers
- None — concurrency rework complete, test target exists

## Completed Decisions
- Renamed: VideoAnalyzer → Video Integrity Checker (2026-02-27)
- Bundle ID: com.lucesumbrarum.VideoIntegrityChecker (2026-02-27)
- Button style: prominent + labeled (2026-02-27)

---
*Updated by Claude. Source of truth for project position.*
