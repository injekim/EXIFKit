import Foundation

// MARK: - JPEG Marker Constants

/// JPEG files are a sequence of marker segments.
/// Each marker is 0xFF followed by a type byte.
private enum JPEGMarker {
    static let prefix:  UInt8 = 0xFF
    static let soi:     UInt8 = 0xD8  // Start of Image
    static let eoi:     UInt8 = 0xD9  // End of Image
    static let app0:    UInt8 = 0xE0  // JFIF
    static let app1:    UInt8 = 0xE1  // EXIF / XMP
    static let sos:     UInt8 = 0xDA  // Start of Scan (image data follows)
}

/// The 6-byte header that identifies an EXIF APP1 segment: "Exif\0\0"
private let exifHeader = Data([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])

// MARK: - JPEG Container

/// Reads and writes EXIF metadata embedded in JPEG files.
///
/// JPEG structure (simplified):
/// ```
/// FF D8              <- SOI (Start of Image)
/// FF E1 [len] [data] <- APP1 (EXIF) — this is what we care about
/// FF E0 [len] [data] <- APP0 (JFIF) — we preserve this
/// ...other markers...
/// FF DA [len] [data] <- SOS + compressed image data
/// FF D9              <- EOI (End of Image)
/// ```
///
/// Our strategy for writing:
/// 1. Parse all marker segments into an ordered list
/// 2. Find or create the EXIF APP1 segment
/// 3. Rebuild the JPEG with the modified APP1
///
/// This preserves all non-EXIF data (image pixels, JFIF, ICC profiles, etc.).
public struct JPEGContainer {

    /// A parsed JPEG marker segment
    struct MarkerSegment {
        let marker: UInt8
        var data: Data  // everything after the 2-byte length field

        /// Is this an EXIF APP1 segment?
        var isEXIF: Bool {
            marker == JPEGMarker.app1 && data.count >= 6 && data.prefix(6) == exifHeader
        }
    }

    // MARK: - Reading

    /// Extract EXIF metadata from JPEG file data.
    ///
    /// - Parameter jpegData: The raw JPEG file bytes
    /// - Returns: Parsed TIFF structure containing all EXIF data
    public static func readEXIF(from jpegData: Data) throws -> TIFFStructure {
        let segments = try parseSegments(jpegData)

        guard let exifSegment = segments.first(where: { $0.isEXIF }) else {
            throw EXIFError.invalidJPEG("No EXIF APP1 segment found")
        }

        // The TIFF data starts after the 6-byte "Exif\0\0" header
        let tiffData = exifSegment.data.dropFirst(6)
        return try TIFFParser.parse(Data(tiffData))
    }

    // MARK: - Writing

    /// Write modified EXIF metadata back into a JPEG file.
    ///
    /// - Parameters:
    ///   - structure: The (possibly modified) TIFF structure
    ///   - jpegData: The original JPEG file data
    /// - Returns: New JPEG file data with updated EXIF
    public static func writeEXIF(_ structure: TIFFStructure, to jpegData: Data) throws -> Data {
        var segments = try parseSegments(jpegData)

        // Build the new APP1 payload: "Exif\0\0" + TIFF data
        let tiffData = TIFFSerializer.serialize(structure)
        var app1Payload = exifHeader
        app1Payload.append(tiffData)

        // Find existing EXIF segment and replace it, or insert after SOI
        if let exifIndex = segments.firstIndex(where: { $0.isEXIF }) {
            segments[exifIndex].data = app1Payload
        } else {
            // Insert as the first segment (after SOI, before everything else)
            let newSegment = MarkerSegment(marker: JPEGMarker.app1, data: app1Payload)
            segments.insert(newSegment, at: 0)
        }

        return assembleJPEG(segments: segments, originalData: jpegData)
    }

    /// Remove all EXIF data from a JPEG file.
    public static func stripEXIF(from jpegData: Data) throws -> Data {
        var segments = try parseSegments(jpegData)
        segments.removeAll(where: { $0.isEXIF })
        return assembleJPEG(segments: segments, originalData: jpegData)
    }

    // MARK: - Segment Parsing

