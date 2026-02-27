# Video File Corruption Types: MP4/MOV & MXF — Comprehensive Reference

## Table of Contents
1. [MP4/MOV Container Structure Overview](#mp4mov-container-structure)
2. [MP4/MOV Corruption Taxonomy](#mp4mov-corruption-taxonomy)
3. [MXF Container Structure Overview](#mxf-container-structure)
4. [MXF Corruption Taxonomy](#mxf-corruption-taxonomy)
5. [Bitstream-Level Corruption (Shared)](#bitstream-level-corruption)
6. [Storage & Transfer Corruption (Shared)](#storage--transfer-corruption)
7. [Detection Strategies](#detection-strategies)
8. [Repair Strategies](#repair-strategies)
9. [Useful Tools & Libraries for macOS](#useful-tools--libraries)

---

## 1. MP4/MOV Container Structure

Both MP4 (ISOBMFF — ISO 14496-12/14) and MOV (QTFF — QuickTime File Format) use a hierarchical **box/atom** architecture. Key top-level boxes:

```
[ftyp]          File type declaration (brand, compatibility)
[moov]          Movie metadata — the "table of contents"
  ├── [mvhd]    Movie header (duration, timescale, creation date)
  ├── [trak]    Track container (one per stream)
  │   ├── [tkhd]   Track header (dimensions, flags)
  │   ├── [edts]   Edit list (timing offsets)
  │   └── [mdia]   Media container
  │       ├── [mdhd]   Media header
  │       ├── [hdlr]   Handler reference (vide/soun)
  │       └── [minf]   Media information
  │           ├── [vmhd/smhd]  Video/Sound media header
  │           ├── [dinf]       Data information
  │           └── [stbl]       Sample Table — THE CRITICAL SECTION
  │               ├── [stsd]   Sample descriptions (codec config, SPS/PPS)
  │               ├── [stts]   Sample-to-time (decoding timestamps)
  │               ├── [ctts]   Composition time offsets (PTS vs DTS)
  │               ├── [stss]   Sync sample table (keyframe index)
  │               ├── [stsc]   Sample-to-chunk mapping
  │               ├── [stsz]   Sample sizes
  │               └── [stco/co64]  Chunk offsets (32-bit / 64-bit)
  └── [udta]    User data / metadata
[mdat]          Media data (raw compressed A/V samples)
[free/skip]     Padding atoms
[uuid]          User-defined extension boxes
```

**Fragmented MP4** (fMP4) adds:
```
[moov] → [mvex]     Movie extends (signals fragmentation)
[moof]               Movie fragment header
  ├── [mfhd]         Fragment header
  └── [traf]         Track fragment
      ├── [tfhd]     Track fragment header
      ├── [tfdt]     Track fragment decode time
      └── [trun]     Track fragment run (sample table for fragment)
[mdat]               Fragment media data
[sidx]               Segment index (byte ranges of fragments)
```

**MOV vs MP4 differences relevant to corruption:**
- MOV may lack `ftyp` (pre-ISOBMFF legacy files)
- MOV supports `cmov` (compressed movie atom), `rmra` (reference movies)
- MOV allows proprietary Apple atoms (`prfl`, custom `udta` fields)
- MOV uses `qt  ` brand; MP4 uses `isom`, `mp41`, `mp42`, etc.

---

## 2. MP4/MOV Corruption Taxonomy

### Category A: Box/Atom Structural Corruption

| # | Corruption Type | Description | Symptoms | Severity |
|---|----------------|-------------|----------|----------|
| A1 | **Missing moov atom** | Most common. Recording aborted (power loss, crash) before moov was written. moov is typically written last. | "moov atom not found", file won't open in any player | Critical |
| A2 | **Truncated file** | Incomplete write — USB disconnect, FAT32 4GB limit, disk full, network transfer failure | File shorter than expected, playback cuts off or fails entirely | Critical |
| A3 | **Missing/corrupt ftyp** | First box damaged or absent. Legacy MOV files may legitimately lack ftyp | File not recognized as MP4/MOV, some players refuse to open | High |
| A4 | **Invalid box sizes** | Size field of one or more boxes contains wrong value (0, negative, exceeds file size) | Parser crashes, cascading parse failures for all subsequent boxes | Critical |
| A5 | **moov at end + truncation** | moov placed after mdat (no fast-start), file truncated — moov partially or fully lost | Same as A1; mdat present but no index to decode it | Critical |
| A6 | **Duplicate/injected moov** | Software (e.g., FCP7) inserts extra moov atom inside mdat, destroying essence data at that offset | Artifacts at specific timecodes, frame corruption | High |
| A7 | **Xtra atom injection** | Windows `wmpnetwk.exe` injects malformed `Xtra` atom into header, corrupting playback metadata | Black screen, no audio, progress bar moves but nothing renders | Medium |
| A8 | **Orphaned mdat** | mdat exists without any moov — data recovered from disk but metadata completely missing | Raw data blob, needs full reconstruction | Critical |

### Category B: Sample Table (stbl) Corruption

| # | Corruption Type | Description | Symptoms | Severity |
|---|----------------|-------------|----------|----------|
| B1 | **stco/co64 offset mismatch** | Chunk offsets don't correspond to actual sample positions in mdat. Common after file move/resize without offset update | Garbled playback, wrong frames displayed, decoder errors | Critical |
| B2 | **Contradictory STSC and STCO** | Sample-to-chunk table references chunks that don't exist in chunk offset table | ffmpeg: "contradictory STSC and STCO", file won't remux | Critical |
| B3 | **stco overflow (>4GB files)** | 32-bit stco used for files exceeding 4GB — offsets wrap around | Playback fails after ~4GB mark, second half of video inaccessible | High |
| B4 | **stsz corruption** | Sample size entries don't match actual compressed frame sizes in mdat | Decoder reads wrong byte ranges, visual artifacts or crashes | High |
| B5 | **stss (sync sample) corruption** | Keyframe index incorrect or missing | Seeking broken, video starts from wrong point, can't find IDR frames | Medium |
| B6 | **stts/ctts corruption** | Decode/composition timing tables damaged | A/V desync, wrong playback speed, frames displayed at wrong times | Medium |
| B7 | **stsd corruption** | Sample description (codec config) damaged — may include corrupted SPS/PPS for H.264/H.265 | Decoder can't initialize, "codec not supported" errors | Critical |

### Category C: Fragmented MP4 Corruption

| # | Corruption Type | Description | Symptoms | Severity |
|---|----------------|-------------|----------|----------|
| C1 | **Missing/corrupt moof** | Fragment metadata lost — mdat present but no index for that segment | Gap in playback, segment skipped or unplayable | High |
| C2 | **moof/mdat size mismatch** | moof declares different sample count or sizes than what mdat contains | Artifacts in segment, partial frame decoding | High |
| C3 | **Missing sidx** | Segment index absent — player can't locate fragments by byte range | Progressive download broken, seeking fails in DASH/HLS | Medium |
| C4 | **tfdt discontinuity** | Track fragment decode time jumps or overlaps between segments | Timeline gaps, audio pops, frame drops at segment boundaries | Medium |
| C5 | **Missing mvex** | moov doesn't signal fragmentation — player treats as non-fragmented and fails | Only first segment plays, rest of file ignored | High |

### Category D: MOV-Specific Corruption

| # | Corruption Type | Description | Symptoms | Severity |
|---|----------------|-------------|----------|----------|
| D1 | **Legacy MOV without ftyp** | Pre-2005 QuickTime files — valid but many modern parsers reject them | "Unknown format", works in QuickTime but fails elsewhere | Low |
| D2 | **cmov decompression failure** | Compressed movie atom can't be decompressed (zlib damage) | moov data inaccessible despite being present | Critical |
| D3 | **Reference movie broken** | `rmra` atom points to external files that no longer exist | Player can't resolve references, empty playback | Medium |
| D4 | **ProRes container corruption** | Transcoding inserts wrong frames, frame repetition at regular intervals | Flickering, ghosting, frame insertion artifacts every N frames | Medium |

### Category E: Audio/Video Synchronization Corruption

| # | Corruption Type | Description | Symptoms | Severity |
|---|----------------|-------------|----------|----------|
| E1 | **Non-monotonous DTS** | Decode timestamps out of order or duplicated | Progressive A/V desync, audio drifts ahead/behind | Medium |
| E2 | **Edit list (elst) corruption** | Timing offset entries incorrect — initial delay or loop specifications wrong | Audio starts at wrong point, repeated segments | Medium |
| E3 | **VFR metadata inconsistency** | Variable frame rate metadata doesn't match actual frame timing | Stuttering, judder, desync gets worse over duration | Medium |
| E4 | **Audio stream byte corruption** | Invalid bytes in audio essence cause decoder to skip data | Progressive desync (each skip shifts audio further) | Medium |

---

## 3. MXF Container Structure

MXF (Material Exchange Format, SMPTE ST 377) uses **KLV (Key-Length-Value) triplet** encoding throughout. All data is KLV-wrapped.

```
[Header Partition]
  ├── Header Partition Pack    (identifies partition type + status)
  ├── KLV Fill                 (padding for alignment)
  ├── Primer Pack              (local tag → UL mapping dictionary)
  ├── Header Metadata          (Preface → ContentStorage → Packages → Tracks → Descriptors)
  │   ├── MXFPreface
  │   ├── MXFIdentification
  │   ├── MXFContentStorage
  │   ├── MXFMaterialPackage (tracks, sequences, source clips)
  │   ├── MXFSourcePackage (tracks, sequences, source clips)
  │   ├── MXFMultipleDescriptor / MXFGenericPictureEssenceDescriptor / MXFAES3PCMDescriptor
  │   └── MXFEssenceContainerData
  └── [Optional: Index Table Segment]

[Body Partition(s)]  — one or more
  ├── Body Partition Pack
  ├── [Optional: repeated Header Metadata]
  ├── [Optional: Index Table Segment]
  └── Essence Container
      ├── SystemMetadata (per-frame timecode, flags)
      ├── Essence Element — Video (KLV-wrapped compressed frame)
      ├── Essence Element — Audio Ch1 (KLV-wrapped audio frame)
      ├── Essence Element — Audio Ch2
      └── ... (repeated per frame)

[Footer Partition]
  ├── Footer Partition Pack
  ├── [Optional: Header Metadata — "closed & complete" copy]
  ├── [Optional: Index Table Segment]
  └── Random Index Pack (RIP) — byte offsets to all partitions
```

**Operational Patterns:**
- **OP-Atom**: Single essence track per file (Avid workflow, P2 cards — separate video.mxf + audio1.mxf + audio2.mxf)
- **OP1a**: Single item, interleaved tracks in one file (most common for recording/exchange)
- **OP1b**: Single item, multiple essence containers (Panasonic specific)

---

## 4. MXF Corruption Taxonomy

### Category F: Partition & Structural Corruption

| # | Corruption Type | Description | Symptoms | Severity |
|---|----------------|-------------|----------|----------|
| F1 | **Missing Header Partition** | No partition pack found at file start — may have run-in bytes or be entirely absent | "Does not appear to be MXF file", complete parse failure | Critical |
| F2 | **Missing/damaged Footer Partition** | Footer absent (common: recording aborted). Metadata may be incomplete/open | File may play but duration unknown, seeking unreliable, metadata "open & incomplete" | High |
| F3 | **Partition Pack corruption** | Invalid kind byte (byte 14) or status byte (byte 15) in partition pack UL | Parser can't identify partition type (Header/Body/Footer) | Critical |
| F4 | **KLV stream break** | No valid SMPTE key at expected byte position — gap or garbage data in KLV sequence | Parser must resync by scanning forward, lost data in gap | High |
| F5 | **Unable to resync KLV** | After KLV break, no valid SMPTE key found before EOF | Remaining file data unrecoverable by standard parsing | Critical |
| F6 | **Multiple consecutive KLV Fill** | More than one filler item in a row (violates spec) | Structural violation, some decoders may fail | Low |
| F7 | **Invalid KLV lengths** | Length field of KLV triplet contains impossible value (> remaining file size, negative BER) | Cascading parse failure from that point forward | Critical |
| F8 | **Missing Random Index Pack** | RIP at file end absent or corrupted | No fast random access to partitions, must scan sequentially | Low |

### Category G: Metadata Corruption

| # | Corruption Type | Description | Symptoms | Severity |
|---|----------------|-------------|----------|----------|
| G1 | **Primer Pack corruption** | Local tag → UL mapping table damaged or absent | Can't decode any local set metadata — all descriptors unreadable | Critical |
| G2 | **Header Metadata corruption** | Preface, packages, tracks, or descriptors have invalid values | Codec info wrong/missing, track layout unknown | Critical |
| G3 | **Essence Descriptor corruption** | Picture/Sound descriptor has wrong resolution, framerate, codec UL | Decoder initializes with wrong parameters, garbled output | High |
| G4 | **Index Table corruption** | Index table entries point to wrong byte offsets in essence container | Seeking broken, wrong frames returned, can't navigate timeline | High |
| G5 | **Timecode track damage** | SystemMetadata per-frame timecode entries corrupted | NLE shows wrong timecodes, EDL conforming fails | Medium |
| G6 | **ContentStorage/Package corruption** | Track mapping or package linkage broken | Audio tracks mapped wrong, OP1b multi-container confusion | High |
| G7 | **Dark metadata damage** | Proprietary/vendor-specific metadata (dark atoms) corrupted | Camera-specific features lost, usually non-fatal for playback | Low |

### Category H: Essence Container Corruption

| # | Corruption Type | Description | Symptoms | Severity |
|---|----------------|-------------|----------|----------|
| H1 | **Unfinalized recording** | Camera crashed during write — Body has essence but Header/Footer incomplete. May produce .RSV or .TMP file | File unplayable, needs complete container reconstruction | Critical |
| H2 | **Interleaved junk data** | After card recovery, non-essence data (filesystem metadata, index clusters) interleaved with A/V frames | Audio frames found in middle of video data (esp. at 0x80000 boundaries on P2) | High |
| H3 | **Essence Element UL mismatch** | Essence element KLV key doesn't match what Header declares | Decoder receives wrong stream type, A/V confusion | High |
| H4 | **Partial frame write** | Last frame(s) incomplete due to interrupted recording | Decoder error on final frame(s), may cascade to previous GOP | Medium |
| H5 | **Essence track number collision** | Multiple tracks share same track number (OP1b bug) | Only first track audio plays, others silenced or looped | High |
| H6 | **KAG alignment violation** | Essence elements don't align to KLV Alignment Grid boundaries | Some strict decoders reject file, others handle gracefully | Low |

### Category I: Card/Filesystem Recovery Scenarios

| # | Corruption Type | Description | Symptoms | Severity |
|---|----------------|-------------|----------|----------|
| I1 | **Formatted/deleted card** | Card quick-formatted or files deleted — filesystem metadata gone, raw essence on disk | Must scan card cluster-by-cluster, rebuild container from scratch | Critical |
| I2 | **P2 card HFS corruption** | HFS filesystem on P2 card damaged — MXF files fragmented across non-contiguous clusters | Recovered files have gaps, out-of-order data | Critical |
| I3 | **RSV file recovery** | Sony cameras produce .RSV file when recording interrupted — essentially incomplete MXF/MP4 | Rename to .mp4/.mxf, use reference file to reconstruct container | High |
| I4 | **Partial overwrite** | New recording partially overwrites old — some clusters have new data, some have old | Frankenstein file — mix of two different recordings | Critical |

---

## 5. Bitstream-Level Corruption (Both Containers)

These affect the compressed video/audio data inside mdat (MP4) or Essence Elements (MXF), regardless of container health.

### H.264 (AVC) Bitstream Corruption

| # | Type | Description | Effect |
|---|------|-------------|--------|
| BS1 | **SPS corruption/missing** | Sequence Parameter Set damaged — contains resolution, profile, level, reference frame count | Decoder can't initialize at all |
| BS2 | **PPS corruption/missing** | Picture Parameter Set damaged — contains entropy coding mode, slice groups, QP | Frames referencing this PPS undecodable |
| BS3 | **IDR frame loss** | Instantaneous Decoder Refresh frame missing — first frame or periodic keyframe | No clean entry point for decoding; all subsequent P/B frames fail until next IDR |
| BS4 | **NAL unit header corruption** | `forbidden_zero_bit` set to 1, invalid `nal_unit_type` | Decoder rejects NAL unit entirely |
| BS5 | **Slice header corruption** | Slice type, QP delta, reference list modifications damaged | Single slice undecodable, rest of frame may survive if multi-slice |
| BS6 | **Missing NAL start codes** | `0x00 0x00 0x00 0x01` or `0x00 0x00 0x01` absent | NAL boundary detection fails, multiple NALs parsed as one |
| BS7 | **Compressed data bit flips** | Random bit errors in CABAC/CAVLC compressed data | Visual artifacts: macroblocking, color shifts, partial frame corruption |
| BS8 | **Reference frame corruption** | I/P frame used as reference is damaged — error propagates through entire GOP | Cascading artifacts across multiple frames until next IDR |
| BS9 | **SEI message corruption** | Supplemental Enhancement Information damaged | Usually non-fatal; may lose HDR metadata, timecode, or closed captions |

### H.265 (HEVC) Additional Issues

| # | Type | Description | Effect |
|---|------|-------------|--------|
| BS10 | **VPS corruption** | Video Parameter Set (HEVC-specific) damaged | Decoder can't initialize |
| BS11 | **Tile boundary corruption** | HEVC tile partition data damaged | Partial frame corruption in tile region only |
| BS12 | **WPP entry point corruption** | Wavefront Parallel Processing entry points wrong | Multi-threaded decode fails |

### Audio Bitstream Corruption

| # | Type | Description | Effect |
|---|------|-------------|--------|
| AS1 | **AAC ADTS header corruption** | Audio frame header damaged | Frame skipped, progressive A/V desync |
| AS2 | **PCM sample corruption** | Raw audio samples contain wrong values | Clicks, pops, noise bursts |
| AS3 | **Audio frame size mismatch** | Declared size vs actual data mismatch | Decoder reads into next frame, cascading errors |

---

## 6. Storage & Transfer Corruption (Shared)

| # | Type | Description | Containers Affected |
|---|------|-------------|---------------------|
| ST1 | **Bit rot / data decay** | Gradual bit flips from storage media degradation — HDD magnetic decay, SSD charge leakage, optical media delamination | All |
| ST2 | **Bad sectors** | Storage device returns corrupted data for specific disk regions | All |
| ST3 | **Incomplete file transfer** | Network timeout, USB disconnect, copy interrupted | All |
| ST4 | **FAT32 4GB limit** | File system can't store files > 4GB, recording truncated silently | MP4/MOV (cameras using SD cards) |
| ST5 | **File system fragmentation recovery** | Data recovery tool assembles file fragments in wrong order | All |
| ST6 | **Zero-filled regions** | Storage space allocated but never written (power loss during recording) — large blocks of 0x00 | All |
| ST7 | **Encryption/DRM damage** | DRM metadata or key storage corrupted — content encrypted but undecryptable | MP4/MOV |
| ST8 | **Cosmic ray / ECC failure** | Single-event upset causes undetected bit flip beyond ECC correction capability | All (rare) |

---

## 7. Detection Strategies

### For the Analyzer App

**Container-level checks (MP4/MOV):**
1. Parse box tree — validate every box size (size > 8, size ≤ remaining file bytes)
2. Check ftyp presence and brand validity
3. Check moov presence and completeness
4. Validate stbl tables: stco offsets < file size, stsz count matches stts total, stsc references valid chunks
5. Cross-validate stco/co64 with actual mdat boundaries
6. Check for stco overflow on files > 4GB
7. Verify stsd codec configuration (parse SPS/PPS from avcC/hvcC box)
8. Detect orphaned mdat (mdat present, moov absent)
9. For fMP4: validate moof→mdat pairing and tfdt continuity

**Container-level checks (MXF):**
1. Scan for Header Partition Pack UL at file start (`06 0e 2b 34 02 05 01 01 0d 01 02 01 01 02 xx 00`)
2. Walk KLV stream — validate each Key (16-byte UL), Length (BER), Value (Length bytes)
3. Detect KLV breaks (scan forward for next valid SMPTE key)
4. Validate Partition Pack kind/status bytes
5. Check Primer Pack completeness
6. Verify essence descriptor vs actual essence format
7. Validate Index Table entries against essence container offsets
8. Check Footer Partition presence and closed/complete status

**Bitstream-level checks:**
1. Scan for NAL start codes, validate forbidden_zero_bit = 0
2. Verify SPS/PPS presence before first slice
3. Check IDR frame presence (nal_unit_type = 5 for H.264, types 16-21 for HEVC)
4. Validate GOP structure integrity
5. Check for zero-filled regions in mdat/essence

---

## 8. Repair Strategies

> Note: VideoAnalyzer is analysis-only. Repair/remux is a separate project.

### MP4/MOV Repair Approaches

| Corruption | Repair Strategy |
|-----------|----------------|
| **Missing moov** | Reconstruct from reference file (same camera/settings) — extract codec config, scan mdat for NAL units, rebuild sample tables (stts, stsz, stco, stss) |
| **Truncated file** | If moov at start (fast-start): adjust mdat size to match actual file size, truncate sample tables. If moov at end: full moov reconstruction needed |
| **stco/co64 offset errors** | Recalculate offsets by scanning mdat for frame boundaries (NAL start codes for H.264/H.265, ProRes frame headers, etc.) |
| **stco overflow (>4GB)** | Convert stco → co64, recalculate all offsets, update all parent box sizes |
| **Orphaned mdat** | Full reconstruction: determine codec from bitstream analysis, build entire moov from scratch |
| **Duplicate moov** | Identify correct moov (usually last one or the one at standard position), strip extras, re-validate stco offsets |
| **fMP4 moof damage** | Rebuild moof from mdat analysis for affected segment, or skip damaged segment |
| **A/V desync** | Recalculate stts/ctts tables, or separate tracks and re-interleave with corrected timing |

### MXF Repair Approaches

| Corruption | Repair Strategy |
|-----------|----------------|
| **Missing Header/Footer** | Extract essence from Body, determine format by analyzing KLV essence element ULs and bitstream, reconstruct Header/Footer from scratch or from reference file |
| **KLV break** | Scan forward for next valid SMPTE key, bridge gap with KLV Fill, adjust Index Table |
| **Primer Pack damage** | Rebuild primer from SMPTE standard defaults for the operational pattern |
| **Index Table damage** | Scan essence container sequentially, rebuild index from essence element positions |
| **Interleaved junk** | Filter essence elements by UL pattern, strip non-essence KLVs, reassemble clean Body |
| **RSV file** | Rename to appropriate extension, use reference file to supply Header/Footer metadata, reconstruct container |
| **P2 card recovery** | Cluster-level scan, identify essence by UL patterns, filter HFS metadata clusters, reassemble per-track MXF files |
| **OP-Atom track linkage** | Rebuild MXFMaterialPackage linking separate track files |

---

## 9. Useful Tools & Libraries for macOS

### Analysis / Inspection
- **MP4Box** (GPAC) — `brew install gpac` — MP4 parsing, box inspection, manipulation
- **mp4dump** (Bento4) — `brew install bento4` — detailed box/atom dumping
- **ffprobe** — `brew install ffmpeg` — stream analysis, frame-level inspection
- **MediaInfo** — `brew install mediainfo` — comprehensive metadata extraction
- **mp4analyser** (Python) — `pip install mp4analyser` — programmatic MP4 structure analysis

### Repair / Recovery
- **untrunc** (anthwlock fork) — reference-based moov reconstruction for truncated MP4/MOV
- **ffmpeg** — `-err_detect ignore_err -i broken.mp4 -c copy fixed.mp4` — error-tolerant remux
- **MP4Box** — can attempt to repair/rewrite MP4 structure

### Programming Libraries (Swift/C/Python)
- **mp4parse-rust** (Mozilla) — Rust MP4 parser, can be called from Swift via FFI
- **libavformat** (FFmpeg) — C library for container format reading/writing
- **Apple AVFoundation** — native macOS framework for reading MP4/MOV structure

### Hex Analysis
- **Hex Fiend** — macOS native hex editor, excellent for large video files
- **hexdump / xxd** — CLI hex inspection

---

## Coverage Map (VideoAnalyzer Implementation Status)

Last updated: 2026-02-26

| Category | Coverage | Notes |
|----------|----------|-------|
| A: Box/Atom Structural | ~81% | A1-A4 detected + invalid sizes, overlapping, extends-beyond-EOF |
| B: Sample Table | ~86% | stco, stsz, stss, elst, stts/ctts timing, stco overflow (>4GB) |
| C: Fragmented MP4 | ~10% | No moof parser yet |
| D: MOV-Specific | 0% | cmov, rmra not handled |
| E: A/V Sync | ~63% | Timestamp gaps, edit lists done |
| F: MXF Partition | 100% | All partition checks implemented |
| G: MXF Metadata | ~50% | Essence descriptors, OP pattern done |
| H: MXF Essence | ~42% | Unfinalized, KLV length checks done |
| BS: Bitstream | ~42% | NAL boundaries, IDR presence, SPS/PPS/VPS validation in avcC/hvcC |
| AS: Audio Bitstream | 0% | Not implemented |
| ST: Storage/Transfer | ~31% | Truncation, incomplete writes done |
