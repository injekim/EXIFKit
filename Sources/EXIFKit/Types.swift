import Foundation

// MARK: - EXIF Errors

public enum EXIFError: Error, LocalizedError, CustomStringConvertible {
    case unexpectedEndOfData(needed: Int, available: Int, at: Int)
    case invalidOffset(Int, dataSize: Int)
    case invalidTIFFHeader
    case invalidByteOrder
    case unsupportedFormat(String)
    case tagNotFound(UInt16)
    case typeMismatch(expected: String, got: String)
    case invalidJPEG(String)
    case invalidPNG(String)
    case invalidHEIF(String)
    case invalidCR3(String)
    case invalidRAF(String)
    case invalidRAW(String)
    case corruptedIFD(String)
    case writeFailed(String)
    case readOnly(String)

    public var description: String {
        switch self {
        case .unexpectedEndOfData(let needed, let available, let at):
            return "Unexpected end of data at offset \(at): needed \(needed) bytes, \(available) available"
        case .invalidOffset(let offset, let dataSize):
            return "Invalid offset \(offset) for data of size \(dataSize)"
        case .invalidTIFFHeader:
            return "Invalid TIFF header"
        case .invalidByteOrder:
            return "Invalid byte order marker (expected 'II' or 'MM')"
        case .unsupportedFormat(let fmt):
            return "Unsupported format: \(fmt)"
        case .tagNotFound(let tag):
            return "Tag 0x\(String(tag, radix: 16, uppercase: true)) not found"
        case .typeMismatch(let expected, let got):
            return "Type mismatch: expected \(expected), got \(got)"
        case .invalidJPEG(let detail):
            return "Invalid JPEG: \(detail)"
        case .invalidPNG(let detail):
            return "Invalid PNG: \(detail)"
        case .invalidHEIF(let detail):
            return "Invalid HEIF/HEIC: \(detail)"
        case .invalidCR3(let detail):
            return "Invalid CR3: \(detail)"
        case .invalidRAF(let detail):
            return "Invalid RAF: \(detail)"
        case .invalidRAW(let detail):
            return "Invalid RAW: \(detail)"
        case .corruptedIFD(let detail):
            return "Corrupted IFD: \(detail)"
        case .writeFailed(let detail):
            return "Write failed: \(detail)"
        case .readOnly(let detail):
            return "Read-only operation: \(detail)"
        }
    }

    public var errorDescription: String? { description }
}

// MARK: - Rational Number Types

/// Unsigned rational (used for aperture, focal length, GPS coordinates, etc.)
public struct URational: Equatable, Hashable, CustomStringConvertible, Sendable {
    public let numerator: UInt32
    public let denominator: UInt32

    public var doubleValue: Double {
        guard denominator != 0 else { return 0 }
        return Double(numerator) / Double(denominator)
    }

    public var description: String {
        "\(numerator)/\(denominator)"
    }

    public init(numerator: UInt32, denominator: UInt32) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// Convenience: create from a double with a given denominator precision
    public init(_ value: Double, precision: UInt32 = 10000) {
        self.denominator = precision
        self.numerator = UInt32(clamping: Int64((value * Double(precision)).rounded()))
    }
}

/// Signed rational (used for exposure bias, etc.)
public struct SRational: Equatable, Hashable, CustomStringConvertible, Sendable {
    public let numerator: Int32
    public let denominator: Int32

    public var doubleValue: Double {
        guard denominator != 0 else { return 0 }
        return Double(numerator) / Double(denominator)
    }

    public var description: String {
        "\(numerator)/\(denominator)"
    }

    public init(numerator: Int32, denominator: Int32) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// Convenience: create from a double
    public init(_ value: Double, precision: Int32 = 10000) {
        self.denominator = precision
        self.numerator = Int32(clamping: Int64((value * Double(precision)).rounded()))
    }
}

// MARK: - EXIF Data Type IDs

/// The 12 data types defined by the TIFF/EXIF spec.
/// Each IFD entry declares its type, which determines how to read the value bytes.
public enum EXIFDataType: UInt16, CaseIterable, Sendable {
    case byte       = 1   // UInt8
    case ascii      = 2   // 7-bit ASCII, null-terminated
    case short      = 3   // UInt16
    case long       = 4   // UInt32
    case rational   = 5   // Two UInt32s (numerator/denominator)
    case sbyte      = 6   // Int8
    case undefined  = 7   // Arbitrary bytes
    case sshort     = 8   // Int16
    case slong      = 9   // Int32
    case srational  = 10  // Two Int32s (numerator/denominator)
    case float      = 11  // IEEE 754 float
    case double     = 12  // IEEE 754 double

    /// Size in bytes of a single element of this type
    public var unitSize: Int {
        switch self {
        case .byte, .sbyte, .ascii, .undefined: return 1
        case .short, .sshort:                   return 2
        case .long, .slong, .float:             return 4
        case .rational, .srational, .double:    return 8
        }
    }
}

// MARK: - Tag Value

