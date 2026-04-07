import Foundation

// MARK: - Image Format Detection

/// Supported image formats for EXIF parsing
public enum ImageFormat: String, CaseIterable, Sendable {
    case jpeg
    case png
    case tiff
    case dng
    case cr2      // Canon (TIFF-based)
    case cr3      // Canon (ISOBMFF-based)
    case nef      // Nikon (TIFF-based)
    case arw      // Sony (TIFF-based)
    case raf      // Fujifilm (custom)
    case orf      // Olympus / OM System (TIFF variant)
    case rw2      // Panasonic / Lumix (TIFF variant)
    case pef      // Pentax (TIFF-based)
    case heif     // HEIF / HEIC (ISOBMFF-based)

    /// Whether this format is TIFF-based (uses standard IFD structures)
    public var isTIFFBased: Bool {
        switch self {
        case .tiff, .dng, .cr2, .nef, .arw, .orf, .rw2, .pef:
            return true
        default:
            return false
        }
    }

    /// Whether this format uses ISOBMFF container
    public var isISOBMFF: Bool {
        switch self {
        case .cr3, .heif:
            return true
        default:
            return false
        }
    }

    /// Detect format from file data by inspecting magic bytes
    public static func detect(from data: Data) -> ImageFormat? {
        guard data.count >= 16 else {
            guard data.count >= 8 else { return nil }
            let head = [UInt8](data.prefix(8))
            if head[0] == 0xFF && head[1] == 0xD8 { return .jpeg }
            if head[0] == 0x89 && head[1] == 0x50 && head[2] == 0x4E && head[3] == 0x47 { return .png }
            return nil
        }

        let head = [UInt8](data.prefix(16))

        // JPEG
        if head[0] == 0xFF && head[1] == 0xD8 {
            return .jpeg
        }

        // PNG
        if head[0] == 0x89 && head[1] == 0x50 && head[2] == 0x4E && head[3] == 0x47 {
            return .png
        }

        // Fujifilm RAF
        if RAFContainer.isRAF(data) {
            return .raf
        }

        // ISOBMFF-based formats
        if head[4] == 0x66 && head[5] == 0x74 && head[6] == 0x79 && head[7] == 0x70 {
            if CR3Container.isCR3(data) { return .cr3 }
            if HEIFContainer.isHEIF(data) { return .heif }
        }

        // TIFF-based formats
        let isLE = (head[0] == 0x49 && head[1] == 0x49)
        let isBE = (head[0] == 0x4D && head[1] == 0x4D)

        if isLE || isBE {
            let magic: UInt16
            if isLE {
                magic = UInt16(head[2]) | UInt16(head[3]) << 8
            } else {
                magic = UInt16(head[2]) << 8 | UInt16(head[3])
            }

            if magic == 0x4F52 || magic == 0x5352 { return .orf }
            if magic == 0x0055 { return .rw2 }

            if magic == 42 {
                if data.count >= 10 && head[8] == 0x43 && head[9] == 0x52 {
                    return .cr2
                }
                return .tiff
            }
        }

        return nil
    }

    /// Detect format from file extension
    public static func detect(fromExtension ext: String) -> ImageFormat? {
        switch ext.lowercased() {
        case "jpg", "jpeg":       return .jpeg
        case "png":               return .png
        case "tif", "tiff":       return .tiff
        case "dng":               return .dng
        case "cr2":               return .cr2
        case "cr3":               return .cr3
        case "nef", "nrw":        return .nef
        case "arw", "srf", "sr2": return .arw
        case "raf":               return .raf
        case "orf":               return .orf
        case "rw2":               return .rw2
        case "pef":               return .pef
        case "srw":               return .tiff
        case "heif", "heic":      return .heif
        case "avif":              return .heif
        default:                  return nil
        }
    }
}

// MARK: - EXIFKit

