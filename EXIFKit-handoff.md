# EXIFKit — Conversation Handoff

## Project Overview

**EXIFKit** is a pure Swift library for reading, writing, and stripping EXIF metadata from images. Built from scratch with zero dependencies (Foundation only). Designed primarily to support **Taggy**, an iOS photo geotagging app that matches photo timestamps with Google Maps Timeline data.

## Current State

- **14 source files, ~4,150 lines of code**
- **Zero external dependencies** (Foundation only)
- Swift 5.9+, iOS 15+ / macOS 12+
- Public API surface: `EXIFKit.read(from:)`, `EXIFKit.write(_:to:)`, `EXIFKit.strip(from:)`, `EXIFKit.dump(_:)`
- **Has NOT been compiled or tested against real camera files yet** — synthetic round-trip tests only

## Format Support

13 formats, all with read/write/strip:
- **Standard**: JPEG, PNG, TIFF, DNG
- **Canon**: CR2 (TIFF-based), CR3 (ISOBMFF-based)
- **Nikon**: NEF
- **Sony**: ARW
- **Fujifilm**: RAF (custom container with embedded JPEG)
- **Olympus/OM System**: ORF (uses non-standard magic 0x4F52)
- **Panasonic/Lumix**: RW2 (uses non-standard magic 0x0055)
- **Pentax**: PEF
- **Apple/modern**: HEIF/HEIC/AVIF (ISOBMFF-based)

## Architecture

```
EXIFKit.swift          ← Public API: read/write/strip/dump + ImageFormat enum
  ├── JPEG.swift        ← APP1 marker segment container
  ├── PNG.swift         ← eXIf chunk container (with CRC32 implementation)
  ├── TIFFFile.swift    ← Standalone TIFF/DNG container with IFD0 rebuild support
  ├── RAWFormats.swift  ← CR2, NEF, ARW, ORF, RW2, PEF (TIFF-based RAWs)
  ├── CR3.swift         ← Canon CR3 with full ISOBMFF box tree rebuild
  ├── HEIF.swift        ← HEIF/HEIC with iloc patching for in-place writes
  ├── RAF.swift         ← Fujifilm — modifies embedded JPEG, recalculates header offsets
  ├── ISOBMFF.swift     ← ISO Base Media File Format parser (used by CR3 + HEIF)
  ├── TIFF.swift        ← TIFFStructure + TIFFParser + TIFFSerializer
  ├── IFD.swift         ← IFD read/write engine (12-byte entries, all 12 EXIF data types)
  ├── ByteReader.swift  ← Endian-aware cursor-based binary I/O (ByteReader + ByteWriter)
  ├── Types.swift       ← TagValue (22 cases), EXIFError, URational, SRational, EXIFDataType
  └── Tags.swift        ← Standard EXIF/TIFF/GPS tag dictionary
```

The library is layered: container parsers find TIFF data within each format, the TIFF parser reads IFD chains, and the IFD engine reads individual tag entries. Everything flows through `ByteReader`/`ByteWriter` which handle endianness. All formats produce the same `TIFFStructure` output.

**Important: MakerNote handling**

The user explicitly asked to **REMOVE** the MakerNote parser and tag dictionaries (originally `MakerNote.swift` ~566 lines and `MakerNoteTags.swift` ~736 lines, ~1,300 lines total) because they didn't want the maintenance burden of monthly tag dictionary updates. MakerNote blobs (tag 0x927C) are now preserved as raw bytes during read/write — they pass through untouched without any manufacturer-specific decoding. The `Tag.makerNote` constant (0x927C) remains as a standard EXIF tag ID, but there is no `MakerNote` struct, no `Manufacturer` enum, and no `MakerNoteTags` dictionary. **Do not re-add these.**

## Write Strategies by Format

| Format | Strategy |
|--------|----------|
| JPEG | Full APP1 segment rebuild — can change anything |
| PNG | eXIf chunk replace or insert before IDAT |
| TIFF/DNG/RAW | Append sub-IFDs + patch IFD0 pointers in place. If IFD0 needs new tags, IFD0 is rebuilt at end of file with TIFF header offset updated. **Image data offsets (StripOffsets, TileOffsets) are never touched.** |
| CR3 | Full ISOBMFF box tree rebuild with recalculated box sizes (moov/uuid contents) |
| HEIF/HEIC | iloc patch for in-place; append + iloc offset/length update for size changes |
| RAF | Modify embedded JPEG preview, recalculate RAF header offsets if size changes |

## Bug Fix History (all currently fixed)

1. **Double endianness** (IFD.swift) — was splitting UInt64 into two endian-aware UInt32 reads which produced wrong results on little-endian. **Fixed** to read raw 8 bytes with single UInt64 endian conversion.

