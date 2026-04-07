import Foundation

// MARK: - HEIF/HEIC Container

/// Reads and writes EXIF metadata from HEIF/HEIC image files.
///
/// HEIF (High Efficiency Image File Format) uses the ISOBMFF container.
/// Apple adopted it as the default photo format starting with iOS 11 / iPhone 7.
///
/// HEIF file structure:
/// ```
/// ftyp (file type: "heic", "heix", "hevc", "mif1")
/// meta (FullBox)
///   hdlr (handler: "pict")
///   pitm (primary item ID)
///   iloc (item locations — offsets to actual data)
///   iinf (item info — describes each item)
///     infe (item info entry: "Exif", "hvc1", "grid", etc.)
///   iprp (item properties)
///     ipco (property container)
///       ispe (image spatial extents — width/height)
///       colr (color info)
///       hvcC (HEVC config)
///     ipma (property-to-item associations)
///   iref (item references)
/// mdat (media data — actual image pixels + EXIF blob)
/// ```
///
/// EXIF is stored as a separate "item" in the file:
/// 1. An `infe` box in `meta/iinf` identifies an item of type "Exif"
/// 2. The `iloc` box gives the offset and length of that item in `mdat`
/// 3. The item data is: 4-byte TIFF offset prefix + "Exif\0\0" + TIFF data
///    OR just raw TIFF data (varies by encoder)
public struct HEIFContainer {

    // MARK: - Detection

    /// Known HEIF/HEIC file type brands
    private static let heifBrands: Set<String> = [
        "heic",  // HEVC-coded images (Apple's default)
        "heix",  // HEVC extended
        "hevc",  // HEVC
        "hevx",  // HEVC extended
        "heim",  // HEVC multi-image
        "heis",  // HEVC scalable
        "mif1",  // Generic HEIF
        "msf1",  // HEIF sequence
        "avif",  // AV1 Image (uses same ISOBMFF container)
        "avis",  // AV1 sequence
    ]

    /// Check if data is a HEIF/HEIC file
    public static func isHEIF(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let ftyp = String(data: data[data.startIndex+4..<data.startIndex+8], encoding: .ascii)
        guard ftyp == "ftyp" else { return false }

        // Check major brand
        let brand = String(data: data[data.startIndex+8..<data.startIndex+12], encoding: .ascii) ?? ""
        if heifBrands.contains(brand) { return true }

        // Also check compatible brands (starting at offset 16, each 4 bytes)
        // Read ftyp box size first
        let boxSize = Int(
            UInt32(data[data.startIndex]) << 24 |
            UInt32(data[data.startIndex + 1]) << 16 |
            UInt32(data[data.startIndex + 2]) << 8 |
            UInt32(data[data.startIndex + 3])
        )

        var offset = 16 // Skip size(4) + type(4) + major_brand(4) + minor_version(4)
        while offset + 4 <= min(boxSize, data.count) {
            let compat = String(data: data[(data.startIndex + offset)..<(data.startIndex + offset + 4)], encoding: .ascii) ?? ""
            if heifBrands.contains(compat) { return true }
            offset += 4
        }

        return false
    }

    // MARK: - Reading

    /// Read EXIF metadata from a HEIF/HEIC file.
    public static func readEXIF(from data: Data) throws -> TIFFStructure {
        let boxes = try ISOBMFFParser.parse(data)

        // Try to extract EXIF data from the ISOBMFF structure
        if let exifData = ISOBMFFParser.extractEXIFData(from: boxes, fileData: data) {
            return try TIFFParser.parse(exifData)
        }

        // Fallback: scan for TIFF header in mdat
        if let tiffData = scanForTIFFInMdat(boxes: boxes, fileData: data) {
            return try TIFFParser.parse(tiffData)
        }

        throw EXIFError.unsupportedFormat("HEIF: No EXIF data found")
    }

    // MARK: - Writing

