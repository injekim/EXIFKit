import Foundation

// MARK: - TIFF Structure

/// The complete parsed TIFF metadata structure.
///
/// This is the common representation for all formats — JPEG wraps it in APP1,
/// PNG wraps it in an eXIf chunk, and TIFF/DNG files start with it directly.
public struct TIFFStructure: Sendable {
    /// The byte order used throughout the structure
    public let byteOrder: ByteOrder

    /// IFD0 — primary image metadata (make, model, orientation, etc.)
    public var ifd0: IFD

    /// IFD1 — thumbnail metadata (optional, usually in JPEG)
    public var ifd1: IFD?

    /// EXIF sub-IFD — camera settings (exposure, ISO, focal length, etc.)
    public var exifIFD: IFD?

    /// GPS sub-IFD — geolocation data
    public var gpsIFD: IFD?

    /// The raw TIFF data this structure was parsed from.
    /// Retained for thumbnail extraction.
    /// Not included in serialization — only used as a reference.
    internal var sourceTIFFData: Data?

    public init(
        byteOrder: ByteOrder,
        ifd0: IFD = IFD(),
        ifd1: IFD? = nil,
        exifIFD: IFD? = nil,
        gpsIFD: IFD? = nil
    ) {
        self.byteOrder = byteOrder
        self.ifd0 = ifd0
        self.ifd1 = ifd1
        self.exifIFD = exifIFD
        self.gpsIFD = gpsIFD
    }

    // MARK: - Convenience Accessors

    /// Camera manufacturer
    public var make: String? { ifd0.value(for: Tag.make)?.stringValue }

    /// Camera model
    public var model: String? { ifd0.value(for: Tag.model)?.stringValue }

    /// Image orientation (1-8)
    public var orientation: UInt16? {
        if case .short(let v) = ifd0.value(for: Tag.orientation) { return v }
        return nil
    }

    /// Software used to create/edit the image
    public var software: String? { ifd0.value(for: Tag.software)?.stringValue }

    /// Image description / title
    public var imageDescription: String? { ifd0.value(for: Tag.imageDescription)?.stringValue }

    /// Copyright string
    public var copyright: String? { ifd0.value(for: Tag.copyright)?.stringValue }

    /// Artist / photographer
    public var artist: String? { ifd0.value(for: Tag.artist)?.stringValue }

    /// Date/time the image was taken
    public var dateTimeOriginal: String? { exifIFD?.value(for: Tag.dateTimeOriginal)?.stringValue }

    /// Date/time the image was digitized
    public var dateTimeDigitized: String? { exifIFD?.value(for: Tag.dateTimeDigitized)?.stringValue }

    /// Timezone offset for dateTimeOriginal (e.g., "+09:00")
    public var offsetTimeOriginal: String? { exifIFD?.value(for: Tag.offsetTimeOriginal)?.stringValue }

    /// ISO speed
    public var iso: UInt16? {
        if case .short(let v) = exifIFD?.value(for: Tag.isoSpeedRatings) { return v }
        // Some cameras use shorts array with count 1
        if case .shorts(let v) = exifIFD?.value(for: Tag.isoSpeedRatings), let first = v.first { return first }
        return nil
    }

    /// Focal length in mm
    public var focalLength: Double? { exifIFD?.value(for: Tag.focalLength)?.doubleValue }

    /// Focal length in 35mm equivalent
    public var focalLength35mm: UInt16? {
        if case .short(let v) = exifIFD?.value(for: Tag.focalLength35mm) { return v }
        return nil
    }

    /// F-number (aperture)
    public var fNumber: Double? { exifIFD?.value(for: Tag.fNumber)?.doubleValue }

    /// Exposure time in seconds
    public var exposureTime: Double? { exifIFD?.value(for: Tag.exposureTime)?.doubleValue }

    /// Exposure bias / compensation in EV
    public var exposureBias: Double? { exifIFD?.value(for: Tag.exposureBias)?.doubleValue }

    /// Lens model name
    public var lensModel: String? { exifIFD?.value(for: Tag.lensModel)?.stringValue }

    /// Lens manufacturer
    public var lensMake: String? { exifIFD?.value(for: Tag.lensMake)?.stringValue }

    /// Flash fired (bit 0 of flash tag)
    public var flashFired: Bool? {
        if case .short(let v) = exifIFD?.value(for: Tag.flash) { return (v & 1) == 1 }
        return nil
    }