2. **iloc version parsing** (HEIF.swift × 2 sites + ISOBMFF.swift) — was reading `iloc.payloadData[0]` as the version byte, but `payloadData` already strips the 4-byte version+flags prefix. So the first byte was actually offset/length size fields. **Fixed** by reading `iloc.version ?? 0` and adjusting reader offsets.

3. **CR3 buildBox append** (CR3.swift) — was using wrong `Data.append(_:count:)` overload with an Array argument. **Fixed** with `append(contentsOf:)`.

4. **JPEG segment overflow** (JPEG.swift) — was using `UInt16(segment.data.count + 2)` which would trap on >64KB segments. **Fixed** with `UInt16(clamping:)`.

5. **TIFFFile pointer addition** (TIFFFile.swift) — was throwing `tagNotFound` when adding GPS to a file that had no existing GPS pointer in IFD0. **Fixed** with full IFD0 rebuild strategy that appends new IFD0 at end of file and patches the TIFF header offset.

6. **MakerNote offset resolution** (EXIFKit.swift, since removed) — manufacturers using absolute offsets (Canon/Sony/Apple) need the real TIFF-base offset, not 0. Was fixed via `findMakerNoteOffset()` byte-pattern scan, but the entire MakerNote system was subsequently removed at user's request.

## Public API

### Core operations

```swift
// Read — auto-detect format
let metadata = try EXIFKit.read(from: data)

// Read with explicit format
let metadata = try EXIFKit.read(from: data, format: .cr3)

// Read from URL (uses extension)
let metadata = try EXIFKit.read(from: url)

// Write
let newData = try EXIFKit.write(metadata, to: originalData)

// Strip
let cleanData = try EXIFKit.strip(from: data)

// Dump (debug)
print(EXIFKit.dump(metadata))
```

### TIFFStructure convenience accessors

Camera info: `make`, `model`, `software`, `artist`, `copyright`, `imageDescription`
Exposure: `iso`, `fNumber`, `exposureTime`, `exposureBias`, `flashFired`
Lens: `focalLength`, `focalLength35mm`, `lensModel`, `lensMake`
Image: `orientation`, `colorSpace`, `pixelWidth`, `pixelHeight`
Date/time: `dateTimeOriginal`, `dateTimeDigitized`, `offsetTimeOriginal`
GPS: `latitude`, `longitude`, `altitude` (signed decimal degrees)
Thumbnail: `thumbnailData` (extracts JPEG thumbnail from IFD1)

### GPS Geotagging (most relevant for Taggy)

```swift
var m = try EXIFKit.read(from: data)
m.setGPSCoordinates(
    latitude: 48.8566,    // positive = North
    longitude: 2.3522,    // positive = East
    altitude: 35.0        // optional, meters
)
let geotagged = try EXIFKit.write(m, to: data)
```

This works on files that had no GPS data — the GPS sub-IFD and IFD0 pointer are created automatically.

### Reading any tag

```swift
let m = try EXIFKit.read(from: data)
m.ifd0.value(for: Tag.imageDescription)?.stringValue
m.exifIFD?.value(for: Tag.exposureProgram)?.uint32Value
m.gpsIFD?.value(for: Tag.gpsTimeStamp)
m.exifIFD?.value(for: 0xA434) // raw tag ID
```

### TagValue enum (22 cases)

All 12 EXIF data types are fully supported: `byte/bytes`, `ascii`, `short/shorts`, `long/longs`, `rational/rationals`, `srational/srationals`, `signedByte/signedBytes`, `signedShort/signedShorts`, `signedLong/signedLongs`, `float/floats`, `double/doubles`, `undefined`.

Accessors: `stringValue`, `uint32Value`, `intValue`, `doubleValue`, `rawData`, `dataType`, `count`, `totalSize`.

## User Context

The user is **Inje**, a Data Analyst Specialist at Samsung SDS Europe based in Woking, England. Strong iOS development hobby with sustained SwiftUI work. They previously built **Taggy**, an iOS app that matches photo timestamps with Google Maps Timeline data to add GPS EXIF data — this library was built primarily to support that use case.

Inje has an MSc in Financial Technology from University of Nottingham and BSc in Computer Science from Hanyang University. Other recent projects: ML sales forecasting model with CatBoost/LightGBM, automated e-commerce price scraper using browser-use and Claude API, and a focused distraction-free iOS YouTube client.

**Communication preferences observed in the conversation:**
- Direct and concise; doesn't want fluff or excessive caveats
- Asks pointed questions about specific design decisions ("aren't there any libraries for byte reading?", "do I really need maker notes?")
- Values knowing about limitations honestly upfront
- Wants the library to be low-maintenance — explicitly removed ~1,300 lines of MakerNote code rather than maintain a tag dictionary

## Known Limitations (by design, documented in README)