    /// Parse a JPEG file into its component marker segments.
    ///
    /// This extracts all segments BEFORE the SOS marker.
    /// Everything from SOS onward (the actual image data) is treated as a
    /// single opaque blob that we pass through untouched.
    private static func parseSegments(_ data: Data) throws -> [MarkerSegment] {
        guard data.count >= 4 else {
            throw EXIFError.invalidJPEG("File too small")
        }

        // Verify SOI
        guard data[data.startIndex] == JPEGMarker.prefix,
              data[data.startIndex + 1] == JPEGMarker.soi else {
            throw EXIFError.invalidJPEG("Missing SOI marker")
        }

        var segments: [MarkerSegment] = []
        var offset = 2 // Skip SOI

        while offset < data.count - 1 {
            // Find next marker
            guard data[data.startIndex + offset] == JPEGMarker.prefix else {
                throw EXIFError.invalidJPEG("Expected marker at offset \(offset)")
            }

            let markerType = data[data.startIndex + offset + 1]
            offset += 2

            // SOS marks the beginning of compressed image data — stop parsing
            if markerType == JPEGMarker.sos {
                break
            }

            // Skip standalone markers (no length field)
            if markerType == JPEGMarker.soi || markerType == JPEGMarker.eoi {
                continue
            }

            // Markers 0xFF00–0xFFFF with 0xD0-0xD7 (RST markers) are also standalone
            if markerType >= 0xD0 && markerType <= 0xD7 {
                continue
            }

            // Read segment length (2 bytes, big-endian, includes the 2 length bytes)
            guard offset + 2 <= data.count else {
                throw EXIFError.invalidJPEG("Truncated segment length at offset \(offset)")
            }

            let length = Int(data[data.startIndex + offset]) << 8 | Int(data[data.startIndex + offset + 1])
            offset += 2

            guard length >= 2 else {
                throw EXIFError.invalidJPEG("Invalid segment length \(length) at offset \(offset)")
            }

            let payloadLength = length - 2
            guard offset + payloadLength <= data.count else {
                throw EXIFError.invalidJPEG("Segment data exceeds file size")
            }

            let segmentData = data[(data.startIndex + offset)..<(data.startIndex + offset + payloadLength)]
            segments.append(MarkerSegment(marker: markerType, data: Data(segmentData)))
            offset += payloadLength
        }

        return segments
    }

    /// Reassemble a JPEG file from segments + the original SOS/image data.
    ///
    /// We reconstruct the header segments and append the original image data
    /// (everything from SOS onward) unchanged.
    private static func assembleJPEG(segments: [MarkerSegment], originalData: Data) -> Data {
        var output = Data()

        // SOI
        output.append(JPEGMarker.prefix)
        output.append(JPEGMarker.soi)

        // All header segments
        for segment in segments {
            output.append(JPEGMarker.prefix)
            output.append(segment.marker)
            // Length = payload size + 2 (for the length field itself)
            // JPEG segment lengths are UInt16, max 65535. Segments exceeding
            // this would need to be split, but EXIF data rarely exceeds 64KB.
            let rawLength = segment.data.count + 2
            let length = UInt16(clamping: rawLength)
            output.append(UInt8(length >> 8))
            output.append(UInt8(length & 0xFF))
            output.append(segment.data)
        }

        // Find SOS in original data and append everything from there
        if let sosOffset = findSOS(in: originalData) {
            output.append(originalData[sosOffset...])
        }

        return output
    }

    /// Find the byte offset of the SOS marker in JPEG data
    private static func findSOS(in data: Data) -> Data.Index? {
        var i = data.startIndex + 2 // skip SOI
        while i < data.endIndex - 1 {
            if data[i] == JPEGMarker.prefix && data[i + 1] == JPEGMarker.sos {
                return i
            }
            if data[i] == JPEGMarker.prefix {
                let markerType = data[i + 1]
                // Skip standalone markers
                if markerType >= 0xD0 && markerType <= 0xD9 {
                    i += 2
                    continue
                }
                // Skip segment by reading its length
                if i + 3 < data.endIndex {
                    let length = Int(data[i + 2]) << 8 | Int(data[i + 3])
                    i += 2 + length
                    continue
                }
            }
            i += 1
        }
        return nil
    }
}
