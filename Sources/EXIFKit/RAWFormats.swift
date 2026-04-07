import Foundation

// MARK: - TIFF-Based RAW Formats

/// Container for TIFF-based camera RAW formats.
///
/// Most camera RAW formats are TIFF derivatives. They share the same
/// byte-order marker, magic number (usually 42), and IFD structure.
/// The differences are:
///
/// - **CR2** (Canon): Standard TIFF header, magic 42, 4 IFDs.
///   IFD0 = full-size info, IFD1 = small JPEG preview,
///   IFD2 = small JPEG preview 2, IFD3 = RAW data.
///   Has a special 0xC5D8/0xC5D9 pointer for RAW IFD.
///
/// - **NEF** (Nikon): Standard TIFF header, magic 42.
///   Multiple IFDs: IFD0 = thumbnail, IFD1 = full preview,
///   IFD2+ = RAW data. Complex MakerNote with encrypted data.
///
/// - **ARW** (Sony): Standard TIFF header, magic 42.
///   IFD0 has standard EXIF, some models use SR2 sub-format.
///   Sony's MakerNote contains encrypted settings data.
///
/// - **ORF** (Olympus/OM System): Uses magic number 0x4F52 ("OR")
///   instead of 42 for newer models, or standard 42 for older ones.
///   Byte order is always big-endian for the ORF magic variant.
///
/// - **RW2** (Panasonic): Uses magic number 0x0055 instead of 42.
///   Always little-endian. IFD0 contains most metadata.
///
/// - **PEF** (Pentax): Standard TIFF header, magic 42.
///   Very close to standard TIFF. Has Pentax-specific tags and
///   MakerNote format.
///
/// For reading EXIF, all these formats work with our standard TIFF parser
/// since the EXIF data lives in standard IFD structures. The main challenge
/// is detecting the format and handling the non-standard magic numbers.
///
/// For writing, we use the same append-and-patch strategy as TIFFFileContainer
/// to avoid corrupting image data offsets.
public struct RAWContainer {

    // MARK: - Format-Specific Detection

    /// Detected RAW sub-format
    public enum RAWFormat: String, Sendable {
        case cr2    // Canon
        case nef    // Nikon
        case arw    // Sony
        case orf    // Olympus / OM System
        case rw2    // Panasonic / Lumix
        case pef    // Pentax
        case srw    // Samsung
        case genericTIFF
    }

    /// Detect the specific RAW format from file data
    public static func detectFormat(from data: Data) -> RAWFormat? {
        guard data.count >= 8 else { return nil }

        let head = [UInt8](data.prefix(12))

        // Check byte order marker
        let isLittleEndian = (head[0] == 0x49 && head[1] == 0x49)
        let isBigEndian = (head[0] == 0x4D && head[1] == 0x4D)

        guard isLittleEndian || isBigEndian else { return nil }

        // Read magic number
        let magic: UInt16
        if isLittleEndian {
            magic = UInt16(head[2]) | UInt16(head[3]) << 8
        } else {
            magic = UInt16(head[2]) << 8 | UInt16(head[3])
        }

        // RW2: magic = 0x0055
        if magic == 0x0055 {
            return .rw2
        }

        // ORF: magic = 0x4F52 ("OR") or 0x5352 ("SR") for some models
        if magic == 0x4F52 || magic == 0x5352 {
            return .orf
        }

        // Standard TIFF magic = 42
        guard magic == 42 else { return nil }

        // CR2: has "CR" at bytes 8-9 (Canon's identifier)
        if data.count >= 10 && head[8] == 0x43 && head[9] == 0x52 {
            return .cr2
        }

        // For other formats with magic 42, we need to check the Make tag
        // or use file extension. Return generic for now.
        return .genericTIFF
    }

    /// Refine the RAW format detection using the Make string from IFD0
    public static func refineFormat(
        _ initial: RAWFormat,
        make: String?,
        fileExtension: String? = nil
    ) -> RAWFormat {
        // If already a specific non-generic format, keep it
        if initial != .genericTIFF { return initial }

        // Try file extension first
        if let ext = fileExtension?.lowercased() {
            switch ext {
            case "cr2": return .cr2
            case "nef", "nrw": return .nef
            case "arw", "srf", "sr2": return .arw
            case "orf": return .orf
            case "rw2": return .rw2
            case "pef": return .pef
            case "srw": return .srw
            default: break
            }
        }

        // Try Make string
        guard let make = make?.lowercased() else { return initial }

        if make.contains("nikon")                                { return .nef }
        if make.contains("sony")                                 { return .arw }
        if make.contains("olympus") || make.contains("om digi")  { return .orf }
        if make.contains("pentax") || make.contains("ricoh")     { return .pef }
        if make.contains("panasonic") || make.contains("lumix")  { return .rw2 }
        if make.contains("samsung")                              { return .srw }
        if make.contains("canon")                                { return .cr2 }

        return initial
    }

    // MARK: - Reading

