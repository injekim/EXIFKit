import Foundation

// MARK: - TIFF File Container

/// Reads and writes EXIF metadata from standalone TIFF, DNG, and TIFF-based RAW files.
///
/// Write strategy:
/// 1. If the original IFD0 already has ExifIFDPointer/GPSInfoIFDPointer,
///    we append new sub-IFDs and patch the existing pointer values in place.
/// 2. If IFD0 is missing a pointer tag (e.g., adding GPS to a file that had none),
///    we rebuild IFD0 at the end of the file with the new entries and update the
///    TIFF header's IFD0 offset. The original IFD0 becomes dead space (harmless).
/// 3. Image data offsets (StripOffsets, TileOffsets) are never touched.
public struct TIFFFileContainer {

    // Tags that reference image data — we must never modify these
    private static let imageDataTags: Set<UInt16> = [
        0x0111, // StripOffsets
        0x0117, // StripByteCounts
        0x0144, // TileOffsets
        0x0145, // TileByteCounts
        0x0201, // JPEGInterchangeFormat (thumbnail offset)
        0x0202, // JPEGInterchangeFormatLength
    ]

    // MARK: - Reading

    public static func readEXIF(from data: Data) throws -> TIFFStructure {
        return try TIFFParser.parse(data)
    }

    // MARK: - Writing

    public static func writeEXIF(_ structure: TIFFStructure, to originalData: Data) throws -> Data {
        let originalStructure = try TIFFParser.parse(originalData)
        return try writeEXIFInternal(structure, to: originalData, originalStructure: originalStructure)
    }

    /// Internal write that accepts a pre-parsed original structure.
    /// Used by RAWContainer for formats with non-standard TIFF magic (ORF, RW2).
    internal static func writeEXIFInternal(
        _ structure: TIFFStructure,
        to originalData: Data,
        originalStructure: TIFFStructure
    ) throws -> Data {
        var data = originalData
        let byteOrder = structure.byteOrder

        let hadExifPointer = originalStructure.ifd0.value(for: Tag.exifIFDPointer) != nil
        let hadGPSPointer = originalStructure.ifd0.value(for: Tag.gpsIFDPointer) != nil
        let needsExifPointer = structure.exifIFD != nil
        let needsGPSPointer = structure.gpsIFD != nil

        // Check if we need to rebuild IFD0 (adding OR removing pointer tags)
        let needsIFD0Rebuild = (needsExifPointer != hadExifPointer) ||
                               (needsGPSPointer != hadGPSPointer) ||
                               ifd0TagsChanged(original: originalStructure.ifd0, modified: structure.ifd0)

        if needsIFD0Rebuild {
            return try rebuildWithNewIFD0(structure: structure, originalData: originalData, originalStructure: originalStructure)
        }

        // Simple case: just append sub-IFDs and patch existing pointers
        if let exifIFD = structure.exifIFD {
            let appendOffset = UInt32(data.count)
            let exifData = IFDWriter.writeIFD(exifIFD, baseOffset: appendOffset, byteOrder: byteOrder)
            data.append(exifData)
            try patchIFD0Pointer(in: &data, tagID: Tag.exifIFDPointer, newOffset: appendOffset, byteOrder: byteOrder)
        }

        if let gpsIFD = structure.gpsIFD {
            let appendOffset = UInt32(data.count)
            let gpsData = IFDWriter.writeIFD(gpsIFD, baseOffset: appendOffset, byteOrder: byteOrder)
            data.append(gpsData)
            try patchIFD0Pointer(in: &data, tagID: Tag.gpsIFDPointer, newOffset: appendOffset, byteOrder: byteOrder)
        }

        return data
    }

    // MARK: - IFD0 Rebuild

