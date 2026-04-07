import Foundation

// MARK: - Canon CR3 Container

/// Reads and writes EXIF metadata from Canon CR3 RAW files.
///
/// CR3 is Canon's modern RAW format, introduced with the EOS M50 in 2018.
/// Unlike CR2 (which is TIFF-based), CR3 uses the ISO Base Media File Format
/// (ISOBMFF), the same container format as HEIF and MP4.
///
/// CR3 file structure:
/// ```
/// ftyp (file type: "crx ")
/// moov
///   uuid (Canon's UUID: 85c0b687-820f-11e0-8111-f4ce462b6a48)
///     CNCV (Canon Compressor Version)
///     CCTP (Canon CCTP)
///     CMT1 (IFD0 — TIFF-format metadata)
///     CMT2 (EXIF sub-IFD — TIFF-format)
///     CMT3 (Canon MakerNote — TIFF-format)
///     CMT4 (GPS sub-IFD — TIFF-format)
///     THMB (Thumbnail)
///   trak (preview image track)
///   trak (main image track)
///   trak (video track, if applicable)
/// mdat (raw image data)
/// ```
///
/// Each CMT box contains TIFF-format IFD data (with its own TIFF header).
/// We parse each CMT independently and combine them into a TIFFStructure.
public struct CR3Container {

    /// The Canon CR3 UUID that identifies Canon-specific metadata
    static let canonUUID = Data([
        0x85, 0xC0, 0xB6, 0x87, 0x82, 0x0F, 0x11, 0xE0,
        0x81, 0x11, 0xF4, 0xCE, 0x46, 0x2B, 0x6A, 0x48
    ])

    // MARK: - Detection

    /// Check if data is a CR3 file by looking for the "crx " file type
    public static func isCR3(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        // ftyp box starts at offset 0, type at offset 4
        let ftyp = String(data: data[data.startIndex+4..<data.startIndex+8], encoding: .ascii)
        guard ftyp == "ftyp" else { return false }
        // Major brand at offset 8
        let brand = String(data: data[data.startIndex+8..<data.startIndex+12], encoding: .ascii)
        return brand == "crx "
    }

    // MARK: - Reading

    /// Read EXIF metadata from a CR3 file.
    ///
    /// Parses the ISOBMFF structure, finds the CMT boxes, and combines
    /// their IFD data into a unified TIFFStructure.
    public static func readEXIF(from data: Data) throws -> TIFFStructure {
        let boxes = try ISOBMFFParser.parse(data)

        // Find Canon's UUID box inside moov
        guard let moov = boxes.first(where: { $0.type == "moov" }) else {
            throw EXIFError.unsupportedFormat("CR3: No moov box found")
        }

        // Find the Canon UUID box (contains CMT1-CMT4)
        let canonBox = findCanonUUIDBox(in: moov)

        // Parse each CMT box as a TIFF structure
        var byteOrder: ByteOrder = .littleEndian
        var ifd0 = IFD()
        var exifIFD: IFD? = nil
        var gpsIFD: IFD? = nil

        // CMT1: IFD0
        if let cmt1 = canonBox?.child(ofType: "CMT1") ?? findBoxRecursive("CMT1", in: [moov]) {
            if let tiff = try? TIFFParser.parse(cmt1.data) {
                ifd0 = tiff.ifd0
                byteOrder = tiff.byteOrder
            }
        }

        // CMT2: EXIF sub-IFD
        if let cmt2 = canonBox?.child(ofType: "CMT2") ?? findBoxRecursive("CMT2", in: [moov]) {
            if let tiff = try? TIFFParser.parse(cmt2.data) {
                exifIFD = tiff.ifd0 // CMT2's IFD0 IS the EXIF data
            }
        }

        // CMT4: GPS sub-IFD
        if let cmt4 = canonBox?.child(ofType: "CMT4") ?? findBoxRecursive("CMT4", in: [moov]) {
            if let tiff = try? TIFFParser.parse(cmt4.data) {
                gpsIFD = tiff.ifd0 // CMT4's IFD0 IS the GPS data
            }
        }

        // If we couldn't find any CMT boxes, try the generic ISOBMFF EXIF extraction
        if ifd0.entries.isEmpty {
            if let exifData = ISOBMFFParser.extractEXIFData(from: boxes, fileData: data) {
                return try TIFFParser.parse(exifData)
            }
            throw EXIFError.unsupportedFormat("CR3: No metadata boxes found")
        }

        return TIFFStructure(
            byteOrder: byteOrder,
            ifd0: ifd0,
            exifIFD: exifIFD,
            gpsIFD: gpsIFD
        )
    }

    // MARK: - Writing

    /// Write modified EXIF metadata back to a CR3 file.
    ///
    /// Strategy: rebuild the ISOBMFF box tree with updated CMT contents.
    /// When CMT sizes change, all parent box sizes (uuid, moov) are recalculated,
    /// and everything after moov is shifted accordingly.
    public static func writeEXIF(_ structure: TIFFStructure, to data: Data) throws -> Data {
        let boxes = try ISOBMFFParser.parse(data)

        // Build new CMT TIFF payloads
        let cmt1TIFF = TIFFSerializer.serialize(TIFFStructure(
            byteOrder: structure.byteOrder,
            ifd0: structure.ifd0
        ))

        var cmt2TIFF: Data? = nil
        if let exifIFD = structure.exifIFD {
            cmt2TIFF = TIFFSerializer.serialize(TIFFStructure(
                byteOrder: structure.byteOrder,
                ifd0: exifIFD
            ))
        }

        var cmt4TIFF: Data? = nil
        if let gpsIFD = structure.gpsIFD {
            cmt4TIFF = TIFFSerializer.serialize(TIFFStructure(
                byteOrder: structure.byteOrder,
                ifd0: gpsIFD
            ))
        }

        // Rebuild the file box by box
        var output = Data()

        for box in boxes {
            if box.type == "moov" {
                let rebuiltMoov = rebuildMoovBox(
                    moov: box,
                    originalData: data,
                    cmt1: cmt1TIFF,
                    cmt2: cmt2TIFF,
                    cmt4: cmt4TIFF
                )
                output.append(rebuiltMoov)
            } else {
                // Copy other boxes verbatim from original data
                let start = data.startIndex + box.fileOffset
                let end = start + box.totalSize
                if end <= data.endIndex {
                    output.append(data[start..<end])
                }
            }
        }

        return output
    }

