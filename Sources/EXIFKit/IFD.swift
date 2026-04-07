import Foundation

// MARK: - IFD Entry

/// A single entry in an Image File Directory.
///
/// Each IFD entry is exactly 12 bytes on disk:
///   - 2 bytes: tag ID
///   - 2 bytes: data type
///   - 4 bytes: count (number of values, not bytes)
///   - 4 bytes: value or offset to value (if total size > 4 bytes)
public struct IFDEntry: Sendable {
    public let tagID: UInt16
    public let dataType: EXIFDataType
    public let count: UInt32
    public var value: TagValue

    /// Human-readable tag name
    public var tagName: String {
        Tag.name(for: tagID)
    }

    public init(tagID: UInt16, value: TagValue) {
        self.tagID = tagID
        self.dataType = value.dataType
        self.count = value.count
        self.value = value
    }

    init(tagID: UInt16, dataType: EXIFDataType, count: UInt32, value: TagValue) {
        self.tagID = tagID
        self.dataType = dataType
        self.count = count
        self.value = value
    }
}

// MARK: - IFD (Image File Directory)

/// A parsed IFD — an ordered collection of tag entries.
///
/// EXIF metadata is organized as a tree of IFDs:
///   IFD0 (main image)
///     → EXIF sub-IFD (camera settings)
///       → GPS sub-IFD (location)
///     → IFD1 (thumbnail)
public struct IFD: Sendable {
    /// The entries in tag-ID order
    public var entries: [IFDEntry]

    /// Offset to the next IFD (0 = no next IFD)
    public var nextIFDOffset: UInt32

    public init(entries: [IFDEntry] = [], nextIFDOffset: UInt32 = 0) {
        self.entries = entries
        self.nextIFDOffset = nextIFDOffset
    }

    // MARK: - Lookup

    /// Find an entry by tag ID
    public func entry(for tagID: UInt16) -> IFDEntry? {
        entries.first(where: { $0.tagID == tagID })
    }

    /// Get the value of a tag
    public func value(for tagID: UInt16) -> TagValue? {
        entry(for: tagID)?.value
    }

    // MARK: - Mutation

    /// Set or replace a tag value. Inserts in tag-ID order if new.
    public mutating func set(tagID: UInt16, value: TagValue) {
        if let index = entries.firstIndex(where: { $0.tagID == tagID }) {
            entries[index] = IFDEntry(tagID: tagID, value: value)
        } else {
            let entry = IFDEntry(tagID: tagID, value: value)
            // Insert in sorted order by tag ID (TIFF spec requires this)
            if let insertIndex = entries.firstIndex(where: { $0.tagID > tagID }) {
                entries.insert(entry, at: insertIndex)
            } else {
                entries.append(entry)
            }
        }
    }

    /// Remove a tag
    @discardableResult
    public mutating func remove(tagID: UInt16) -> IFDEntry? {
        if let index = entries.firstIndex(where: { $0.tagID == tagID }) {
            return entries.remove(at: index)
        }
        return nil
    }
}

// MARK: - IFD Reader

/// Reads IFD structures from raw TIFF data.
public struct IFDReader {

    /// Parse an IFD at the given offset within TIFF data.
    ///
    /// - Parameters:
    ///   - data: The entire TIFF data block (starting from the TIFF header "II"/"MM")
    ///   - offset: Byte offset from the start of TIFF data to the IFD
    ///   - byteOrder: Endianness
    /// - Returns: A parsed IFD
    public static func readIFD(
        from data: Data,
        at offset: Int,
        byteOrder: ByteOrder
    ) throws -> IFD {
        var reader = ByteReader(data: data, byteOrder: byteOrder)
        try reader.seek(to: offset)

        let entryCount = try reader.readUInt16()

        // Sanity check: an IFD with >1000 entries is almost certainly corrupt
        guard entryCount < 1000 else {
            throw EXIFError.corruptedIFD("Entry count \(entryCount) seems too large")
        }

        var entries: [IFDEntry] = []
        entries.reserveCapacity(Int(entryCount))

        for _ in 0..<entryCount {
            let entry = try readEntry(from: &reader, tiffData: data)
            entries.append(entry)
        }

        let nextOffset = try reader.readUInt32()

        return IFD(entries: entries, nextIFDOffset: nextOffset)
    }