    /// Write modified EXIF metadata back to a HEIF/HEIC file.
    ///
    /// HEIF writing is complex because:
    /// 1. EXIF data is stored as an item in mdat
    /// 2. Changing its size requires updating iloc offsets
    /// 3. It may also require updating iinf item sizes
    /// 4. Other items in mdat may shift if the EXIF item size changes
    ///
    /// Current strategy: in-place replacement when the new EXIF data
    /// fits in the same space, with zero-padding for smaller data.
    /// For larger data, we append to the end and update iloc.
    public static func writeEXIF(_ structure: TIFFStructure, to data: Data) throws -> Data {
        let boxes = try ISOBMFFParser.parse(data)

        // Find the existing EXIF item location
        guard let meta = boxes.first(where: { $0.type == "meta" }),
              let iloc = meta.child(ofType: "iloc") else {
            throw EXIFError.unsupportedFormat("HEIF: Cannot write — no meta/iloc box found")
        }

        // Build new TIFF data
        let newTIFF = TIFFSerializer.serialize(structure)

        // Build the complete EXIF item: 4-byte prefix + "Exif\0\0" + TIFF
        var newExifItem = Data()
        // The 4-byte prefix is the offset from the start of the item to the TIFF header
        // Typically 6 (length of "Exif\0\0")
        var exifPrefix: UInt32 = 6
        newExifItem.append(Data(bytes: &exifPrefix, count: 4))
        newExifItem.append(contentsOf: [0x45, 0x78, 0x69, 0x66, 0x00, 0x00]) // "Exif\0\0"
        newExifItem.append(newTIFF)

        // Find the EXIF item's location in the file
        guard let exifLocation = findExifItemLocation(meta: meta, iloc: iloc) else {
            throw EXIFError.unsupportedFormat("HEIF: Cannot locate EXIF item for writing")
        }

        var mutableData = data

        if newExifItem.count <= exifLocation.length {
            // In-place replacement (pad with zeros)
            let start = mutableData.startIndex + exifLocation.offset
            let end = start + exifLocation.length
            var padded = newExifItem
            padded.append(Data(count: exifLocation.length - newExifItem.count))
            mutableData.replaceSubrange(start..<end, with: padded)
        } else {
            // Append strategy: add new EXIF at end of file, update iloc
            // This is a simplified approach — a full implementation would
            // rebuild the iloc box with updated offsets
            let appendOffset = mutableData.count
            mutableData.append(newExifItem)

            // Try to patch iloc in place (update the offset for the EXIF item)
            // This requires finding the exact iloc entry bytes and rewriting them
            patchIlocOffset(
                in: &mutableData,
                meta: meta,
                iloc: iloc,
                itemID: exifLocation.itemID,
                newOffset: UInt64(appendOffset),
                newLength: UInt64(newExifItem.count)
            )
        }

        return mutableData
    }

    /// Strip EXIF from a HEIF file by zeroing out the EXIF item data
    public static func stripEXIF(from data: Data) throws -> Data {
        let boxes = try ISOBMFFParser.parse(data)

        guard let meta = boxes.first(where: { $0.type == "meta" }),
              let iloc = meta.child(ofType: "iloc") else {
            throw EXIFError.unsupportedFormat("HEIF: Cannot strip — no meta/iloc box found")
        }

        guard let exifLocation = findExifItemLocation(meta: meta, iloc: iloc) else {
            // No EXIF to strip
            return data
        }

        var mutableData = data
        let start = mutableData.startIndex + exifLocation.offset
        let end = start + exifLocation.length
        let zeros = Data(count: exifLocation.length)
        mutableData.replaceSubrange(start..<end, with: zeros)

        return mutableData
    }

    // MARK: - Helpers

    private struct ExifItemLocation {
        let itemID: UInt32
        let offset: Int
        let length: Int
    }

