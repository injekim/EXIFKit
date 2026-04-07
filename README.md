# EXIFKit

A pure Swift library for reading, writing, and stripping EXIF metadata from images. Zero external dependencies — Foundation only.

## Features

- **Read** EXIF metadata from 13 image formats
- **Write** modified metadata back (GPS geotagging, camera info, timestamps, etc.)
- **Strip** all EXIF metadata for privacy
- **Auto-detect** image format from file contents or extension
- All 12 EXIF data types fully supported
- MakerNote blobs preserved as raw bytes (pass-through, no decoding)
- Swift 6 strict concurrency compliant

## Supported Formats

| Format | Type | Read | Write | Strip |
|--------|------|------|-------|-------|
| JPEG | Standard | Yes | Yes | Yes |
| PNG | Standard | Yes | Yes | Yes |
| TIFF | Standard | Yes | Yes | Yes |
| DNG | Standard | Yes | Yes | Yes |
| CR2 (Canon) | TIFF-based | Yes | Yes | Yes |
| CR3 (Canon) | ISOBMFF | Yes | Yes | Yes |
| NEF (Nikon) | TIFF-based | Yes | Yes | Yes |
| ARW (Sony) | TIFF-based | Yes | Yes | Yes |
| RAF (Fujifilm) | Custom | Yes | Yes | Yes |
| ORF (Olympus/OM) | TIFF variant | Yes | Yes | Yes |
| RW2 (Panasonic) | TIFF variant | Yes | Yes | Yes |
| PEF (Pentax) | TIFF-based | Yes | Yes | Yes |
| HEIF/HEIC/AVIF | ISOBMFF | Yes | Yes | Yes |

## Requirements

- Swift 5.9+
- iOS 15+ / macOS 12+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/injekim/EXIFKit.git", from: "0.1.0")
]
```

Or in Xcode: File > Add Package Dependencies, then paste the repository URL.

## Usage

### Reading EXIF

```swift
import EXIFKit

// Auto-detect format from data
let metadata = try EXIFKit.read(from: imageData)

// Or from a file URL (uses extension for format hint)
let metadata = try EXIFKit.read(from: url)

// Or with explicit format
let metadata = try EXIFKit.read(from: data, format: .cr3)

// Access common fields
print(metadata.make)              // "NIKON CORPORATION"
print(metadata.model)             // "NIKON Z 8"
print(metadata.dateTimeOriginal)  // "2024:01:15 14:30:00"
print(metadata.iso)               // 100
print(metadata.fNumber)           // 2.8
print(metadata.focalLength)       // 50.0
print(metadata.lensModel)         // "NIKKOR Z 50mm f/1.8 S"
print(metadata.latitude)          // 51.5074
print(metadata.longitude)         // -0.1278
```

### Writing EXIF

```swift
var metadata = try EXIFKit.read(from: imageData)

// Modify any tag
metadata.ifd0.set(tagID: Tag.software, value: .ascii("MyApp"))
metadata.ifd0.set(tagID: Tag.artist, value: .ascii("Photographer"))

// Write back
let newData = try EXIFKit.write(metadata, to: imageData)
```

### GPS Geotagging

```swift
var metadata = try EXIFKit.read(from: imageData)
metadata.setGPSCoordinates(
    latitude: 48.8566,    // positive = North
    longitude: 2.3522,    // positive = East
    altitude: 35.0        // optional, meters
)
let geotagged = try EXIFKit.write(metadata, to: imageData)
```

This works even on files with no existing GPS data — the GPS sub-IFD and IFD0 pointer are created automatically.

### Stripping EXIF

```swift
let cleanData = try EXIFKit.strip(from: imageData)
```

### Reading Any Tag

```swift
let m = try EXIFKit.read(from: data)
m.ifd0.value(for: Tag.imageDescription)?.stringValue
m.exifIFD?.value(for: Tag.exposureProgram)?.uint32Value
m.gpsIFD?.value(for: Tag.gpsTimeStamp)
m.exifIFD?.value(for: 0xA434) // raw tag ID
```

### Debug Dump

```swift
print(EXIFKit.dump(metadata))
```

## Convenience Accessors

`TIFFStructure` provides typed accessors for common fields:

| Category | Properties |
|----------|-----------|
| Camera | `make`, `model`, `software`, `artist`, `copyright`, `imageDescription` |
| Exposure | `iso`, `fNumber`, `exposureTime`, `exposureBias`, `flashFired` |
| Lens | `focalLength`, `focalLength35mm`, `lensModel`, `lensMake` |
| Image | `orientation`, `colorSpace`, `pixelWidth`, `pixelHeight` |
| Date/Time | `dateTimeOriginal`, `dateTimeDigitized`, `offsetTimeOriginal` |
| GPS | `latitude`, `longitude`, `altitude` (signed decimal degrees) |
| Thumbnail | `thumbnailData` (extracts JPEG thumbnail from IFD1) |

## Architecture

```
EXIFKit.swift          <- Public API: read/write/strip/dump + ImageFormat enum
  +-- JPEG.swift        <- APP1 marker segment container
  +-- PNG.swift         <- eXIf chunk container (with CRC32)
  +-- TIFFFile.swift    <- Standalone TIFF/DNG container with IFD0 rebuild
  +-- RAWFormats.swift  <- CR2, NEF, ARW, ORF, RW2, PEF (TIFF-based RAWs)
  +-- CR3.swift         <- Canon CR3 with full ISOBMFF box tree rebuild
  +-- HEIF.swift        <- HEIF/HEIC with iloc patching
  +-- RAF.swift         <- Fujifilm: modifies embedded JPEG, recalculates offsets
  +-- ISOBMFF.swift     <- ISO Base Media File Format parser (CR3 + HEIF)
  +-- TIFF.swift        <- TIFFStructure + TIFFParser + TIFFSerializer
  +-- IFD.swift         <- IFD read/write engine (12-byte entries, all data types)
  +-- ByteReader.swift  <- Endian-aware cursor-based binary I/O
  +-- Types.swift       <- TagValue (22 cases), EXIFError, URational, SRational
  +-- Tags.swift        <- Standard EXIF/TIFF/GPS tag dictionary