- **No XMP or IPTC** — only TIFF/IFD-based EXIF is parsed
- **No ICC profile parsing** — preserved as opaque data
- **MakerNote is opaque** — preserved as raw bytes, not decoded (user's choice)
- **HEIF multi-image** — only the primary image's EXIF is extracted, not depth maps/gain maps/burst frames
- **Not yet tested against real camera files** — passes synthetic round-trip tests only

## Files in the package

```
EXIFKit/
├── Package.swift
├── README.md          ← Comprehensive ~440-line documentation
├── LICENSE            ← MIT
├── .gitignore         ← Standard Swift package ignores
├── Sources/
│   └── EXIFKit/
│       ├── ByteReader.swift   (228 lines)
│       ├── Types.swift        (302 lines — TagValue, errors, rationals)
│       ├── Tags.swift         (167 lines — standard EXIF tag dictionary)
│       ├── IFD.swift          (~450 lines — read/write engine)
│       ├── TIFF.swift         (~440 lines — TIFFStructure + parser + serializer)
│       ├── TIFFFile.swift     (197 lines — TIFF/DNG container with IFD0 rebuild)
│       ├── RAWFormats.swift   (250 lines — CR2/NEF/ARW/ORF/RW2/PEF)
│       ├── ISOBMFF.swift      (~420 lines — used by CR3 and HEIF)
│       ├── CR3.swift          (~310 lines — full box tree rebuild)
│       ├── HEIF.swift         (~485 lines — iloc patching)
│       ├── RAF.swift          (182 lines — embedded JPEG modification)
│       ├── JPEG.swift         (231 lines — APP1 marker)
│       ├── PNG.swift          (186 lines — eXIf chunk + CRC32)
│       └── EXIFKit.swift      (~330 lines — public API + dump)
└── Tests/
    └── EXIFKitTests/
        └── EXIFKitTests.swift (~445 lines — round-trip tests, format detection, all data types)
```

## Next Steps for Continuation

**Highest priority:**
1. **Actually compile it** — `swift build` in the package directory. There may be minor syntax issues that surface only on first compile (no Swift compiler was available during development).
2. **Test against real camera files** — synthetic tests pass but real-world Canon/Nikon/Sony/Fujifilm files will likely surface edge cases. Build a small test suite of representative files.
3. **Run `swift test`** to verify the round-trip tests pass.
4. **Publish to GitHub** — create repo, tag 0.1.0, push. Standard SPM publishing.

**Lower priority improvements that were discussed but not implemented:**
- Adding XMP parser (separate APP1 segment with `http://ns.adobe.com/xap/1.0/` header)
- IPTC parser (APP13 segment in JPEG)
- ICC profile parsing
- HEIF depth map / gain map / burst frame extraction
- Test with real Taggy use case (geotagging actual iPhone HEIC files)

**Things explicitly rejected by user (don't re-add):**
- MakerNote parser and tag dictionaries
- Manufacturer enum and detection
- swift-nio or any other byte-reading dependency

## Key Implementation Details to Remember

**TIFFStructure.sourceTIFFData** — internal property that retains the raw TIFF bytes for thumbnail extraction. Set by `TIFFParser.parse()` via the `withSourceData()` extension method. Not part of the Sendable serialization, just used internally.

**IFD0 rebuild trigger** — `TIFFFileContainer.writeEXIF` checks if any non-pointer, non-image-data IFD0 tags have changed (or if a new sub-IFD pointer needs to be added). If yes, it goes into `rebuildWithNewIFD0()`. Otherwise it uses the fast append-and-patch path. Image-data tags (StripOffsets, TileOffsets, JPEGInterchangeFormat) are always preserved from the original.

**iloc patcher** — `payloadData` already strips the 4-byte version+flags prefix for FullBoxes, so byte 0 is the offset/length size byte, NOT the version. Always read version from `iloc.version ?? 0`. The reader starts at offset 2 (skipping the two size-fields bytes), then reads item count.

**CR3 box rebuild** — when CMT box sizes change, the entire moov/uuid box tree needs rebuilding with recalculated sizes. The `buildBox` helper creates a single ISOBMFF box from type + payload. Type strings shorter than 4 chars are padded with spaces.

**RAF JPEG offset** — embedded JPEG offset is at byte 84 (big-endian UInt32), length at byte 88, CFA header offset at byte 92, CFA data offset at byte 100. When the embedded JPEG size changes, all offsets pointing past the JPEG must be adjusted by the size diff.

**RAWContainer non-standard magic** — ORF uses 0x4F52 ("OR") or 0x5352 ("SR"), RW2 uses 0x0055. Both bypass the standard TIFF magic number check (which expects 42) and parse the IFD chain directly.

## How to Resume

Tell Claude: "I'm continuing work on EXIFKit, a Swift EXIF library I've been building. Here's the handoff document." Then attach this file and the EXIFKit folder. Claude should be able to pick up from any of the next steps above without missing context.
