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
- **Focus:** MXF OP1a inspector, dual-engine cross-reference, Vision artifact detection
- **Status:** in progress
- **Last session:** 2026-02-25 (session 2)

## Funnel Progress

| Funnel | Status | Gate |
|--------|--------|------|
| **Define** | done | Interview done, spec reviewed |
| **Plan** | done | Implementation plan created |
| **Build** | active | Waves 1-5 complete + container inspection system |

## Phase Progress
```
[#################...] 85% - Core + container inspection done, MXF/Vision next
```

| Phase | Status | Tasks |
|-------|--------|-------|
| Discovery | done | Architecture decided |
| Planning | done | 6-wave implementation plan |
| Implementation | **active** | Waves 1-5 complete (13/13) + container inspection (4 new files) |
| Polish | pending | MXF inspector, dual-engine, Vision artifacts, unit tests |

## Readiness

| Dimension | Status | Notes |
|-----------|--------|-------|
| Features | partial | Core analysis + ISOBMFF container inspection working. MXF stub ready. |
| UI/Polish | partial | NavigationSplitView, toolbar, drop zone done |
| Testing | — | No unit tests yet |
| Docs | partial | Directions set up, CLAUDE.md current |
| Distribution | — | Direct download (non-App Store) |

## Architecture Decisions
- AVFoundation as primary analysis engine (covers MP4, MOV, HEVC, ProRes, etc.)
- Optional ffmpeg support for expanded format coverage (MKV, WebM, AVI, VP9, MXF)
- Detect user-installed ffmpeg (Homebrew) rather than bundling (avoids LGPL issues)
- SwiftUI for UI, single-window app with drag-and-drop
- Non-App Store distribution (direct download) for flexibility
- Protocol-based container inspection: ISOBMFF (MP4/MOV), MXF (OP1a), MPEG-TS — extensible
- Container inspection as pre-pass before frame decode (root cause appears first)
- Remediation tagging on diagnostics (remux vs re-encode vs informational)
- This app is analysis-only; repair/remux is a separate app project

## Blockers

---
*Updated by Claude. Source of truth for project position.*