/// Main entry point for reading and writing EXIF metadata.
///
/// Supports all major image formats:
/// - **Standard**: JPEG, PNG, TIFF, DNG
/// - **Canon**: CR2 (TIFF-based), CR3 (ISOBMFF-based)
/// - **Nikon**: NEF (TIFF-based)
/// - **Sony**: ARW (TIFF-based)
/// - **Fujifilm**: RAF (custom container)
/// - **Olympus/OM System**: ORF (TIFF variant)
/// - **Panasonic/Lumix**: RW2 (TIFF variant)
/// - **Pentax**: PEF (TIFF-based)
/// - **Apple/Modern**: HEIF/HEIC (ISOBMFF-based)
///
/// Usage:
/// ```swift
/// // Read — auto-detects format
/// let metadata = try EXIFKit.read(from: imageData)
/// print(metadata.make)             // "NIKON CORPORATION"
/// print(metadata.model)            // "NIKON Z 8"
/// print(metadata.dateTimeOriginal) // "2024:01:15 14:30:00"
///
/// // Modify and write back
/// var metadata = try EXIFKit.read(from: imageData)
/// metadata.setGPSCoordinates(latitude: 48.8566, longitude: 2.3522)
/// let newData = try EXIFKit.write(metadata, to: imageData)
/// ```
public enum EXIFKit {

    // MARK: - Reading

    /// Read EXIF metadata from image data (auto-detects format).
    public static func read(from data: Data) throws -> TIFFStructure {
        guard let format = ImageFormat.detect(from: data) else {
            throw EXIFError.unsupportedFormat("Unable to detect image format")
        }
        return try read(from: data, format: format)
    }

    /// Read EXIF metadata from image data with explicit format.
    public static func read(from data: Data, format: ImageFormat) throws -> TIFFStructure {
        switch format {
        case .jpeg:
            return try JPEGContainer.readEXIF(from: data)
        case .png:
            return try PNGContainer.readEXIF(from: data)
        case .tiff, .dng:
            return try TIFFFileContainer.readEXIF(from: data)
        case .cr2, .nef, .arw, .pef, .orf, .rw2:
            return try RAWContainer.readEXIF(from: data)
        case .cr3:
            return try CR3Container.readEXIF(from: data)
        case .heif:
            return try HEIFContainer.readEXIF(from: data)
        case .raf:
            return try RAFContainer.readEXIF(from: data)
        }
    }

    /// Read EXIF metadata from a file URL.
    public static func read(from url: URL) throws -> TIFFStructure {
        let data = try Data(contentsOf: url)
        if let ext = ImageFormat.detect(fromExtension: url.pathExtension) {
            return try read(from: data, format: ext)
        }
        return try read(from: data)
    }

    // MARK: - Writing

    /// Write modified EXIF metadata back to image data (auto-detects format).
    public static func write(_ structure: TIFFStructure, to data: Data) throws -> Data {
        guard let format = ImageFormat.detect(from: data) else {
            throw EXIFError.unsupportedFormat("Unable to detect image format")
        }
        return try write(structure, to: data, format: format)
    }

    /// Write modified EXIF metadata back to image data with explicit format.
    public static func write(
        _ structure: TIFFStructure,
        to data: Data,
        format: ImageFormat
    ) throws -> Data {
        switch format {
        case .jpeg:
            return try JPEGContainer.writeEXIF(structure, to: data)
        case .png:
            return try PNGContainer.writeEXIF(structure, to: data)
        case .tiff, .dng:
            return try TIFFFileContainer.writeEXIF(structure, to: data)
        case .cr2, .nef, .arw, .pef, .orf, .rw2:
            return try RAWContainer.writeEXIF(structure, to: data)
        case .cr3:
            return try CR3Container.writeEXIF(structure, to: data)
        case .heif:
            return try HEIFContainer.writeEXIF(structure, to: data)
        case .raf:
            return try RAFContainer.writeEXIF(structure, to: data)
        }
    }

    // MARK: - Stripping

    /// Strip all EXIF metadata from image data (auto-detects format).
    public static func strip(from data: Data) throws -> Data {
        guard let format = ImageFormat.detect(from: data) else {
            throw EXIFError.unsupportedFormat("Unable to detect image format")
        }
        return try strip(from: data, format: format)
    }

