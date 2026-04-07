import Foundation

// MARK: - PNG Constants

private let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

// MARK: - PNG Chunk

/// A single PNG chunk.
///
/// PNG files are a sequence of chunks, each with:
///   - 4 bytes: data length
///   - 4 bytes: chunk type (ASCII)
///   - N bytes: chunk data
///   - 4 bytes: CRC32 checksum
private struct PNGChunk {
    let type: String
    var data: Data

    var isEXIF: Bool { type == "eXIf" }

    /// Serialize the chunk including length, type, data, and CRC
    func serialize() -> Data {
        var output = Data()

        // Length (4 bytes, big-endian)
        var length = UInt32(data.count).bigEndian
        output.append(Data(bytes: &length, count: 4))

        // Type (4 bytes ASCII)
        let typeBytes = Array(type.utf8)
        output.append(contentsOf: typeBytes)

        // Data
        output.append(data)

        // CRC32 over type + data
        var crcInput = Data(typeBytes)
        crcInput.append(data)
        var crc = CRC32.calculate(crcInput).bigEndian
        output.append(Data(bytes: &crc, count: 4))

        return output
    }
}

// MARK: - PNG Container

/// Reads and writes EXIF metadata embedded in PNG files via the eXIf chunk.
///
/// PNG structure:
/// ```
/// [8-byte signature]
/// [IHDR chunk]     <- always first
/// [other chunks]   <- eXIf goes here (before IDAT)
/// [IDAT chunks]    <- compressed image data
/// [IEND chunk]     <- always last
/// ```
///
/// The eXIf chunk (introduced in PNG 1.5) contains raw TIFF/IFD bytes,
/// identical to the JPEG APP1 payload but without the "Exif\0\0" prefix.
public struct PNGContainer {

    // MARK: - Reading

    /// Extract EXIF metadata from a PNG file.
    public static func readEXIF(from pngData: Data) throws -> TIFFStructure {
        let chunks = try parseChunks(pngData)

        guard let exifChunk = chunks.first(where: { $0.isEXIF }) else {
            throw EXIFError.invalidPNG("No eXIf chunk found")
        }

        return try TIFFParser.parse(exifChunk.data)
    }

    // MARK: - Writing

    /// Write EXIF metadata into a PNG file.
    ///
    /// If an eXIf chunk exists, it's replaced. Otherwise, one is inserted
    /// after IHDR (and any other ancillary chunks before IDAT).
    public static func writeEXIF(_ structure: TIFFStructure, to pngData: Data) throws -> Data {
        var chunks = try parseChunks(pngData)

        let tiffData = TIFFSerializer.serialize(structure)

        if let exifIndex = chunks.firstIndex(where: { $0.isEXIF }) {
            chunks[exifIndex].data = tiffData
        } else {
            // Insert before the first IDAT chunk
            let insertIndex = chunks.firstIndex(where: { $0.type == "IDAT" }) ?? chunks.endIndex
            chunks.insert(PNGChunk(type: "eXIf", data: tiffData), at: insertIndex)
        }

        return assembleChunks(chunks)
    }

    /// Remove all EXIF data from a PNG file.
    public static func stripEXIF(from pngData: Data) throws -> Data {
        var chunks = try parseChunks(pngData)
        chunks.removeAll(where: { $0.isEXIF })
        return assembleChunks(chunks)
    }

    // MARK: - Chunk Parsing

    private static func parseChunks(_ data: Data) throws -> [PNGChunk] {
        guard data.count >= 8, data.prefix(8) == pngSignature else {
            throw EXIFError.invalidPNG("Invalid PNG signature")
        }

        var chunks: [PNGChunk] = []
        var offset = 8 // Skip signature

        while offset + 12 <= data.count {
            // Length (4 bytes big-endian)
            let length = Int(
                UInt32(data[data.startIndex + offset]) << 24 |
                UInt32(data[data.startIndex + offset + 1]) << 16 |
                UInt32(data[data.startIndex + offset + 2]) << 8 |
                UInt32(data[data.startIndex + offset + 3])
            )
            offset += 4

            // Type (4 bytes ASCII)
            let typeData = data[(data.startIndex + offset)..<(data.startIndex + offset + 4)]
            let type = String(data: Data(typeData), encoding: .ascii) ?? "????"
            offset += 4

            // Data
            guard offset + length + 4 <= data.count else {
                throw EXIFError.invalidPNG("Truncated chunk '\(type)'")
            }

            let chunkData = Data(data[(data.startIndex + offset)..<(data.startIndex + offset + length)])
            offset += length

            // CRC (4 bytes — we skip validation on read, recalculate on write)
            offset += 4

            chunks.append(PNGChunk(type: type, data: chunkData))

            if type == "IEND" { break }
        }

        return chunks
    }

    private static func assembleChunks(_ chunks: [PNGChunk]) -> Data {
        var output = pngSignature
        for chunk in chunks {
            output.append(chunk.serialize())
        }
        return output
    }
}

// MARK: - CRC32

/// CRC32 implementation for PNG chunk checksums.
/// PNG uses the same CRC32 polynomial as zlib/gzip.
private enum CRC32 {
    static let table: [UInt32] = {
        (0..<256).map { n -> UInt32 in
            var c = UInt32(n)
            for _ in 0..<8 {
                if c & 1 != 0 {
                    c = 0xEDB88320 ^ (c >> 1)
                } else {
                    c = c >> 1
                }
            }
            return c
        }
    }()

    static func calculate(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xFF)
            crc = table[index] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}