    /// Read EXIF from a TIFF-based RAW file.
    ///
    /// This handles the non-standard magic numbers (ORF, RW2) that our
    /// standard TIFFParser would reject.
    public static func readEXIF(from data: Data) throws -> TIFFStructure {
        guard let format = detectFormat(from: data) else {
            throw EXIFError.unsupportedFormat("Not a recognized TIFF-based RAW format")
        }

        switch format {
        case .orf:
            return try readORF(from: data)
        case .rw2:
            return try readRW2(from: data)
        default:
            // CR2, NEF, ARW, PEF, SRW all use standard TIFF magic 42
            return try TIFFParser.parse(data)
        }
    }

    /// Write EXIF to a TIFF-based RAW file.
    ///
    /// For formats with non-standard TIFF magic (ORF, RW2), we parse the original
    /// using our own readers and pass the result to TIFFFileContainer's internal
    /// write method, bypassing TIFFParser's magic number check.
    public static func writeEXIF(_ structure: TIFFStructure, to data: Data) throws -> Data {
        guard let format = detectFormat(from: data) else {
            throw EXIFError.unsupportedFormat("Not a recognized TIFF-based RAW format")
        }

        switch format {
        case .orf, .rw2:
            // These have non-standard magic numbers that TIFFParser.parse rejects,
            // so we parse with our own readers and use the internal write path
            let originalStructure: TIFFStructure
            if format == .orf {
                originalStructure = try readORF(from: data)
            } else {
                originalStructure = try readRW2(from: data)
            }
            return try TIFFFileContainer.writeEXIFInternal(
                structure, to: data, originalStructure: originalStructure
            )
        default:
            // CR2, NEF, ARW, PEF, SRW all use standard TIFF magic 42
            return try TIFFFileContainer.writeEXIF(structure, to: data)
        }
    }

    // MARK: - ORF (Olympus RAW Format)

    /// Olympus uses non-standard magic numbers (0x4F52 or 0x5352).
    /// We patch the magic to 42, parse as TIFF, then restore it.
    private static func readORF(from data: Data) throws -> TIFFStructure {
        guard data.count >= 8 else {
            throw EXIFError.invalidTIFFHeader
        }

        // Determine byte order
        let isLittleEndian = data[data.startIndex] == 0x49
        let byteOrder: ByteOrder = isLittleEndian ? .littleEndian : .bigEndian

        // Read IFD0 offset (bytes 4-7)
        var reader = ByteReader(data: data, byteOrder: byteOrder)
        reader.offset = 4
        let ifd0Offset = try reader.readUInt32()

        // Parse IFD0 directly (bypassing the magic number check)
        let ifd0 = try IFDReader.readIFD(from: data, at: Int(ifd0Offset), byteOrder: byteOrder)

        // Parse sub-IFDs
        var ifd1: IFD? = nil
        if ifd0.nextIFDOffset != 0 {
            ifd1 = try? IFDReader.readIFD(from: data, at: Int(ifd0.nextIFDOffset), byteOrder: byteOrder)
        }

        var exifIFD: IFD? = nil
        if let ptr = ifd0.value(for: Tag.exifIFDPointer)?.uint32Value {
            exifIFD = try? IFDReader.readIFD(from: data, at: Int(ptr), byteOrder: byteOrder)
        }

        var gpsIFD: IFD? = nil
        if let ptr = ifd0.value(for: Tag.gpsIFDPointer)?.uint32Value {
            gpsIFD = try? IFDReader.readIFD(from: data, at: Int(ptr), byteOrder: byteOrder)
        }

        return TIFFStructure(
            byteOrder: byteOrder,
            ifd0: ifd0,
            ifd1: ifd1,
            exifIFD: exifIFD,
            gpsIFD: gpsIFD
        )
    }

    // MARK: - RW2 (Panasonic RAW Format)

    /// Panasonic uses magic number 0x0055 and is always little-endian.
    private static func readRW2(from data: Data) throws -> TIFFStructure {
        guard data.count >= 8 else {
            throw EXIFError.invalidTIFFHeader
        }

        let byteOrder: ByteOrder = .littleEndian

        var reader = ByteReader(data: data, byteOrder: byteOrder)
        reader.offset = 4
        let ifd0Offset = try reader.readUInt32()

        let ifd0 = try IFDReader.readIFD(from: data, at: Int(ifd0Offset), byteOrder: byteOrder)

        var ifd1: IFD? = nil
        if ifd0.nextIFDOffset != 0 {
            ifd1 = try? IFDReader.readIFD(from: data, at: Int(ifd0.nextIFDOffset), byteOrder: byteOrder)
        }

        var exifIFD: IFD? = nil
        if let ptr = ifd0.value(for: Tag.exifIFDPointer)?.uint32Value {
            exifIFD = try? IFDReader.readIFD(from: data, at: Int(ptr), byteOrder: byteOrder)
        }

        var gpsIFD: IFD? = nil
        if let ptr = ifd0.value(for: Tag.gpsIFDPointer)?.uint32Value {
            gpsIFD = try? IFDReader.readIFD(from: data, at: Int(ptr), byteOrder: byteOrder)
        }

        return TIFFStructure(
            byteOrder: byteOrder,
            ifd0: ifd0,
            ifd1: ifd1,
            exifIFD: exifIFD,
            gpsIFD: gpsIFD
        )
    }
}