    /// Strip all EXIF metadata from image data with explicit format.
    public static func strip(from data: Data, format: ImageFormat) throws -> Data {
        switch format {
        case .jpeg:
            return try JPEGContainer.stripEXIF(from: data)
        case .png:
            return try PNGContainer.stripEXIF(from: data)
        case .heif:
            return try HEIFContainer.stripEXIF(from: data)
        case .tiff, .dng, .cr2, .nef, .arw, .pef, .orf, .rw2:
            var structure = try read(from: data, format: format)
            structure.exifIFD = nil
            structure.gpsIFD = nil
            structure.ifd0.remove(tagID: Tag.exifIFDPointer)
            structure.ifd0.remove(tagID: Tag.gpsIFDPointer)
            return try write(structure, to: data, format: format)
        case .cr3:
            return try CR3Container.stripEXIF(from: data)
        case .raf:
            var structure = try read(from: data, format: format)
            structure.exifIFD = nil
            structure.gpsIFD = nil
            structure.ifd0.remove(tagID: Tag.exifIFDPointer)
            structure.ifd0.remove(tagID: Tag.gpsIFDPointer)
            return try write(structure, to: data, format: format)
        }
    }

    // MARK: - Dump

    /// Returns a human-readable dump of all EXIF tags.
    public static func dump(from data: Data) throws -> String {
        let structure = try read(from: data)
        return dump(structure)
    }

    /// Returns a human-readable dump of a TIFFStructure.
    public static func dump(_ structure: TIFFStructure) -> String {
        var lines: [String] = []

        lines.append("=== Info ===")
        lines.append("  Byte Order: \(structure.byteOrder == .littleEndian ? "Little Endian (II)" : "Big Endian (MM)")")

        lines.append("\n=== IFD0 ===")
        for entry in structure.ifd0.entries {
            lines.append("  \(Tag.name(for: entry.tagID)) (0x\(hex(entry.tagID))): \(entry.value)")
        }

        if let exif = structure.exifIFD {
            lines.append("\n=== EXIF IFD ===")
            for entry in exif.entries {
                if entry.tagID == Tag.makerNote {
                    lines.append("  MakerNote (0x927C): [\(entry.value.count) bytes]")
                    continue
                }
                lines.append("  \(Tag.name(for: entry.tagID)) (0x\(hex(entry.tagID))): \(entry.value)")
            }
        }

        if let gps = structure.gpsIFD {
            lines.append("\n=== GPS IFD ===")
            for entry in gps.entries {
                lines.append("  \(Tag.gpsName(for: entry.tagID)) (0x\(hex(entry.tagID))): \(entry.value)")
            }
        }

        if let lat = structure.latitude, let lon = structure.longitude {
            lines.append("\n=== GPS Coordinates ===")
            lines.append("  Latitude:  \(lat)")
            lines.append("  Longitude: \(lon)")
            if let alt = structure.altitude {
                lines.append("  Altitude:  \(alt)m")
            }
        }

        lines.append("\n=== Summary ===")
        if let make = structure.make { lines.append("  Camera: \(make) \(structure.model ?? "")") }
        if let dt = structure.dateTimeOriginal { lines.append("  Date: \(dt)") }
        if let iso = structure.iso { lines.append("  ISO: \(iso)") }
        if let f = structure.fNumber { lines.append("  Aperture: f/\(String(format: "%.1f", f))") }
        if let exp = structure.exposureTime {
            if exp < 1 { lines.append("  Shutter: 1/\(Int(1.0/exp))s") }
            else { lines.append("  Shutter: \(String(format: "%.1f", exp))s") }
        }
        if let fl = structure.focalLength { lines.append("  Focal Length: \(String(format: "%.0f", fl))mm") }
        if let lens = structure.lensModel { lines.append("  Lens: \(lens)") }

        return lines.joined(separator: "\n")
    }

    private static func hex(_ value: UInt16) -> String {
        String(value, radix: 16, uppercase: true)
    }
}