    /// Color space (1 = sRGB, 65535 = uncalibrated)
    public var colorSpace: UInt16? {
        if case .short(let v) = exifIFD?.value(for: Tag.colorSpace) { return v }
        return nil
    }

    /// Pixel width from EXIF
    public var pixelWidth: UInt32? { exifIFD?.value(for: Tag.pixelXDimension)?.uint32Value }

    /// Pixel height from EXIF
    public var pixelHeight: UInt32? { exifIFD?.value(for: Tag.pixelYDimension)?.uint32Value }

    // MARK: - Thumbnail Extraction

    /// Extract the embedded JPEG thumbnail from IFD1, if present.
    ///
    /// Most JPEG files contain a small JPEG thumbnail in IFD1.
    /// The thumbnail data is referenced by JPEGInterchangeFormat (offset)
    /// and JPEGInterchangeFormatLength (size) tags.
    public var thumbnailData: Data? {
        guard let ifd1 = ifd1,
              let source = sourceTIFFData else { return nil }

        // Method 1: JPEG thumbnail (most common)
        let jpegOffsetTag: UInt16 = 0x0201 // JPEGInterchangeFormat
        let jpegLengthTag: UInt16 = 0x0202 // JPEGInterchangeFormatLength

        if let offset = ifd1.value(for: jpegOffsetTag)?.uint32Value,
           let length = ifd1.value(for: jpegLengthTag)?.uint32Value {
            let start = Int(offset)
            let size = Int(length)
            if start >= 0 && start + size <= source.count && size > 0 {
                return Data(source[(source.startIndex + start)..<(source.startIndex + start + size)])
            }
        }

        return nil
    }

    /// GPS latitude as a signed decimal degree (negative = South)
    public var latitude: Double? {
        guard let coords = gpsIFD?.value(for: Tag.gpsLatitude),
              let ref = gpsIFD?.value(for: Tag.gpsLatitudeRef)?.stringValue else { return nil }
        guard let degrees = degreesFromDMS(coords) else { return nil }
        return ref == "S" ? -degrees : degrees
    }

    /// GPS longitude as a signed decimal degree (negative = West)
    public var longitude: Double? {
        guard let coords = gpsIFD?.value(for: Tag.gpsLongitude),
              let ref = gpsIFD?.value(for: Tag.gpsLongitudeRef)?.stringValue else { return nil }
        guard let degrees = degreesFromDMS(coords) else { return nil }
        return ref == "W" ? -degrees : degrees
    }

    /// GPS altitude in meters
    public var altitude: Double? {
        guard let alt = gpsIFD?.value(for: Tag.gpsAltitude)?.doubleValue else { return nil }
        if case .byte(let ref) = gpsIFD?.value(for: Tag.gpsAltitudeRef), ref == 1 {
            return -alt // Below sea level
        }
        return alt
    }

    /// Convert DMS (degrees/minutes/seconds as 3 rationals) to decimal degrees
    private func degreesFromDMS(_ value: TagValue) -> Double? {
        guard case .rationals(let rats) = value, rats.count == 3 else { return nil }
        let d = rats[0].doubleValue
        let m = rats[1].doubleValue
        let s = rats[2].doubleValue
        return d + m / 60.0 + s / 3600.0
    }

    // MARK: - Mutation helpers

    /// Set GPS coordinates
    public mutating func setGPSCoordinates(latitude: Double, longitude: Double, altitude: Double? = nil) {
        if gpsIFD == nil { gpsIFD = IFD() }

        // Latitude
        let latRef: String = latitude >= 0 ? "N" : "S"
        let latDMS = decimalToDMS(abs(latitude))
        gpsIFD!.set(tagID: Tag.gpsLatitudeRef, value: .ascii(latRef))
        gpsIFD!.set(tagID: Tag.gpsLatitude, value: .rationals(latDMS))

        // Longitude
        let lonRef: String = longitude >= 0 ? "E" : "W"
        let lonDMS = decimalToDMS(abs(longitude))
        gpsIFD!.set(tagID: Tag.gpsLongitudeRef, value: .ascii(lonRef))
        gpsIFD!.set(tagID: Tag.gpsLongitude, value: .rationals(lonDMS))

        // Altitude
        if let alt = altitude {
            gpsIFD!.set(tagID: Tag.gpsAltitudeRef, value: .byte(alt < 0 ? 1 : 0))
            gpsIFD!.set(tagID: Tag.gpsAltitude, value: .rational(URational(abs(alt), precision: 1000)))
        }

        // GPS version
        gpsIFD!.set(tagID: Tag.gpsVersionID, value: .bytes([2, 3, 0, 0]))
    }