    /// Read a single 12-byte IFD entry
    private static func readEntry(
        from reader: inout ByteReader,
        tiffData: Data
    ) throws -> IFDEntry {
        let tagID = try reader.readUInt16()
        let typeRaw = try reader.readUInt16()
        let count = try reader.readUInt32()

        guard let dataType = EXIFDataType(rawValue: typeRaw) else {
            // Unknown type — skip the 4-byte value/offset field
            let rawBytes = try reader.readBytes(4)
            return IFDEntry(
                tagID: tagID,
                dataType: .undefined,
                count: count,
                value: .undefined(rawBytes)
            )
        }

        // Sanity check: cap total size to prevent OOM on corrupt count values.
        // Legitimate EXIF values rarely exceed 64KB; MakerNotes can be ~1MB.
        let totalSize = Int(count) * dataType.unitSize
        let maxValueSize = 10 * 1024 * 1024 // 10 MB
        guard totalSize >= 0, totalSize <= maxValueSize else {
            let rawBytes = try reader.readBytes(4)
            return IFDEntry(
                tagID: tagID,
                dataType: .undefined,
                count: 4,
                value: .undefined(rawBytes)
            )
        }

        // If total value size ≤ 4 bytes, it's stored inline in the entry.
        // Otherwise, the 4 bytes are an offset to where the value lives.
        let valueData: Data
        if totalSize <= 4 {
            valueData = try reader.readBytes(4)
        } else {
            let valueOffset = try reader.readUInt32()
            // Validate offset before following it
            guard Int(valueOffset) + totalSize <= tiffData.count else {
                return IFDEntry(
                    tagID: tagID,
                    dataType: .undefined,
                    count: 0,
                    value: .undefined(Data())
                )
            }
            valueData = try reader.reading(at: Int(valueOffset)) { r in
                try r.readBytes(totalSize)
            }
        }

        let value = try parseValue(
            data: valueData,
            type: dataType,
            count: count,
            byteOrder: reader.byteOrder
        )

        return IFDEntry(tagID: tagID, dataType: dataType, count: count, value: value)
    }

    /// Parse raw bytes into a TagValue based on the declared type and count
    private static func parseValue(
        data: Data,
        type: EXIFDataType,
        count: UInt32,
        byteOrder: ByteOrder
    ) throws -> TagValue {
        var reader = ByteReader(data: data, byteOrder: byteOrder)

        switch type {
        case .byte:
            if count == 1 {
                return .byte(try reader.readByte())
            } else {
                var bytes: [UInt8] = []
                for _ in 0..<count { bytes.append(try reader.readByte()) }
                return .bytes(bytes)
            }

        case .ascii:
            return .ascii(try reader.readASCII(Int(count)))

        case .short:
            if count == 1 {
                return .short(try reader.readUInt16())
            } else {
                var values: [UInt16] = []
                for _ in 0..<count { values.append(try reader.readUInt16()) }
                return .shorts(values)
            }

        case .long:
            if count == 1 {
                return .long(try reader.readUInt32())
            } else {
                var values: [UInt32] = []
                for _ in 0..<count { values.append(try reader.readUInt32()) }
                return .longs(values)
            }

        case .rational:
            if count == 1 {
                return .rational(try reader.readURational())
            } else {
                var values: [URational] = []
                for _ in 0..<count { values.append(try reader.readURational()) }
                return .rationals(values)
            }

        case .srational:
            if count == 1 {
                return .srational(try reader.readSRational())
            } else {
                var values: [SRational] = []
                for _ in 0..<count { values.append(try reader.readSRational()) }
                return .srationals(values)
            }

        case .slong:
            if count == 1 {
                return .signedLong(try reader.readInt32())
            } else {
                var values: [Int32] = []
                for _ in 0..<count { values.append(try reader.readInt32()) }
                return .signedLongs(values)
            }

        case .sbyte:
            if count == 1 {
                return .signedByte(Int8(bitPattern: try reader.readByte()))
            } else {
                var values: [Int8] = []
                for _ in 0..<count { values.append(Int8(bitPattern: try reader.readByte())) }
                return .signedBytes(values)
            }

        case .sshort:
            if count == 1 {
                return .signedShort(Int16(bitPattern: try reader.readUInt16()))
            } else {
                var values: [Int16] = []
                for _ in 0..<count { values.append(Int16(bitPattern: try reader.readUInt16())) }
                return .signedShorts(values)
            }

        case .float:
            if count == 1 {
                let bits = try reader.readUInt32()
                return .float(Float(bitPattern: bits))
            } else {
                var values: [Float] = []
                for _ in 0..<count {
                    let bits = try reader.readUInt32()
                    values.append(Float(bitPattern: bits))
                }
                return .floats(values)
            }

        case .double:
            if count == 1 {
                let rawBytes = try reader.readBytes(8)
                let bits = rawBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                let ordered = reader.byteOrder == .littleEndian ? UInt64(littleEndian: bits) : UInt64(bigEndian: bits)
                return .double(Swift.Double(bitPattern: ordered))
            } else {
                var values: [Swift.Double] = []
                for _ in 0..<count {
                    let rawBytes = try reader.readBytes(8)
                    let bits = rawBytes.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
                    let ordered = reader.byteOrder == .littleEndian ? UInt64(littleEndian: bits) : UInt64(bigEndian: bits)
                    values.append(Swift.Double(bitPattern: ordered))
                }
                return .doubles(values)
            }

        case .undefined:
            return .undefined(data.prefix(Int(count)))
        }
    }
}

