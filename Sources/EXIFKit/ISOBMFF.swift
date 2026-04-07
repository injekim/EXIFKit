import Foundation

// MARK: - ISOBMFF Box

/// A parsed ISOBMFF (ISO 14496-12) box.
///
/// ISOBMFF is a hierarchical container format used by HEIF, HEIC, MP4, CR3, etc.
/// Each "box" has:
///   - 4 bytes: size (includes the 8-byte header)
///   - 4 bytes: type (4 ASCII characters, e.g., "ftyp", "moov", "meta")
///   - If size == 1: 8 bytes extended size follows
///   - If size == 0: box extends to end of file
///   - Remaining bytes: box payload (may contain child boxes)
///
/// Some boxes are "full boxes" that have an additional 4-byte version+flags field.
public struct ISOBMFFBox: Sendable {
    /// 4-character box type (e.g., "ftyp", "moov", "meta", "uuid")
    public let type: String

    /// Raw payload data (after the header, not including children)
    public let data: Data

    /// Child boxes (if this is a container box)
    public var children: [ISOBMFFBox]

    /// Offset of this box in the original file
    public let fileOffset: Int

    /// Total size including header
    public let totalSize: Int

    /// Is this a "full box" (has version + flags)?
    public var isFullBox: Bool {
        // These box types are defined as FullBox in the spec
        ["meta", "hdlr", "pitm", "iloc", "iinf", "infe", "iprp",
         "ipco", "ispe", "colr", "iref", "idat"].contains(type)
    }

    /// For full boxes: version byte
    public var version: UInt8? {
        guard isFullBox, data.count >= 4 else { return nil }
        return data[data.startIndex]
    }

    /// For full boxes: flags (3 bytes)
    public var flags: UInt32? {
        guard isFullBox, data.count >= 4 else { return nil }
        return UInt32(data[data.startIndex + 1]) << 16 |
               UInt32(data[data.startIndex + 2]) << 8 |
               UInt32(data[data.startIndex + 3])
    }

    /// Payload data after version+flags for full boxes
    public var payloadData: Data {
        if isFullBox && data.count >= 4 {
            return Data(data.dropFirst(4))
        }
        return data
    }

    // MARK: - Child lookup

    /// Find first child box of a given type
    public func child(ofType type: String) -> ISOBMFFBox? {
        children.first(where: { $0.type == type })
    }

    /// Find all child boxes of a given type
    public func children(ofType type: String) -> [ISOBMFFBox] {
        children.filter({ $0.type == type })
    }

    /// Find a box by path (e.g., "moov/meta/iinf")
    public func find(path: String) -> ISOBMFFBox? {
        let components = path.split(separator: "/").map(String.init)
        var current: ISOBMFFBox? = self
        for component in components {
            current = current?.child(ofType: component)
        }
        return current
    }
}

// MARK: - ISOBMFF Parser

/// Parses ISO Base Media File Format (ISOBMFF) containers.
///
/// Used by:
/// - **HEIF/HEIC**: Apple's default photo format since iPhone 7
/// - **Canon CR3**: Canon's modern RAW format (EOS R series, newer DSLRs)
/// - **AVIF**: AV1 Image File Format
///
/// The parser recursively descends into known container boxes to build
/// a tree structure. Unknown boxes are preserved as opaque blobs.
public struct ISOBMFFParser {