    /// Convert decimal degrees to DMS as 3 URationals
    private func decimalToDMS(_ decimal: Double) -> [URational] {
        let d = Int(decimal)
        let mFull = (decimal - Double(d)) * 60.0
        let m = Int(mFull)
        let s = (mFull - Double(m)) * 60.0
        return [
            URational(numerator: UInt32(d), denominator: 1),
            URational(numerator: UInt32(m), denominator: 1),
            URational(numerator: UInt32((s * 10000).rounded()), denominator: 10000)
        ]
    }
}

// MARK: - TIFF Parser

/// Parses raw TIFF data (the "II"/"MM" byte-order marker through all IFDs).
///
/// This parser is used by all container formats:
/// - JPEG: pass the APP1 payload (after "Exif\0\0")
/// - PNG: pass the eXIf chunk data
/// - TIFF/DNG: pass the entire file
public struct TIFFParser {

    /// Parse TIFF data starting from the byte-order marker.
    public static func parse(_ data: Data) throws -> TIFFStructure {
        guard data.count >= 8 else {
            throw EXIFError.invalidTIFFHeader
        }

        var reader = ByteReader(data: data)

        // Byte order: "II" (0x4949) = little-endian, "MM" (0x4D4D) = big-endian
        let bom1 = try reader.readByte()
        let bom2 = try reader.readByte()

        let byteOrder: ByteOrder
        if bom1 == 0x49 && bom2 == 0x49 {
            byteOrder = .littleEndian
        } else if bom1 == 0x4D && bom2 == 0x4D {
            byteOrder = .bigEndian
        } else {
            throw EXIFError.invalidByteOrder
        }

        reader.byteOrder = byteOrder

        // Magic number: must be 42 (0x002A)
        let magic = try reader.readUInt16()
        guard magic == 42 else {
            throw EXIFError.invalidTIFFHeader
        }

        // Offset to first IFD
        let ifd0Offset = try reader.readUInt32()

        // Parse IFD0
        let ifd0 = try IFDReader.readIFD(from: data, at: Int(ifd0Offset), byteOrder: byteOrder)

        // Parse IFD1 (thumbnail) if present
        var ifd1: IFD? = nil
        if ifd0.nextIFDOffset != 0 {
            ifd1 = try? IFDReader.readIFD(from: data, at: Int(ifd0.nextIFDOffset), byteOrder: byteOrder)
        }

        // Parse EXIF sub-IFD if IFD0 has a pointer to it
        var exifIFD: IFD? = nil
        if let exifPointer = ifd0.value(for: Tag.exifIFDPointer)?.uint32Value {
            exifIFD = try? IFDReader.readIFD(from: data, at: Int(exifPointer), byteOrder: byteOrder)
        }

        // Parse GPS sub-IFD if IFD0 has a pointer to it
        var gpsIFD: IFD? = nil
        if let gpsPointer = ifd0.value(for: Tag.gpsIFDPointer)?.uint32Value {
            gpsIFD = try? IFDReader.readIFD(from: data, at: Int(gpsPointer), byteOrder: byteOrder)
        }

        return TIFFStructure(
            byteOrder: byteOrder,
            ifd0: ifd0,
            ifd1: ifd1,
            exifIFD: exifIFD,
            gpsIFD: gpsIFD
        ).withSourceData(data)
    }
}

extension TIFFStructure {
    /// Attach the source TIFF data for thumbnail extraction
    internal func withSourceData(_ data: Data) -> TIFFStructure {
        var copy = self
        copy.sourceTIFFData = data
        return copy
    }
}

// MARK: - TIFF Serializer

/// Rebuilds a complete TIFF data block from a TIFFStructure.
///
/// This is a "rebuild from scratch" approach — simpler and more reliable
/// than trying to patch offsets in place.
public struct TIFFSerializer {

