import Foundation

// MARK: - Fujifilm RAF Container

/// Reads EXIF metadata from Fujifilm RAF (RAW) files.
///
/// RAF is Fujifilm's proprietary RAW format. Unlike most other RAW formats,
/// it is NOT TIFF-based. It has a unique structure:
///
/// ```
/// [16 bytes] Magic: "FUJIFILMCCD-RAW "
/// [4 bytes]  Format version (e.g., "0201")
/// [8 bytes]  Camera model ID
/// [32 bytes] Camera model string
/// [4 bytes]  Directory version
/// [20 bytes] Unknown
/// [4 bytes]  JPEG offset (from start of file)
/// [4 bytes]  JPEG length
/// [4 bytes]  CFA header offset
/// [4 bytes]  CFA header length
/// [4 bytes]  CFA data offset
/// [4 bytes]  CFA data length
/// ...
/// [JPEG data at JPEG offset] ← Full JPEG preview with complete EXIF!
/// [CFA header]
/// [CFA data (raw sensor data)]
/// ```
///
/// The key insight: RAF files contain an embedded JPEG preview that has
/// complete EXIF metadata including Fujifilm's MakerNote. We extract
/// EXIF by parsing this embedded JPEG.
///
/// For writing, we modify the EXIF in the embedded JPEG and write it back.
public struct RAFContainer {

    /// RAF magic string
    private static let rafMagic = "FUJIFILMCCD-RAW "

    // MARK: - Detection

    /// Check if data is a Fujifilm RAF file
    public static func isRAF(_ data: Data) -> Bool {
        guard data.count >= 16 else { return false }
        let magic = String(data: data[data.startIndex..<data.startIndex + 16], encoding: .ascii)
        return magic == rafMagic
    }

    // MARK: - Reading

    /// Read EXIF from a RAF file by extracting the embedded JPEG's EXIF data.
    public static func readEXIF(from data: Data) throws -> TIFFStructure {
        let jpegInfo = try findEmbeddedJPEG(in: data)
        let jpegData = Data(data[(data.startIndex + jpegInfo.offset)..<(data.startIndex + jpegInfo.offset + jpegInfo.length)])
        return try JPEGContainer.readEXIF(from: jpegData)
    }

    // MARK: - Writing

    /// Write modified EXIF back to a RAF file.
    ///
    /// Strategy: modify the EXIF in the embedded JPEG preview.
    /// If the new JPEG is the same size, replace in-place.
    /// If different size, rebuild the RAF header offsets.
    public static func writeEXIF(_ structure: TIFFStructure, to data: Data) throws -> Data {
        let jpegInfo = try findEmbeddedJPEG(in: data)
        let jpegData = Data(data[(data.startIndex + jpegInfo.offset)..<(data.startIndex + jpegInfo.offset + jpegInfo.length)])

        // Modify EXIF in the embedded JPEG
        let newJPEG = try JPEGContainer.writeEXIF(structure, to: jpegData)

        if newJPEG.count == jpegData.count {
            // Same size — simple in-place replacement
            var result = data
            let start = result.startIndex + jpegInfo.offset
            let end = start + jpegInfo.length
            result.replaceSubrange(start..<end, with: newJPEG)
            return result
        } else {
            // Different size — need to rebuild with adjusted offsets
            return try rebuildRAF(data: data, jpegInfo: jpegInfo, newJPEG: newJPEG)
        }
    }

    // MARK: - Helpers

    private struct JPEGInfo {
        let offset: Int
        let length: Int
    }

    /// Find the embedded JPEG in a RAF file
    private static func findEmbeddedJPEG(in data: Data) throws -> JPEGInfo {
        guard data.count >= 100 else {
            throw EXIFError.unsupportedFormat("RAF file too small")
        }

        // Verify magic
        let magic = String(data: data[data.startIndex..<data.startIndex + 16], encoding: .ascii)
        guard magic == rafMagic else {
            throw EXIFError.unsupportedFormat("Not a Fujifilm RAF file")
        }

        // JPEG offset is at byte 84 (big-endian UInt32)
        // JPEG length is at byte 88
        var reader = ByteReader(data: data, byteOrder: .bigEndian)
        try reader.seek(to: 84)
        let jpegOffset = Int(try reader.readUInt32())
        let jpegLength = Int(try reader.readUInt32())

        guard jpegOffset > 0, jpegLength > 0,
              jpegOffset + jpegLength <= data.count else {
            throw EXIFError.unsupportedFormat("RAF: Invalid JPEG offset/length")
        }

        // Verify it's actually a JPEG
        let jpegStart = data.startIndex + jpegOffset
        guard data[jpegStart] == 0xFF, data[jpegStart + 1] == 0xD8 else {
            throw EXIFError.unsupportedFormat("RAF: Embedded data is not JPEG")
        }

        return JPEGInfo(offset: jpegOffset, length: jpegLength)
    }

    /// Rebuild a RAF file with a different-sized embedded JPEG
    private static func rebuildRAF(data: Data, jpegInfo: JPEGInfo, newJPEG: Data) throws -> Data {
        var result = Data()

        // Copy header up to the JPEG
        result.append(data[data.startIndex..<data.startIndex + jpegInfo.offset])

        // Insert new JPEG
        result.append(newJPEG)

        // Copy everything after the old JPEG
        let afterOldJPEG = jpegInfo.offset + jpegInfo.length
        if afterOldJPEG < data.count {
            result.append(data[(data.startIndex + afterOldJPEG)...])
        }

        // Update JPEG length in header (offset 88, big-endian UInt32)
        let newLength = UInt32(newJPEG.count).bigEndian
        withUnsafeBytes(of: newLength) { buf in
            for i in 0..<4 {
                result[result.startIndex + 88 + i] = buf[i]
            }
        }

        // Update CFA header/data offsets if they come after the JPEG
        let sizeDiff = newJPEG.count - jpegInfo.length

        if sizeDiff != 0 {
            // CFA header offset at byte 92
            updateOffset(in: &result, at: 92, adjustment: sizeDiff, threshold: jpegInfo.offset)
            // CFA header length at byte 96 (doesn't change)
            // CFA data offset at byte 100
            updateOffset(in: &result, at: 100, adjustment: sizeDiff, threshold: jpegInfo.offset)
            // CFA data length at byte 104 (doesn't change)
        }

        return result
    }

    /// Update a big-endian UInt32 offset if it points past a threshold
    private static func updateOffset(in data: inout Data, at position: Int, adjustment: Int, threshold: Int) {
        guard position + 4 <= data.count else { return }
        let current = Int(
            UInt32(data[data.startIndex + position]) << 24 |
            UInt32(data[data.startIndex + position + 1]) << 16 |
            UInt32(data[data.startIndex + position + 2]) << 8 |
            UInt32(data[data.startIndex + position + 3])
        )
        if current > threshold {
            let newValue = UInt32(current + adjustment).bigEndian
            withUnsafeBytes(of: newValue) { buf in
                for i in 0..<4 {
                    data[data.startIndex + position + i] = buf[i]
                }
            }
        }
    }
}