    /// Find the EXIF item's byte offset and length in the file
    private static func findExifItemLocation(
        meta: ISOBMFFBox,
        iloc: ISOBMFFBox
    ) -> ExifItemLocation? {
        // Find EXIF item ID from iinf
        let exifItemID = findExifItemID(in: meta)
        guard exifItemID != 0 else { return nil }

        // Parse iloc to find offset/length
        // payloadData already strips the 4-byte version+flags for FullBoxes,
        // so byte 0 is the offset_size/length_size field, not the version.
        let ilocData = iloc.payloadData
        guard ilocData.count >= 4 else { return nil }

        let ilocVersion = iloc.version ?? 0
        let offsetSize = Int((ilocData[ilocData.startIndex] >> 4) & 0x0F)
        let lengthSize = Int(ilocData[ilocData.startIndex] & 0x0F)
        let baseOffsetSize = Int((ilocData[ilocData.startIndex + 1] >> 4) & 0x0F)

        var reader = ByteReader(data: Data(ilocData), byteOrder: .bigEndian)
        reader.offset = 2 // skip the two size-fields bytes

        let itemCount: Int
        if ilocVersion < 2 {
            itemCount = Int((try? reader.readUInt16()) ?? 0)
        } else {
            itemCount = Int((try? reader.readUInt32()) ?? 0)
        }

        for _ in 0..<itemCount {
            let itemID: UInt32
            if ilocVersion < 2 {
                itemID = UInt32((try? reader.readUInt16()) ?? 0)
            } else {
                itemID = (try? reader.readUInt32()) ?? 0
            }

            if ilocVersion >= 1 { _ = try? reader.readUInt16() }
            _ = try? reader.readUInt16() // data_reference_index

            let baseOffset: Int
            switch baseOffsetSize {
            case 4: baseOffset = Int((try? reader.readUInt32()) ?? 0)
            case 8:
                let hi = UInt64((try? reader.readUInt32()) ?? 0)
                let lo = UInt64((try? reader.readUInt32()) ?? 0)
                baseOffset = Int((hi << 32) | lo)
            default: baseOffset = 0
            }

            let extentCount = Int((try? reader.readUInt16()) ?? 0)

            for _ in 0..<extentCount {
                let extOffset: Int
                switch offsetSize {
                case 4: extOffset = Int((try? reader.readUInt32()) ?? 0)
                case 8:
                    let hi = UInt64((try? reader.readUInt32()) ?? 0)
                    let lo = UInt64((try? reader.readUInt32()) ?? 0)
                    extOffset = Int((hi << 32) | lo)
                default: extOffset = 0
                }

                let extLength: Int
                switch lengthSize {
                case 4: extLength = Int((try? reader.readUInt32()) ?? 0)
                case 8:
                    let hi = UInt64((try? reader.readUInt32()) ?? 0)
                    let lo = UInt64((try? reader.readUInt32()) ?? 0)
                    extLength = Int((hi << 32) | lo)
                default: extLength = 0
                }

                if itemID == exifItemID {
                    return ExifItemLocation(
                        itemID: itemID,
                        offset: baseOffset + extOffset,
                        length: extLength
                    )
                }
            }
        }

        return nil
    }

    /// Find the EXIF item ID from iinf
    private static func findExifItemID(in meta: ISOBMFFBox) -> UInt32 {
        guard let iinf = meta.child(ofType: "iinf") else { return 0 }
        for infe in iinf.children(ofType: "infe") {
            let pd = infe.payloadData
            guard pd.count >= 8 else { continue }
            var reader = ByteReader(data: Data(pd), byteOrder: .bigEndian)
            let itemID = (try? reader.readUInt16()) ?? 0
            _ = try? reader.readUInt16()
            let typeBytes = (try? reader.readBytes(4)) ?? Data()
            if String(data: typeBytes, encoding: .ascii) == "Exif" {
                return UInt32(itemID)
            }
        }
        return 0
    }

    /// Scan mdat for a TIFF header (fallback when iloc parsing fails)
    private static func scanForTIFFInMdat(boxes: [ISOBMFFBox], fileData: Data) -> Data? {
        guard let mdat = boxes.first(where: { $0.type == "mdat" }) else { return nil }

        let mdatStart = mdat.fileOffset + 8
        let mdatEnd = mdat.fileOffset + mdat.totalSize

        guard mdatEnd <= fileData.count else { return nil }

        // Scan for TIFF header ("II\x2A\x00" or "MM\x00\x2A")
        var offset = mdatStart
        while offset < mdatEnd - 8 {
            let b0 = fileData[fileData.startIndex + offset]
            let b1 = fileData[fileData.startIndex + offset + 1]

            if (b0 == 0x49 && b1 == 0x49) || (b0 == 0x4D && b1 == 0x4D) {
                // Check magic number
                let magic: UInt16
                if b0 == 0x49 {
                    magic = UInt16(fileData[fileData.startIndex + offset + 2]) |
                            UInt16(fileData[fileData.startIndex + offset + 3]) << 8
                } else {
                    magic = UInt16(fileData[fileData.startIndex + offset + 2]) << 8 |
                            UInt16(fileData[fileData.startIndex + offset + 3])
                }

                if magic == 42 {
                    // Found TIFF header — extract up to end of mdat
                    let tiffLength = min(mdatEnd - offset, 65536) // Cap at 64KB for EXIF
                    let start = fileData.startIndex + offset
                    return Data(fileData[start..<start + tiffLength])
                }
            }

            // Also check for "Exif\0\0" prefix
            if b0 == 0x45 && b1 == 0x78 {
                let exifStr = String(data: Data(fileData[(fileData.startIndex + offset)..<(fileData.startIndex + offset + 4)]), encoding: .ascii)
                if exifStr == "Exif" {
                    let tiffStart = offset + 6
                    let tiffLength = min(mdatEnd - tiffStart, 65536)
                    if tiffStart + tiffLength <= fileData.count {
                        let start = fileData.startIndex + tiffStart
                        return Data(fileData[start..<start + tiffLength])
                    }
                }
            }

            offset += 1
        }

        return nil
    }