    /// Known container box types that contain child boxes
    private static let containerTypes: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "dinf",
        "meta", "iprp", "ipco", "iref", "edts",
        "iinf",                            // Item info (FullBox + entry_count)
        "uuid",                            // 16-byte UUID prefix before children
    ]

    /// Parse an ISOBMFF file into a list of top-level boxes
    public static func parse(_ data: Data) throws -> [ISOBMFFBox] {
        return try parseBoxes(from: data, offset: 0, length: data.count, depth: 0)
    }

    /// Recursively parse boxes from a data region
    private static func parseBoxes(
        from data: Data,
        offset: Int,
        length: Int,
        depth: Int
    ) throws -> [ISOBMFFBox] {
        // Prevent infinite recursion
        guard depth < 20 else { return [] }

        var boxes: [ISOBMFFBox] = []
        var pos = offset

        while pos < offset + length {
            guard pos + 8 <= data.count else { break }

            // Read box size (4 bytes big-endian)
            let size = Int(
                UInt32(data[data.startIndex + pos]) << 24 |
                UInt32(data[data.startIndex + pos + 1]) << 16 |
                UInt32(data[data.startIndex + pos + 2]) << 8 |
                UInt32(data[data.startIndex + pos + 3])
            )

            // Read box type (4 ASCII bytes)
            let typeData = data[(data.startIndex + pos + 4)..<(data.startIndex + pos + 8)]
            let type = String(data: Data(typeData), encoding: .ascii) ?? "????"

            // Determine actual box size
            var headerSize = 8
            var boxSize: Int

            if size == 1 {
                // Extended size (8 bytes)
                guard pos + 16 <= data.count else { break }
                headerSize = 16
                let extSize = UInt64(data[data.startIndex + pos + 8]) << 56 |
                              UInt64(data[data.startIndex + pos + 9]) << 48 |
                              UInt64(data[data.startIndex + pos + 10]) << 40 |
                              UInt64(data[data.startIndex + pos + 11]) << 32 |
                              UInt64(data[data.startIndex + pos + 12]) << 24 |
                              UInt64(data[data.startIndex + pos + 13]) << 16 |
                              UInt64(data[data.startIndex + pos + 14]) << 8 |
                              UInt64(data[data.startIndex + pos + 15])
                boxSize = Int(extSize)
            } else if size == 0 {
                // Box extends to end of data
                boxSize = (offset + length) - pos
            } else {
                boxSize = size
            }

            guard boxSize >= headerSize else { break }
            if pos + boxSize > data.count {
                // Truncated box — take what we can
                boxSize = data.count - pos
            }

            // Extract payload
            let payloadStart = pos + headerSize
            let payloadLength = boxSize - headerSize
            let payloadData: Data

            if payloadLength > 0 && payloadStart + payloadLength <= data.count {
                payloadData = Data(data[(data.startIndex + payloadStart)..<(data.startIndex + payloadStart + payloadLength)])
            } else {
                payloadData = Data()
            }

            // Recursively parse children for container boxes
            var children: [ISOBMFFBox] = []
            if containerTypes.contains(type) && payloadLength > 8 {
                // Different box types have different prefixes before child boxes
                let skipBytes: Int
                if type == "meta" || type == "iref" {
                    // FullBox: skip version(1) + flags(3)
                    skipBytes = 4
                } else if type == "iinf" {
                    // FullBox + entry_count(2): skip version(1) + flags(3) + count(2)
                    skipBytes = 6
                } else if type == "uuid" {
                    // UUID identifier prefix (16 bytes) before child boxes
                    skipBytes = 16
                } else {
                    skipBytes = 0
                }

                if payloadLength > skipBytes + 8 {
                    let childOffset = payloadStart + skipBytes
                    let childLength = payloadLength - skipBytes
                    children = (try? parseBoxes(from: data, offset: childOffset, length: childLength, depth: depth + 1)) ?? []
                }
            }

            let box = ISOBMFFBox(
                type: type,
                data: payloadData,
                children: children,
                fileOffset: pos,
                totalSize: boxSize
            )
            boxes.append(box)

            pos += boxSize
        }

        return boxes
    }

    // MARK: - EXIF Extraction from ISOBMFF

    /// Extract EXIF data from an ISOBMFF container.
    ///
    /// EXIF in ISOBMFF is typically stored in one of these locations:
    /// - `meta/iinf` + `meta/iloc` → locate the Exif item → read TIFF data
    /// - Canon CR3: `moov/uuid/CMT1` (IFD0), `CMT2` (EXIF), `CMT3` (MakerNote), `CMT4` (GPS)
    ///
    /// Returns the raw TIFF data block if found.
    public static func extractEXIFData(from boxes: [ISOBMFFBox], fileData: Data) -> Data? {
        // Strategy 1: Look for Exif item in meta box (HEIF style)
        if let exifData = extractFromMetaBox(boxes: boxes, fileData: fileData) {
            return exifData
        }

        // Strategy 2: Look for Canon CR3 metadata boxes
        if let exifData = extractFromCR3(boxes: boxes, fileData: fileData) {
            return exifData
        }

        return nil
    }

    /// HEIF-style: find the Exif item through meta/iloc
    private static func extractFromMetaBox(boxes: [ISOBMFFBox], fileData: Data) -> Data? {
        // Find top-level meta box
        guard let meta = boxes.first(where: { $0.type == "meta" }) else { return nil }

        // Look for 'Exif' item in iinf (item info)
        guard let iloc = meta.child(ofType: "iloc") else { return nil }

        // Parse iloc to find item locations
        // iloc is a FullBox: version(1) + flags(3) are in the box data prefix,
        // which payloadData already strips. We read version from the box directly.
        let ilocData = iloc.payloadData
        guard ilocData.count >= 4 else { return nil }

        let ilocVersion = iloc.version ?? 0
        let offsetSize = Int((ilocData[ilocData.startIndex] >> 4) & 0x0F)
        let lengthSize = Int(ilocData[ilocData.startIndex] & 0x0F)
        let baseOffsetSize = Int((ilocData[ilocData.startIndex + 1] >> 4) & 0x0F)

        var reader = ByteReader(data: Data(ilocData), byteOrder: .bigEndian)
        // Byte 0: offset_size(4) | length_size(4)
        // Byte 1: base_offset_size(4) | index_size(4) [index_size only in version >= 1, else reserved]
        // Byte 2+: item_count
        reader.offset = 2

        let itemCount: Int
        if ilocVersion < 2 {
            itemCount = Int((try? reader.readUInt16()) ?? 0)
        } else {
            itemCount = Int((try? reader.readUInt32()) ?? 0)
        }

        // Find the Exif item ID from iinf
        let exifItemID = findExifItemID(in: meta)

        // Scan iloc entries to find the Exif item's offset and length
        for _ in 0..<itemCount {
            let itemID: UInt32
            if ilocVersion < 2 {
                itemID = UInt32((try? reader.readUInt16()) ?? 0)
            } else {
                itemID = (try? reader.readUInt32()) ?? 0
            }

            // Construction method (version >= 1)
            if ilocVersion >= 1 {
                _ = try? reader.readUInt16() // construction_method
            }

            _ = try? reader.readUInt16() // data_reference_index

            // Base offset
            let baseOffset: UInt64
            switch baseOffsetSize {
            case 4: baseOffset = UInt64((try? reader.readUInt32()) ?? 0)
            case 8:
                let hi = UInt64((try? reader.readUInt32()) ?? 0)
                let lo = UInt64((try? reader.readUInt32()) ?? 0)
                baseOffset = (hi << 32) | lo
            default: baseOffset = 0
            }

            let extentCount = Int((try? reader.readUInt16()) ?? 0)

            for _ in 0..<extentCount {
                let extentOffset: UInt64
                switch offsetSize {
                case 4: extentOffset = UInt64((try? reader.readUInt32()) ?? 0)
                case 8:
                    let hi = UInt64((try? reader.readUInt32()) ?? 0)
                    let lo = UInt64((try? reader.readUInt32()) ?? 0)
                    extentOffset = (hi << 32) | lo
                default: extentOffset = 0
                }

                let extentLength: UInt64
                switch lengthSize {
                case 4: extentLength = UInt64((try? reader.readUInt32()) ?? 0)
                case 8:
                    let hi = UInt64((try? reader.readUInt32()) ?? 0)
                    let lo = UInt64((try? reader.readUInt32()) ?? 0)
                    extentLength = (hi << 32) | lo
                default: extentLength = 0
                }

                if itemID == exifItemID || exifItemID == 0 {
                    let start = Int(baseOffset + extentOffset)
                    let length = Int(extentLength)
                    if start >= 0 && start + length <= fileData.count && length > 8 {
                        var exifData = Data(fileData[(fileData.startIndex + start)..<(fileData.startIndex + start + length)])

                        // HEIF EXIF items may have a 4-byte prefix (Exif offset)
                        // followed by "Exif\0\0" + TIFF data, or just TIFF data
                        if exifData.count > 10 {
                            // Check for "Exif\0\0" header
                            let possibleExif = exifData.prefix(10)
                            if let str = String(data: Data(possibleExif.dropFirst(4).prefix(4)), encoding: .ascii),
                               str == "Exif" {
                                // Skip 4-byte offset prefix + 6 bytes "Exif\0\0"
                                exifData = Data(exifData.dropFirst(10))
                            } else if possibleExif[possibleExif.startIndex] == 0x45 &&
                                      possibleExif[possibleExif.startIndex + 1] == 0x78 {
                                // Starts with "Ex" — skip "Exif\0\0"
                                exifData = Data(exifData.dropFirst(6))
                            }
                            // Check if it starts with TIFF header
                            let b0 = exifData[exifData.startIndex]
                            let b1 = exifData[exifData.startIndex + 1]
                            if (b0 == 0x49 && b1 == 0x49) || (b0 == 0x4D && b1 == 0x4D) {
                                return exifData
                            }
                        }
                    }
                }
            }
        }

        return nil
    }

    /// Find the item ID of the "Exif" item from the iinf box
    private static func findExifItemID(in meta: ISOBMFFBox) -> UInt32 {
        guard let iinf = meta.child(ofType: "iinf") else { return 0 }

        // Each infe box describes an item
        for infe in iinf.children(ofType: "infe") {
            let infeData = infe.payloadData
            guard infeData.count >= 8 else { continue }

            // Version 2+: item_id(2) + item_protection_index(2) + item_type(4)
            var reader = ByteReader(data: Data(infeData), byteOrder: .bigEndian)
            let itemID = (try? reader.readUInt16()) ?? 0
            _ = try? reader.readUInt16() // protection index
            let typeBytes = (try? reader.readBytes(4)) ?? Data()
            let itemType = String(data: typeBytes, encoding: .ascii) ?? ""

            if itemType == "Exif" {
                return UInt32(itemID)
            }
        }

        return 0
    }

    /// Canon CR3: extract TIFF data from CMT boxes
    private static func extractFromCR3(boxes: [ISOBMFFBox], fileData: Data) -> Data? {
        // CR3 stores metadata in moov/uuid/ with Canon-specific boxes:
        // CMT1 = IFD0 (TIFF header + IFD)
        // CMT2 = EXIF IFD
        // CMT3 = Canon MakerNote
        // CMT4 = GPS IFD
        //
        // Each CMT box contains raw TIFF-format IFD data.
        // CMT1 is the primary one that acts as a standard TIFF structure.

        for box in boxes {
            if box.type == "moov" {
                // Search through moov's children for uuid boxes containing CMT data
                for child in box.children {
                    if child.type == "uuid" {
                        // Look for CMT1 in uuid children
                        if let cmt1 = child.child(ofType: "CMT1") {
                            return cmt1.data
                        }
                        // Also check nested structures
                        for grandchild in child.children {
                            if let cmt1 = grandchild.child(ofType: "CMT1") {
                                return cmt1.data
                            }
                        }
                    }
                }
            }
        }

        // Direct search at any level
        return findBoxRecursive(type: "CMT1", in: boxes)?.data
    }

    /// Recursively search for a box type
    private static func findBoxRecursive(type: String, in boxes: [ISOBMFFBox]) -> ISOBMFFBox? {
        for box in boxes {
            if box.type == type { return box }
            if let found = findBoxRecursive(type: type, in: box.children) {
                return found
            }
        }
        return nil
    }
}
