import Foundation

// MARK: - Byte Order

/// Byte ordering used in TIFF/EXIF structures.
/// Determined by the first two bytes of the TIFF header: "II" (Intel/little) or "MM" (Motorola/big).
public enum ByteOrder: Sendable {
    case littleEndian  // "II" - Intel
    case bigEndian     // "MM" - Motorola
}

// MARK: - ByteReader

/// A cursor-based binary reader that respects byte ordering.
///
/// This is the foundation of all parsing — every IFD entry, every tag value,
/// every offset resolution flows through here.
public struct ByteReader {
    public let data: Data
    public var offset: Int
    public var byteOrder: ByteOrder

    public var bytesRemaining: Int { data.count - offset }
    public var isAtEnd: Bool { offset >= data.count }

    public init(data: Data, byteOrder: ByteOrder = .bigEndian) {
        self.data = data
        self.offset = 0
        self.byteOrder = byteOrder
    }

    // MARK: - Bounds checking

    private func ensureAvailable(_ count: Int) throws {
        guard offset + count <= data.count else {
            throw EXIFError.unexpectedEndOfData(
                needed: count,
                available: bytesRemaining,
                at: offset
            )
        }
    }

    // MARK: - Raw reads (no endian conversion)

    public mutating func readByte() throws -> UInt8 {
        try ensureAvailable(1)
        let value = data[data.startIndex + offset]
        offset += 1
        return value
    }

    public mutating func readBytes(_ count: Int) throws -> Data {
        try ensureAvailable(count)
        let start = data.startIndex + offset
        let slice = data[start..<start + count]
        offset += count
        return Data(slice)
    }

    // MARK: - Endian-aware integer reads

    public mutating func readUInt16() throws -> UInt16 {
        try ensureAvailable(2)
        let start = data.startIndex + offset
        let raw = data[start..<start + 2]
        offset += 2
        let value = raw.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        return byteOrder == .littleEndian ? UInt16(littleEndian: value) : UInt16(bigEndian: value)
    }

    public mutating func readUInt32() throws -> UInt32 {
        try ensureAvailable(4)
        let start = data.startIndex + offset
        let raw = data[start..<start + 4]
        offset += 4
        let value = raw.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return byteOrder == .littleEndian ? UInt32(littleEndian: value) : UInt32(bigEndian: value)
    }

    public mutating func readInt32() throws -> Int32 {
        let raw = try readUInt32()
        return Int32(bitPattern: raw)
    }

    // MARK: - EXIF-specific types

    /// Reads a RATIONAL (two UInt32s: numerator/denominator)
    public mutating func readURational() throws -> URational {
        let num = try readUInt32()
        let den = try readUInt32()
        return URational(numerator: num, denominator: den)
    }

    /// Reads a SRATIONAL (two Int32s: numerator/denominator)
    public mutating func readSRational() throws -> SRational {
        let num = try readInt32()
        let den = try readInt32()
        return SRational(numerator: num, denominator: den)
    }

    /// Reads a null-terminated ASCII string, or up to `maxLength` bytes
    public mutating func readASCII(_ maxLength: Int) throws -> String {
        let bytes = try readBytes(maxLength)
        // Strip null terminators
        let trimmed = bytes.prefix(while: { $0 != 0 })
        return String(data: Data(trimmed), encoding: .ascii) ?? ""
    }

    // MARK: - Navigation

    public mutating func seek(to position: Int) throws {
        guard position >= 0, position <= data.count else {
            throw EXIFError.invalidOffset(position, dataSize: data.count)
        }
        offset = position
    }

    /// Read at a specific offset without moving the cursor
    public func reading<T>(at position: Int, _ body: (inout ByteReader) throws -> T) throws -> T {
        var reader = self
        try reader.seek(to: position)
        return try body(&reader)
    }
}

// MARK: - ByteWriter

/// A binary writer that respects byte ordering.
/// Used to serialize IFD structures back into raw bytes.
public struct ByteWriter {
    public private(set) var data: Data
    public let byteOrder: ByteOrder

    public var count: Int { data.count }

    public init(byteOrder: ByteOrder = .bigEndian) {
        self.data = Data()
        self.byteOrder = byteOrder
    }

    public init(capacity: Int, byteOrder: ByteOrder = .bigEndian) {
        self.data = Data()
        self.data.reserveCapacity(capacity)
        self.byteOrder = byteOrder
    }

    // MARK: - Raw writes

    public mutating func writeByte(_ value: UInt8) {
        data.append(value)
    }

    public mutating func writeBytes(_ bytes: Data) {
        data.append(bytes)
    }

    public mutating func writeBytes(_ bytes: [UInt8]) {
        data.append(contentsOf: bytes)
    }

    // MARK: - Endian-aware writes

    public mutating func writeUInt16(_ value: UInt16) {
        let ordered = byteOrder == .littleEndian ? value.littleEndian : value.bigEndian
        withUnsafeBytes(of: ordered) { data.append(contentsOf: $0) }
    }

    public mutating func writeUInt32(_ value: UInt32) {
        let ordered = byteOrder == .littleEndian ? value.littleEndian : value.bigEndian
        withUnsafeBytes(of: ordered) { data.append(contentsOf: $0) }
    }

    public mutating func writeInt32(_ value: Int32) {
        writeUInt32(UInt32(bitPattern: value))
    }

    public mutating func writeURational(_ value: URational) {
        writeUInt32(value.numerator)
        writeUInt32(value.denominator)
    }

    public mutating func writeSRational(_ value: SRational) {
        writeInt32(value.numerator)
        writeInt32(value.denominator)
    }

    /// Write ASCII string with null terminator, padded to even length
    public mutating func writeASCII(_ string: String) {
        if let asciiData = string.data(using: .ascii) {
            data.append(asciiData)
        }
        data.append(0) // null terminator
        // TIFF requires values at even offsets
        if (string.count + 1) % 2 != 0 {
            data.append(0)
        }
    }

    // MARK: - Padding

    /// Pad to even byte boundary (required by TIFF spec)
    public mutating func padToEven() {
        if data.count % 2 != 0 {
            data.append(0)
        }
    }

    // MARK: - Patching (write at specific offset)

    public mutating func writeUInt16(at offset: Int, _ value: UInt16) {
        let ordered = byteOrder == .littleEndian ? value.littleEndian : value.bigEndian
        withUnsafeBytes(of: ordered) { buf in
            for i in 0..<2 {
                data[offset + i] = buf[i]
            }
        }
    }

    public mutating func writeUInt32(at offset: Int, _ value: UInt32) {
        let ordered = byteOrder == .littleEndian ? value.littleEndian : value.bigEndian
        withUnsafeBytes(of: ordered) { buf in
            for i in 0..<4 {
                data[offset + i] = buf[i]
            }
        }
    }
}