    /// Patch iloc offset and length for a specific item in-place.
    ///
    /// This scans the iloc box bytes in the file to find the entry matching
    /// the target item ID, then overwrites the offset and length fields directly.
    private static func patchIlocOffset(
        in data: inout Data,
        meta: ISOBMFFBox,
        iloc: ISOBMFFBox,
        itemID: UInt32,
        newOffset: UInt64,
        newLength: UInt64
    ) {
        let ilocData = iloc.payloadData
        guard ilocData.count >= 4 else { return }

        let ilocVersion = iloc.version ?? 0
        let offsetSize = Int((ilocData[ilocData.startIndex] >> 4) & 0x0F)
        let lengthSize = Int(ilocData[ilocData.startIndex] & 0x0F)
        let baseOffsetSize = Int((ilocData[ilocData.startIndex + 1] >> 4) & 0x0F)

        // We need the iloc box's position in the file to patch bytes
        // iloc is a child of meta, which is a FullBox.
        // The iloc payload starts after: meta box header + meta version/flags(4) +
        // ... child boxes before iloc. We use iloc.fileOffset directly.
        let ilocPayloadFileOffset: Int
        if iloc.isFullBox {
            ilocPayloadFileOffset = iloc.fileOffset + 8 + 4 // box header + version/flags
        } else {
            ilocPayloadFileOffset = iloc.fileOffset + 8
        }

        // Parse iloc structure to find the byte positions of our target item's fields
        // payloadData byte layout: [offset/length sizes (1)] [base_offset/index sizes (1)] [item_count (2 or 4)] [items...]
        var reader = ByteReader(data: Data(ilocData), byteOrder: .bigEndian)
        reader.offset = 2 // skip the two size-fields bytes

        let itemCount: Int
        if ilocVersion < 2 {
            itemCount = Int((try? reader.readUInt16()) ?? 0)
        } else {
            itemCount = Int((try? reader.readUInt32()) ?? 0)
        }

        for _ in 0..<itemCount {
            let thisItemID: UInt32
            if ilocVersion < 2 {
                thisItemID = UInt32((try? reader.readUInt16()) ?? 0)
            } else {
                thisItemID = (try? reader.readUInt32()) ?? 0
            }

            if ilocVersion >= 1 {
                _ = try? reader.readUInt16() // construction_method
            }
            _ = try? reader.readUInt16() // data_reference_index

            // Skip base_offset
            reader.offset += baseOffsetSize

            let extentCount = Int((try? reader.readUInt16()) ?? 0)

            for extIdx in 0..<extentCount {
                let extentOffsetPos = reader.offset

                // Skip extent offset
                reader.offset += offsetSize

                let extentLengthPos = reader.offset

                // Skip extent length
                reader.offset += lengthSize

                if thisItemID == itemID && extIdx == 0 {
                    // Patch the extent offset and length in the file data
                    let fileExtentOffsetPos = ilocPayloadFileOffset + extentOffsetPos

                    // Write new offset
                    if offsetSize == 4 && fileExtentOffsetPos + 4 <= data.count {
                        let val = UInt32(newOffset).bigEndian
                        withUnsafeBytes(of: val) { buf in
                            for i in 0..<4 {
                                data[data.startIndex + fileExtentOffsetPos + i] = buf[i]
                            }
                        }
                    } else if offsetSize == 8 && fileExtentOffsetPos + 8 <= data.count {
                        let val = newOffset.bigEndian
                        withUnsafeBytes(of: val) { buf in
                            for i in 0..<8 {
                                data[data.startIndex + fileExtentOffsetPos + i] = buf[i]
                            }
                        }
                    }

                    // Write new length
                    let fileLengthPos = ilocPayloadFileOffset + extentLengthPos
                    if lengthSize == 4 && fileLengthPos + 4 <= data.count {
                        let val = UInt32(newLength).bigEndian
                        withUnsafeBytes(of: val) { buf in
                            for i in 0..<4 {
                                data[data.startIndex + fileLengthPos + i] = buf[i]
                            }
                        }
                    } else if lengthSize == 8 && fileLengthPos + 8 <= data.count {
                        let val = newLength.bigEndian
                        withUnsafeBytes(of: val) { buf in
                            for i in 0..<8 {
                                data[data.startIndex + fileLengthPos + i] = buf[i]
                            }
                        }
                    }

                    return
                }
            }
        }
    }
}