```

The library is layered: container parsers find TIFF data within each format, the TIFF parser reads IFD chains, and the IFD engine reads individual tag entries. Everything flows through `ByteReader`/`ByteWriter` for endianness handling. All formats produce the same `TIFFStructure` output.

## Write Strategies

| Format | Strategy |
|--------|----------|
| JPEG | Full APP1 segment rebuild |
| PNG | eXIf chunk replace or insert before IDAT |
| TIFF/DNG/RAW | Append sub-IFDs + patch IFD0 pointers. Rebuilds IFD0 at end of file if new pointer tags needed. Image data offsets never touched. |
| CR3 | Full ISOBMFF box tree rebuild with recalculated sizes |
| HEIF/HEIC | In-place replacement when data fits; append + iloc offset update otherwise |
| RAF | Modify embedded JPEG preview, recalculate header offsets if size changes |

## Bug Fix History

All issues discovered during development and initial audit have been resolved:

1. **Double endianness** (IFD.swift) — Was splitting UInt64 into two endian-aware UInt32 reads. Fixed to read raw 8 bytes with single UInt64 endian conversion.

2. **iloc version parsing** (HEIF.swift, ISOBMFF.swift) — Was reading `iloc.payloadData[0]` as version, but `payloadData` already strips the 4-byte version+flags prefix. Fixed to read `iloc.version ?? 0` and adjust reader offsets.

3. **CR3 buildBox append** (CR3.swift) — Was using wrong `Data.append(_:count:)` overload. Fixed with `append(contentsOf:)`.

4. **JPEG segment overflow** (JPEG.swift) — Was using `UInt16(segment.data.count + 2)` which traps on >64KB segments. Fixed with `UInt16(clamping:)`.

5. **TIFFFile pointer addition** (TIFFFile.swift) — Was throwing `tagNotFound` when adding GPS to a file with no existing GPS pointer in IFD0. Fixed with full IFD0 rebuild strategy.

6. **Swift 6 Sendable conformance** (ByteReader.swift) — `ByteOrder` enum lacked `Sendable` conformance required by Swift 6 strict concurrency. Fixed by adding `: Sendable`.

7. **Set union type error** (TIFFFile.swift) — Array literal `[UInt16]` has no `.union()` method. Fixed by wrapping in `Set(...)`.

8. **Guard fallthrough** (ISOBMFF.swift) — `guard` body assigned a variable instead of returning/throwing, causing a compiler error. Fixed by converting to `if` statement.

9. **Unused variables** (HEIF.swift, RAF.swift, TIFF.swift) — Removed unused `entryStartOffset`, `baseOffsetPos`, `newJPEGOffset` variables; changed `var` to `let` for `exifIFD`/`gpsIFD` in serializer.

10. **TIFF strip left pointers intact** (TIFFFile.swift) — `needsIFD0Rebuild` only detected when pointer tags needed to be *added*, not *removed*. Stripping EXIF from TIFF-based formats (TIFF/DNG/CR2/NEF/ARW/PEF/ORF/RW2) returned unchanged data. Fixed by changing `(needsExifPointer && !hadExifPointer)` to `(needsExifPointer != hadExifPointer)`.

11. **ORF/RW2 write rejected by TIFFParser** (RAWFormats.swift, TIFFFile.swift) — `RAWContainer.writeEXIF` delegated to `TIFFFileContainer.writeEXIF`, which re-parsed the original with `TIFFParser.parse()`. TIFFParser rejects non-standard magic numbers (ORF: 0x4F52, RW2: 0x0055). Fixed by adding an internal `writeEXIFInternal` method that accepts a pre-parsed structure, allowing RAWContainer to use its own ORF/RW2 readers.

12. **ISOBMFF uuid box children not parsed** (ISOBMFF.swift) — The parser treated `uuid` boxes as containers but parsed children from byte 0 of the payload, misinterpreting the 16-byte UUID identifier as box headers. CR3 files couldn't find CMT metadata boxes. Fixed by skipping 16 bytes before parsing uuid children.

13. **ISOBMFF iinf children not parsed** (ISOBMFF.swift) — `iinf` was not listed as a container type, so its `infe` children were never parsed. HEIF write/strip couldn't locate the Exif item ID. Fixed by adding `iinf` to container types with a 6-byte skip (version/flags + entry_count).

## Known Limitations

- **No XMP or IPTC** — Only TIFF/IFD-based EXIF is parsed
- **No ICC profile parsing** — Preserved as opaque data
- **MakerNote is opaque** — Preserved as raw bytes, not decoded
- **HEIF multi-image** — Only the primary image's EXIF is extracted
- **HEIF strip after size-changing write** — If a write operation causes an append (new EXIF data is larger), stripping only zeros the current iloc-referenced copy; the stale original copy in mdat may remain. Stripping from unmodified files works correctly.
- **Not yet tested against real camera files** — Passes synthetic round-trip tests for all 13 formats

## License

MIT