    /// Rebuilds IFD0 at the end of the file, preserving all image data references.
    private static func rebuildWithNewIFD0(
        structure: TIFFStructure,
        originalData: Data,
        originalStructure: TIFFStructure
    ) throws -> Data {
        var data = originalData
        let byteOrder = structure.byteOrder

        let original = originalStructure

        // Start with the modified IFD0
        var newIFD0 = structure.ifd0

        // Preserve all image-data tags from the original
        for tag in imageDataTags {
            if let entry = original.ifd0.entry(for: tag) {
                newIFD0.set(tagID: tag, value: entry.value)
            }
        }

        // Append EXIF sub-IFD
        if let exifIFD = structure.exifIFD {
            let exifOffset = UInt32(data.count)
            let exifData = IFDWriter.writeIFD(exifIFD, baseOffset: exifOffset, byteOrder: byteOrder)
            data.append(exifData)
            newIFD0.set(tagID: Tag.exifIFDPointer, value: .long(exifOffset))
        } else {
            newIFD0.remove(tagID: Tag.exifIFDPointer)
        }

        // Append GPS sub-IFD
        if let gpsIFD = structure.gpsIFD {
            let gpsOffset = UInt32(data.count)
            let gpsData = IFDWriter.writeIFD(gpsIFD, baseOffset: gpsOffset, byteOrder: byteOrder)
            data.append(gpsData)
            newIFD0.set(tagID: Tag.gpsIFDPointer, value: .long(gpsOffset))
        } else {
            newIFD0.remove(tagID: Tag.gpsIFDPointer)
        }

        // Preserve next-IFD offset (IFD1 for thumbnail)
        newIFD0.nextIFDOffset = original.ifd0.nextIFDOffset

        // Write new IFD0 at end of file
        let newIFD0Offset = UInt32(data.count)
        let ifd0Data = IFDWriter.writeIFD(newIFD0, baseOffset: newIFD0Offset, byteOrder: byteOrder)
        data.append(ifd0Data)

        // Patch the TIFF header to point to the new IFD0 (bytes 4-7)
        var writer = ByteWriter(byteOrder: byteOrder)
        writer.writeUInt32(newIFD0Offset)
        let offsetBytes = writer.data
        for i in 0..<4 {
            data[data.startIndex + 4 + i] = offsetBytes[i]
        }

        return data
    }

    /// Check if any non-pointer, non-image-data tags in IFD0 have been modified
    private static func ifd0TagsChanged(original: IFD, modified: IFD) -> Bool {
        let skipTags: Set<UInt16> = Set([Tag.exifIFDPointer, Tag.gpsIFDPointer])
            .union(imageDataTags)

        // Check for new or changed tags
        for entry in modified.entries {
            if skipTags.contains(entry.tagID) { continue }
            guard let origEntry = original.entry(for: entry.tagID) else {
                return true // New tag added
            }
            if origEntry.value != entry.value {
                return true // Value changed
            }
        }

        // Check for removed tags
        for entry in original.entries {
            if skipTags.contains(entry.tagID) { continue }
            if modified.entry(for: entry.tagID) == nil {
                return true // Tag removed
            }
        }

        return false
    }

    // MARK: - In-place patching

    private static func patchIFD0Pointer(
        in data: inout Data,
        tagID: UInt16,
        newOffset: UInt32,
        byteOrder: ByteOrder
    ) throws {
        var reader = ByteReader(data: data, byteOrder: byteOrder)
        try reader.seek(to: 4)
        let ifd0Offset = try reader.readUInt32()

        try reader.seek(to: Int(ifd0Offset))
        let entryCount = try reader.readUInt16()

        let entriesStart = Int(ifd0Offset) + 2
        for i in 0..<Int(entryCount) {
            let entryOffset = entriesStart + i * 12
            try reader.seek(to: entryOffset)
            let tag = try reader.readUInt16()

            if tag == tagID {
                let valueOffset = entryOffset + 8
                var writer = ByteWriter(byteOrder: byteOrder)
                writer.writeUInt32(newOffset)
                let bytes = writer.data
                for j in 0..<4 {
                    data[data.startIndex + valueOffset + j] = bytes[j]
                }
                return
            }
        }

        throw EXIFError.tagNotFound(tagID)
    }
}
