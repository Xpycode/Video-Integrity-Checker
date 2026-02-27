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
- **Focus:** Test with real corrupt/MXF files, Tier 2 gaps (fMP4, MXF metadata depth), dual-engine cross-reference, unit tests
- **Status:** in progress
- **Last session:** 2026-02-27

## Funnel Progress

| Funnel | Status | Gate |
|--------|--------|------|
| **Define** | done | Interview done, spec reviewed |
| **Plan** | done | Implementation plan created |
| **Build** | active | Waves 1-5 + ISOBMFF/MXF inspectors + enhanced validation (sample tables, NAL boundaries, MXF integrity) |

## Phase Progress
```
[##################..] 92% - Core + ISOBMFF + MXF inspectors + Tier 1 validation done, dual-engine/fMP4/tests next
```

| Phase | Status | Tasks |
|-------|--------|-------|
| Discovery | done | Architecture decided |
| Planning | done | 6-wave implementation plan |
| Implementation | **active** | Waves 1-5 (13/13) + ISOBMFF + MXF inspectors + deep validation (sample tables, NAL, KLV, timing, SPS/PPS, box sizes, stco overflow) |
| Polish | pending | Dual-engine cross-reference, Vision artifacts, unit tests |

## Readiness

| Dimension | Status | Notes |
|-----------|--------|-------|
| Features | partial | Core analysis + deep ISOBMFF/MXF inspection (sample tables, NAL boundaries, KLV integrity, timing tables, SPS/PPS validation, stco overflow, box size validation, player notes). Needs real corrupt/MXF test files. |
| UI/Polish | partial | NavigationSplitView, toolbar, drop zone done |
| Testing | — | No unit tests yet |
| Docs | partial | Directions set up, CLAUDE.md current, README on GitHub |
| Distribution | — | Direct download (non-App Store), repo at github.com/Xpycode/Video-Analyzer |

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

---
*Updated by Claude. Source of truth for project position.*