/// A type-safe wrapper for EXIF tag values.
/// This is what you get when you read a tag and what you provide when you write one.
public enum TagValue: Equatable, CustomStringConvertible, Sendable {
    case byte(UInt8)
    case bytes([UInt8])
    case ascii(String)
    case short(UInt16)
    case shorts([UInt16])
    case long(UInt32)
    case longs([UInt32])
    case rational(URational)
    case rationals([URational])
    case srational(SRational)
    case srationals([SRational])
    case signedByte(Int8)
    case signedBytes([Int8])
    case signedShort(Int16)
    case signedShorts([Int16])
    case signedLong(Int32)
    case signedLongs([Int32])
    case float(Float)
    case floats([Float])
    case double(Double)
    case doubles([Double])
    case undefined(Data)

    public var description: String {
        switch self {
        case .byte(let v):          return "\(v)"
        case .bytes(let v):         return "\(v)"
        case .ascii(let v):         return v
        case .short(let v):         return "\(v)"
        case .shorts(let v):        return "\(v)"
        case .long(let v):          return "\(v)"
        case .longs(let v):         return "\(v)"
        case .rational(let v):      return v.description
        case .rationals(let v):     return v.map(\.description).joined(separator: ", ")
        case .srational(let v):     return v.description
        case .srationals(let v):    return v.map(\.description).joined(separator: ", ")
        case .signedByte(let v):    return "\(v)"
        case .signedBytes(let v):   return "\(v)"
        case .signedShort(let v):   return "\(v)"
        case .signedShorts(let v):  return "\(v)"
        case .signedLong(let v):    return "\(v)"
        case .signedLongs(let v):   return "\(v)"
        case .float(let v):         return "\(v)"
        case .floats(let v):        return "\(v)"
        case .double(let v):        return "\(v)"
        case .doubles(let v):       return "\(v)"
        case .undefined(let v):     return "\(v.count) bytes"
        }
    }

    // MARK: - Convenience accessors

    /// Get as string (works for .ascii, falls back to description)
    public var stringValue: String? {
        if case .ascii(let s) = self { return s }
        return nil
    }

    /// Get as UInt32 (works for .byte, .short, .long)
    public var uint32Value: UInt32? {
        switch self {
        case .byte(let v):  return UInt32(v)
        case .short(let v): return UInt32(v)
        case .long(let v):  return v
        default: return nil
        }
    }

    /// Get as Int (works for all integer types)
    public var intValue: Int? {
        switch self {
        case .byte(let v):        return Int(v)
        case .short(let v):       return Int(v)
        case .long(let v):        return Int(v)
        case .signedByte(let v):  return Int(v)
        case .signedShort(let v): return Int(v)
        case .signedLong(let v):  return Int(v)
        default: return nil
        }
    }

    /// Get as Double (works for rational types, integers, and floats)
    public var doubleValue: Double? {
        switch self {
        case .byte(let v):        return Double(v)
        case .short(let v):       return Double(v)
        case .long(let v):        return Double(v)
        case .rational(let v):    return v.doubleValue
        case .srational(let v):   return v.doubleValue
        case .signedByte(let v):  return Double(v)
        case .signedShort(let v): return Double(v)
        case .signedLong(let v):  return Double(v)
        case .float(let v):       return Double(v)
        case .double(let v):      return v
        default: return nil
        }
    }

    /// Get raw bytes (works for .undefined, .bytes)
    public var rawData: Data? {
        switch self {
        case .undefined(let d): return d
        case .bytes(let b): return Data(b)
        default: return nil
        }
    }

    /// The EXIF data type ID this value would serialize as
    public var dataType: EXIFDataType {
        switch self {
        case .byte, .bytes:                   return .byte
        case .ascii:                          return .ascii
        case .short, .shorts:                 return .short
        case .long, .longs:                   return .long
        case .rational, .rationals:           return .rational
        case .srational, .srationals:         return .srational
        case .signedByte, .signedBytes:       return .sbyte
        case .signedShort, .signedShorts:     return .sshort
        case .signedLong, .signedLongs:       return .slong
        case .float, .floats:                 return .float
        case .double, .doubles:               return .double
        case .undefined:                      return .undefined
        }
    }

    /// The number of elements (count field in IFD entry)
    public var count: UInt32 {
        switch self {
        case .byte, .signedByte, .short, .signedShort,
             .long, .signedLong, .rational, .srational,
             .float, .double:
            return 1
        case .bytes(let v):         return UInt32(v.count)
        case .ascii(let v):         return UInt32(v.utf8.count + 1) // +1 for null terminator
        case .shorts(let v):        return UInt32(v.count)
        case .signedBytes(let v):   return UInt32(v.count)
        case .signedShorts(let v):  return UInt32(v.count)
        case .longs(let v):         return UInt32(v.count)
        case .signedLongs(let v):   return UInt32(v.count)
        case .rationals(let v):     return UInt32(v.count)
        case .srationals(let v):    return UInt32(v.count)
        case .floats(let v):        return UInt32(v.count)
        case .doubles(let v):       return UInt32(v.count)
        case .undefined(let v):     return UInt32(v.count)
        }
    }

    /// Total size in bytes when serialized
    public var totalSize: Int {
        Int(count) * dataType.unitSize
    }
}