    /// Rebuild the moov box, replacing CMT children with new TIFF data
    private static func rebuildMoovBox(
        moov: ISOBMFFBox,
        originalData: Data,
        cmt1: Data,
        cmt2: Data?,
        cmt4: Data?
    ) -> Data {
        var moovPayload = Data()

        for child in moov.children {
            if child.type == "uuid" && findBoxRecursive("CMT1", in: [child]) != nil {
                // This is Canon's UUID box — rebuild with new CMT data
                let rebuiltUUID = rebuildCanonUUIDBox(
                    uuidBox: child,
                    originalData: originalData,
                    cmt1: cmt1,
                    cmt2: cmt2,
                    cmt4: cmt4
                )
                moovPayload.append(rebuiltUUID)
            } else {
                // Copy other children verbatim
                let start = originalData.startIndex + child.fileOffset
                let end = start + child.totalSize
                if end <= originalData.endIndex {
                    moovPayload.append(originalData[start..<end])
                }
            }
        }

        return buildBox(type: "moov", payload: moovPayload)
    }

    /// Rebuild Canon's UUID box with updated CMT children
    private static func rebuildCanonUUIDBox(
        uuidBox: ISOBMFFBox,
        originalData: Data,
        cmt1: Data,
        cmt2: Data?,
        cmt4: Data?
    ) -> Data {
        var uuidPayload = Data()

        // UUID boxes start with 16 bytes of UUID identifier
        if uuidBox.data.count >= 16 {
            uuidPayload.append(uuidBox.data.prefix(16))
        } else {
            uuidPayload.append(canonUUID)
        }

        for child in uuidBox.children {
            switch child.type {
            case "CMT1":
                uuidPayload.append(buildBox(type: "CMT1", payload: cmt1))
            case "CMT2":
                if let cmt2 = cmt2 {
                    uuidPayload.append(buildBox(type: "CMT2", payload: cmt2))
                }
            case "CMT4":
                if let cmt4 = cmt4 {
                    uuidPayload.append(buildBox(type: "CMT4", payload: cmt4))
                }
            default:
                // Copy other children (CNCV, CCTP, CMT3/MakerNote, THMB, etc.)
                let start = originalData.startIndex + child.fileOffset
                let end = start + child.totalSize
                if end <= originalData.endIndex {
                    uuidPayload.append(originalData[start..<end])
                }
            }
        }

        // Build the uuid box (type bytes are inside the payload for uuid boxes)
        return buildBox(type: "uuid", payload: uuidPayload)
    }

    /// Build a single ISOBMFF box from type + payload
    private static func buildBox(type: String, payload: Data) -> Data {
        var box = Data()
        let totalSize = UInt32(payload.count + 8)
        var size = totalSize.bigEndian
        box.append(Data(bytes: &size, count: 4))
        let typeBytes = Array(type.utf8.prefix(4))
        box.append(contentsOf: typeBytes)
        // Pad type to 4 bytes if shorter (shouldn't happen with valid types)
        for _ in 0..<(4 - typeBytes.count) { box.append(0x20) } // space padding
        box.append(payload)
        return box
    }

    // MARK: - Stripping

    /// Strip EXIF from a CR3 file by zeroing out CMT box contents.
    public static func stripEXIF(from data: Data) throws -> Data {
        let boxes = try ISOBMFFParser.parse(data)

        var mutableData = data

        // Find all CMT boxes and zero their payloads
        for cmtType in ["CMT1", "CMT2", "CMT3", "CMT4"] {
            if let cmtBox = findBoxRecursive(cmtType, in: boxes) {
                let payloadStart = cmtBox.fileOffset + 8
                let payloadLength = cmtBox.totalSize - 8
                let start = mutableData.startIndex + payloadStart
                let end = start + payloadLength
                if end <= mutableData.endIndex {
                    let zeros = Data(count: payloadLength)
                    mutableData.replaceSubrange(start..<end, with: zeros)
                }
            }
        }

        return mutableData
    }

    // MARK: - Helpers

    private static func findCanonUUIDBox(in moov: ISOBMFFBox) -> ISOBMFFBox? {
        for child in moov.children {
            if child.type == "uuid" {
                if child.child(ofType: "CMT1") != nil {
                    return child
                }
                if child.data.count >= 16 && child.data.prefix(16) == canonUUID {
                    return child
                }
            }
        }
        return nil
    }

    private static func findBoxRecursive(_ type: String, in boxes: [ISOBMFFBox]) -> ISOBMFFBox? {
        for box in boxes {
            if box.type == type { return box }
            if let found = findBoxRecursive(type, in: box.children) { return found }
        }
        return nil
    }
}