// MARK: - IFD Writer

/// Serializes IFD structures back into TIFF-compatible bytes.
///
/// The writing strategy: all entries are written as 12-byte records.
/// Values that fit in 4 bytes go inline; larger values go into an overflow
/// area that follows the IFD entries.
public struct IFDWriter {

    /// Serialize an IFD to bytes.
    ///
    /// - Parameters:
    ///   - ifd: The IFD to write
    ///   - baseOffset: The absolute offset in the TIFF file where this IFD will be placed.
    ///     Needed to calculate correct value offsets.
    ///   - byteOrder: Endianness
    /// - Returns: The serialized bytes
    public static func writeIFD(
        _ ifd: IFD,
        baseOffset: UInt32,
        byteOrder: ByteOrder
    ) -> Data {
        var writer = ByteWriter(byteOrder: byteOrder)
        var overflowWriter = ByteWriter(byteOrder: byteOrder)

        let entryCount = UInt16(ifd.entries.count)
        writer.writeUInt16(entryCount)

        // The overflow area starts after:
        //   2 bytes (entry count) + 12 bytes * entryCount + 4 bytes (next IFD offset)
        let overflowStart = baseOffset + 2 + UInt32(entryCount) * 12 + 4

        for entry in ifd.entries {
            writer.writeUInt16(entry.tagID)
            writer.writeUInt16(entry.value.dataType.rawValue)
            writer.writeUInt32(entry.value.count)

            let valueBytes = serializeValue(entry.value, byteOrder: byteOrder)

            if valueBytes.count <= 4 {
                // Inline: pad to 4 bytes
                writer.writeBytes(valueBytes)
                for _ in 0..<(4 - valueBytes.count) {
                    writer.writeByte(0)
                }
            } else {
                // Write offset to overflow area
                let overflowOffset = overflowStart + UInt32(overflowWriter.count)
                writer.writeUInt32(overflowOffset)
                overflowWriter.writeBytes(valueBytes)
                overflowWriter.padToEven()
            }
        }

        writer.writeUInt32(ifd.nextIFDOffset)
        writer.writeBytes(overflowWriter.data)

        return writer.data
    }

    /// Serialize a TagValue to raw bytes
    public static func serializeValue(_ value: TagValue, byteOrder: ByteOrder) -> Data {
        var w = ByteWriter(byteOrder: byteOrder)

        switch value {
        case .byte(let v):
            w.writeByte(v)
        case .bytes(let v):
            w.writeBytes(v)
        case .ascii(let v):
            if let data = v.data(using: .ascii) {
                w.writeBytes(data)
            }
            w.writeByte(0)
        case .short(let v):
            w.writeUInt16(v)
        case .shorts(let v):
            for s in v { w.writeUInt16(s) }
        case .long(let v):
            w.writeUInt32(v)
        case .longs(let v):
            for l in v { w.writeUInt32(l) }
        case .rational(let v):
            w.writeURational(v)
        case .rationals(let v):
            for r in v { w.writeURational(r) }
        case .srational(let v):
            w.writeSRational(v)
        case .srationals(let v):
            for r in v { w.writeSRational(r) }
        case .signedByte(let v):
            w.writeByte(UInt8(bitPattern: v))
        case .signedBytes(let v):
            for b in v { w.writeByte(UInt8(bitPattern: b)) }
        case .signedShort(let v):
            w.writeUInt16(UInt16(bitPattern: v))
        case .signedShorts(let v):
            for s in v { w.writeUInt16(UInt16(bitPattern: s)) }
        case .signedLong(let v):
            w.writeInt32(v)
        case .signedLongs(let v):
            for l in v { w.writeInt32(l) }
        case .float(let v):
            w.writeUInt32(v.bitPattern)
        case .floats(let v):
            for f in v { w.writeUInt32(f.bitPattern) }
        case .double(let v):
            let bits = v.bitPattern
            let ordered = w.byteOrder == .littleEndian ? bits.littleEndian : bits.bigEndian
            withUnsafeBytes(of: ordered) { w.writeBytes(Data($0)) }
        case .doubles(let v):
            for d in v {
                let bits = d.bitPattern
                let ordered = w.byteOrder == .littleEndian ? bits.littleEndian : bits.bigEndian
                withUnsafeBytes(of: ordered) { w.writeBytes(Data($0)) }
            }
        case .undefined(let v):
            w.writeBytes(v)
        }

        return w.data
    }
}