    /// Serialize a TIFFStructure to a complete TIFF data block.
    public static func serialize(_ structure: TIFFStructure) -> Data {
        let byteOrder = structure.byteOrder
        var writer = ByteWriter(byteOrder: byteOrder)

        // TIFF Header (8 bytes)
        if byteOrder == .littleEndian {
            writer.writeBytes([0x49, 0x49]) // "II"
        } else {
            writer.writeBytes([0x4D, 0x4D]) // "MM"
        }
        writer.writeUInt16(42) // Magic

        // We'll write IFD0 starting at offset 8 (right after the header).
        // But first we need to build all the IFDs to know their sizes and set
        // the correct pointer offsets.

        // Build a mutable copy to inject sub-IFD pointers
        var ifd0 = structure.ifd0
        let exifIFD = structure.exifIFD
        let gpsIFD = structure.gpsIFD
        let ifd1 = structure.ifd1

        // We'll lay out data sequentially:
        //   [TIFF Header 8 bytes]
        //   [IFD0]
        //   [IFD1] (if present)
        //   [EXIF sub-IFD]
        //   [GPS sub-IFD]
        //
        // We need a two-pass approach: first compute sizes, then write with correct offsets.

        // Remove old sub-IFD pointers (we'll recalculate them)
        ifd0.remove(tagID: Tag.exifIFDPointer)
        ifd0.remove(tagID: Tag.gpsIFDPointer)

        // Compute IFD0 size (without sub-IFD pointers yet — we'll add them, which changes size)
        // Add placeholder pointers so the size calculation includes them
        if exifIFD != nil {
            ifd0.set(tagID: Tag.exifIFDPointer, value: .long(0)) // placeholder
        }
        if gpsIFD != nil {
            ifd0.set(tagID: Tag.gpsIFDPointer, value: .long(0)) // placeholder
        }

        let ifd0Offset: UInt32 = 8

        // Compute how many bytes IFD0 will take
        let ifd0Data = IFDWriter.writeIFD(ifd0, baseOffset: ifd0Offset, byteOrder: byteOrder)
        var currentOffset = ifd0Offset + UInt32(ifd0Data.count)

        // IFD1
        var ifd1Data: Data? = nil
        if var ifd1 = ifd1 {
            ifd1.nextIFDOffset = 0
            let data = IFDWriter.writeIFD(ifd1, baseOffset: currentOffset, byteOrder: byteOrder)
            ifd1Data = data
            currentOffset += UInt32(data.count)
        }

        // EXIF sub-IFD
        let exifOffset = currentOffset
        var exifData: Data? = nil
        if let exif = exifIFD {
            let data = IFDWriter.writeIFD(exif, baseOffset: exifOffset, byteOrder: byteOrder)
            exifData = data
            currentOffset += UInt32(data.count)
        }

        // GPS sub-IFD
        let gpsOffset = currentOffset
        var gpsData: Data? = nil
        if let gps = gpsIFD {
            let data = IFDWriter.writeIFD(gps, baseOffset: gpsOffset, byteOrder: byteOrder)
            gpsData = data
            currentOffset += UInt32(data.count)
        }

        // Now rebuild IFD0 with correct pointers
        if exifIFD != nil {
            ifd0.set(tagID: Tag.exifIFDPointer, value: .long(exifOffset))
        }
        if gpsIFD != nil {
            ifd0.set(tagID: Tag.gpsIFDPointer, value: .long(gpsOffset))
        }

        // Set IFD0's next-IFD pointer
        if ifd1Data != nil {
            ifd0.nextIFDOffset = ifd0Offset + UInt32(ifd0Data.count) // right after IFD0
        } else {
            ifd0.nextIFDOffset = 0
        }

        // Re-serialize IFD0 with the correct pointers
        // (this changes the offsets of everything after it, but since IFD0's
        //  entry count hasn't changed, its serialized size is the same)
        let finalIFD0Data = IFDWriter.writeIFD(ifd0, baseOffset: ifd0Offset, byteOrder: byteOrder)

        // Write offset to IFD0
        writer.writeUInt32(ifd0Offset)

        // Write all IFD data
        writer.writeBytes(finalIFD0Data)
        if let d = ifd1Data { writer.writeBytes(d) }
        if let d = exifData { writer.writeBytes(d) }
        if let d = gpsData { writer.writeBytes(d) }

        return writer.data
    }
}
