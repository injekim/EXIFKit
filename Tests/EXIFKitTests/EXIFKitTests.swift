import XCTest
@testable import EXIFKit

final class EXIFKitTests: XCTestCase {

    // MARK: - ByteReader / ByteWriter round-trip

    func testByteReaderWriterRoundTrip() throws {
        var writer = ByteWriter(byteOrder: .littleEndian)
        writer.writeUInt16(0x1234)
        writer.writeUInt32(0xDEADBEEF)
        writer.writeURational(URational(numerator: 22, denominator: 7))

        var reader = ByteReader(data: writer.data, byteOrder: .littleEndian)
        XCTAssertEqual(try reader.readUInt16(), 0x1234)
        XCTAssertEqual(try reader.readUInt32(), 0xDEADBEEF)
        let rational = try reader.readURational()
        XCTAssertEqual(rational.numerator, 22)
        XCTAssertEqual(rational.denominator, 7)
    }

    func testByteOrderMatters() throws {
        var writer = ByteWriter(byteOrder: .bigEndian)
        writer.writeUInt16(0x0102)

        var reader = ByteReader(data: writer.data, byteOrder: .bigEndian)
        XCTAssertEqual(try reader.readUInt16(), 0x0102)

        var readerLE = ByteReader(data: writer.data, byteOrder: .littleEndian)
        XCTAssertEqual(try readerLE.readUInt16(), 0x0201)
    }

    func testBoundsChecking() {
        let data = Data([0x01, 0x02])
        var reader = ByteReader(data: data, byteOrder: .bigEndian)
        XCTAssertNoThrow(try reader.readUInt16())
        XCTAssertThrowsError(try reader.readByte()) // should fail - at end
    }

    func testSeekValidation() {
        var reader = ByteReader(data: Data([0x01]), byteOrder: .bigEndian)
        XCTAssertThrowsError(try reader.seek(to: -1))
        XCTAssertThrowsError(try reader.seek(to: 100))
        XCTAssertNoThrow(try reader.seek(to: 0))
        XCTAssertNoThrow(try reader.seek(to: 1)) // seek to end is valid
    }

    // MARK: - IFD

    func testIFDSetAndGet() {
        var ifd = IFD()
        ifd.set(tagID: Tag.make, value: .ascii("Apple"))
        ifd.set(tagID: Tag.model, value: .ascii("iPhone 15 Pro"))

        XCTAssertEqual(ifd.value(for: Tag.make)?.stringValue, "Apple")
        XCTAssertEqual(ifd.value(for: Tag.model)?.stringValue, "iPhone 15 Pro")
    }

    func testIFDSortedInsertion() {
        var ifd = IFD()
        ifd.set(tagID: 0x0200, value: .short(1))
        ifd.set(tagID: 0x0100, value: .short(2))
        ifd.set(tagID: 0x0150, value: .short(3))
        XCTAssertEqual(ifd.entries.map(\.tagID), [0x0100, 0x0150, 0x0200])
    }

    func testIFDRemove() {
        var ifd = IFD()
        ifd.set(tagID: Tag.make, value: .ascii("Apple"))
        XCTAssertNotNil(ifd.value(for: Tag.make))
        ifd.remove(tagID: Tag.make)
        XCTAssertNil(ifd.value(for: Tag.make))
    }

    func testIFDReplace() {
        var ifd = IFD()
        ifd.set(tagID: Tag.make, value: .ascii("Apple"))
        ifd.set(tagID: Tag.make, value: .ascii("Canon"))
        XCTAssertEqual(ifd.entries.count, 1)
        XCTAssertEqual(ifd.value(for: Tag.make)?.stringValue, "Canon")
    }

    // MARK: - TagValue

    func testTagValueSizes() {
        XCTAssertEqual(TagValue.byte(0).totalSize, 1)
        XCTAssertEqual(TagValue.short(0).totalSize, 2)
        XCTAssertEqual(TagValue.long(0).totalSize, 4)
        XCTAssertEqual(TagValue.rational(URational(numerator: 1, denominator: 1)).totalSize, 8)
        XCTAssertEqual(TagValue.ascii("Hello").totalSize, 6) // 5 chars + null
        XCTAssertEqual(TagValue.signedByte(0).totalSize, 1)
        XCTAssertEqual(TagValue.signedShort(0).totalSize, 2)
        XCTAssertEqual(TagValue.float(0).totalSize, 4)
        XCTAssertEqual(TagValue.double(0).totalSize, 8)
    }

    func testTagValueAccessors() {
        XCTAssertEqual(TagValue.byte(42).intValue, 42)
        XCTAssertEqual(TagValue.signedShort(-100).intValue, -100)
        XCTAssertEqual(TagValue.signedLong(-999).intValue, -999)
        XCTAssertEqual(TagValue.float(3.14).doubleValue!, 3.14, accuracy: 0.01)
        XCTAssertEqual(TagValue.double(2.718).doubleValue!, 2.718, accuracy: 0.001)
        XCTAssertEqual(TagValue.ascii("test").stringValue, "test")
        XCTAssertNil(TagValue.long(0).stringValue)

        let data = Data([0x01, 0x02, 0x03])
        XCTAssertEqual(TagValue.undefined(data).rawData, data)
    }

    func testTagValueDataTypes() {
        XCTAssertEqual(TagValue.signedByte(0).dataType, .sbyte)
        XCTAssertEqual(TagValue.signedShort(0).dataType, .sshort)
        XCTAssertEqual(TagValue.float(0).dataType, .float)
        XCTAssertEqual(TagValue.double(0).dataType, .double)
    }

    // MARK: - All data type round-trips through IFD

    func testAllDataTypeSerializationRoundTrip() throws {
        var ifd = IFD()
        ifd.set(tagID: 0x0001, value: .byte(42))
        ifd.set(tagID: 0x0002, value: .ascii("Hello"))
        ifd.set(tagID: 0x0003, value: .short(1000))
        ifd.set(tagID: 0x0004, value: .long(100000))
        ifd.set(tagID: 0x0005, value: .rational(URational(numerator: 22, denominator: 7)))
        ifd.set(tagID: 0x0006, value: .signedByte(-42))
        ifd.set(tagID: 0x0007, value: .undefined(Data([0xDE, 0xAD])))
        ifd.set(tagID: 0x0008, value: .signedShort(-500))
        ifd.set(tagID: 0x0009, value: .signedLong(-100000))
        ifd.set(tagID: 0x000A, value: .srational(SRational(numerator: -22, denominator: 7)))

        let byteOrder = ByteOrder.littleEndian
        let written = IFDWriter.writeIFD(ifd, baseOffset: 0, byteOrder: byteOrder)
        let parsed = try IFDReader.readIFD(from: written, at: 0, byteOrder: byteOrder)

        XCTAssertEqual(parsed.entries.count, 10)
        XCTAssertEqual(parsed.value(for: 0x0001)?.intValue, 42)
        XCTAssertEqual(parsed.value(for: 0x0002)?.stringValue, "Hello")
        XCTAssertEqual(parsed.value(for: 0x0003)?.intValue, 1000)
        XCTAssertEqual(parsed.value(for: 0x0004)?.intValue, 100000)
        XCTAssertEqual(parsed.value(for: 0x0005)!.doubleValue!, 22.0/7.0, accuracy: 0.0001)
        XCTAssertEqual(parsed.value(for: 0x0006)?.intValue, -42)
        XCTAssertEqual(parsed.value(for: 0x0008)?.intValue, -500)
        XCTAssertEqual(parsed.value(for: 0x0009)?.intValue, -100000)
        XCTAssertEqual(parsed.value(for: 0x000A)!.doubleValue!, -22.0/7.0, accuracy: 0.0001)
    }

    // MARK: - GPS helpers

    func testGPSCoordinateRoundTrip() {
        var structure = TIFFStructure(byteOrder: .bigEndian)
        structure.setGPSCoordinates(latitude: 51.5074, longitude: -0.1278, altitude: 11.0)

        XCTAssertNotNil(structure.latitude)
        XCTAssertNotNil(structure.longitude)
        XCTAssertEqual(structure.latitude!, 51.5074, accuracy: 0.0001)
        XCTAssertEqual(structure.longitude!, -0.1278, accuracy: 0.0001)
        XCTAssertEqual(structure.altitude!, 11.0, accuracy: 0.01)
    }

    func testGPSNegativeAltitude() {
        var structure = TIFFStructure(byteOrder: .bigEndian)
        structure.setGPSCoordinates(latitude: 31.5, longitude: 35.5, altitude: -400.0)
        XCTAssertEqual(structure.altitude!, -400.0, accuracy: 0.1)
    }

    func testGPSSouthernHemisphere() {
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.setGPSCoordinates(latitude: -33.8688, longitude: 151.2093)
        XCTAssertEqual(structure.latitude!, -33.8688, accuracy: 0.001)
        XCTAssertEqual(structure.longitude!, 151.2093, accuracy: 0.001)
    }

    // MARK: - Format Detection

    func testFormatDetection() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(ImageFormat.detect(from: jpeg), .jpeg)

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(ImageFormat.detect(from: png), .png)

        let tiffLE = Data([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(ImageFormat.detect(from: tiffLE), .tiff)

        let tiffBE = Data([0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(ImageFormat.detect(from: tiffBE), .tiff)

        // CR2: TIFF + "CR" at bytes 8-9
        let cr2 = Data([0x49, 0x49, 0x2A, 0x00, 0x10, 0x00, 0x00, 0x00, 0x43, 0x52, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(ImageFormat.detect(from: cr2), .cr2)

        // ORF: magic 0x4F52
        let orf = Data([0x49, 0x49, 0x52, 0x4F, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(ImageFormat.detect(from: orf), .orf)

        // RW2: magic 0x0055
        let rw2 = Data([0x49, 0x49, 0x55, 0x00, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertEqual(ImageFormat.detect(from: rw2), .rw2)

        let unknown = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        XCTAssertNil(ImageFormat.detect(from: unknown))
    }

    func testExtensionDetection() {
        XCTAssertEqual(ImageFormat.detect(fromExtension: "jpg"), .jpeg)
        XCTAssertEqual(ImageFormat.detect(fromExtension: "JPEG"), .jpeg)
        XCTAssertEqual(ImageFormat.detect(fromExtension: "png"), .png)
        XCTAssertEqual(ImageFormat.detect(fromExtension: "tif"), .tiff)
        XCTAssertEqual(ImageFormat.detect(fromExtension: "dng"), .dng)
        XCTAssertEqual(ImageFormat.detect(fromExtension: "cr2"), .cr2)
        XCTAssertEqual(ImageFormat.detect(fromExtension: "cr3"), .cr3)
        XCTAssertEqual(ImageFormat.detect(fromExtension: "nef"), .nef)
        XCTAssertEqual(ImageFormat.detect(fromExtension: "arw"), .arw)
        XCTAssertEqual(ImageFormat.detect(fromExtension: "raf"), .raf)
        XCTAssertEqual(ImageFormat.detect(fromExtension: "orf"), .orf)
        XCTAssertEqual(ImageFormat.detect(fromExtension: "rw2"), .rw2)
        XCTAssertEqual(ImageFormat.detect(fromExtension: "pef"), .pef)
        XCTAssertEqual(ImageFormat.detect(fromExtension: "heic"), .heif)
        XCTAssertEqual(ImageFormat.detect(fromExtension: "avif"), .heif)
        XCTAssertNil(ImageFormat.detect(fromExtension: "bmp"))
    }

    func testImageFormatProperties() {
        XCTAssertTrue(ImageFormat.cr2.isTIFFBased)
        XCTAssertTrue(ImageFormat.nef.isTIFFBased)
        XCTAssertTrue(ImageFormat.orf.isTIFFBased)
        XCTAssertFalse(ImageFormat.jpeg.isTIFFBased)
        XCTAssertFalse(ImageFormat.cr3.isTIFFBased)

        XCTAssertTrue(ImageFormat.cr3.isISOBMFF)
        XCTAssertTrue(ImageFormat.heif.isISOBMFF)
        XCTAssertFalse(ImageFormat.jpeg.isISOBMFF)
    }

    // MARK: - IFD Writer round-trip

    func testIFDWriteReadRoundTrip() throws {
        var ifd = IFD()
        ifd.set(tagID: Tag.make, value: .ascii("TestCamera"))
        ifd.set(tagID: Tag.model, value: .ascii("Model X"))
        ifd.set(tagID: Tag.orientation, value: .short(1))
        ifd.set(tagID: Tag.xResolution, value: .rational(URational(numerator: 72, denominator: 1)))

        let byteOrder = ByteOrder.littleEndian
        let written = IFDWriter.writeIFD(ifd, baseOffset: 0, byteOrder: byteOrder)
        let parsed = try IFDReader.readIFD(from: written, at: 0, byteOrder: byteOrder)

        XCTAssertEqual(parsed.entries.count, 4)
        XCTAssertEqual(parsed.value(for: Tag.make)?.stringValue, "TestCamera")
        XCTAssertEqual(parsed.value(for: Tag.model)?.stringValue, "Model X")
        XCTAssertEqual(parsed.value(for: Tag.orientation)?.uint32Value, 1)
        XCTAssertEqual(parsed.value(for: Tag.xResolution)?.doubleValue, 72.0)
    }

    // MARK: - TIFF Structure round-trip

    func testTIFFSerializeParseRoundTrip() throws {
        var structure = TIFFStructure(byteOrder: .bigEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Apple"))
        structure.ifd0.set(tagID: Tag.model, value: .ascii("iPhone 15 Pro"))
        structure.ifd0.set(tagID: Tag.orientation, value: .short(1))

        structure.exifIFD = IFD()
        structure.exifIFD!.set(tagID: Tag.isoSpeedRatings, value: .short(100))
        structure.exifIFD!.set(tagID: Tag.fNumber, value: .rational(URational(numerator: 18, denominator: 10)))
        structure.exifIFD!.set(tagID: Tag.lensModel, value: .ascii("iPhone 15 Pro back triple camera 6.765mm f/1.78"))

        structure.setGPSCoordinates(latitude: 37.7749, longitude: -122.4194)

        let tiffData = TIFFSerializer.serialize(structure)
        let parsed = try TIFFParser.parse(tiffData)

        XCTAssertEqual(parsed.make, "Apple")
        XCTAssertEqual(parsed.model, "iPhone 15 Pro")
        XCTAssertEqual(parsed.orientation, 1)
        XCTAssertEqual(parsed.iso, 100)
        XCTAssertNotNil(parsed.fNumber)
        XCTAssertEqual(parsed.fNumber!, 1.8, accuracy: 0.01)
        XCTAssertEqual(parsed.lensModel, "iPhone 15 Pro back triple camera 6.765mm f/1.78")
        XCTAssertEqual(parsed.latitude!, 37.7749, accuracy: 0.001)
        XCTAssertEqual(parsed.longitude!, -122.4194, accuracy: 0.001)
    }

    // MARK: - Convenience accessors

    func testConvenienceAccessors() throws {
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("NIKON CORPORATION"))
        structure.ifd0.set(tagID: Tag.model, value: .ascii("NIKON Z 8"))
        structure.ifd0.set(tagID: Tag.imageDescription, value: .ascii("Test Photo"))
        structure.ifd0.set(tagID: Tag.artist, value: .ascii("Photographer"))
        structure.ifd0.set(tagID: Tag.copyright, value: .ascii("2024"))
        structure.ifd0.set(tagID: Tag.software, value: .ascii("EXIFKit"))

        structure.exifIFD = IFD()
        structure.exifIFD!.set(tagID: Tag.dateTimeOriginal, value: .ascii("2024:01:15 14:30:00"))
        structure.exifIFD!.set(tagID: Tag.dateTimeDigitized, value: .ascii("2024:01:15 14:30:00"))
        structure.exifIFD!.set(tagID: Tag.offsetTimeOriginal, value: .ascii("+09:00"))
        structure.exifIFD!.set(tagID: Tag.focalLength35mm, value: .short(50))
        structure.exifIFD!.set(tagID: Tag.exposureBias, value: .srational(SRational(numerator: -1, denominator: 3)))
        structure.exifIFD!.set(tagID: Tag.lensMake, value: .ascii("NIKKOR"))
        structure.exifIFD!.set(tagID: Tag.flash, value: .short(0x0001)) // fired
        structure.exifIFD!.set(tagID: Tag.colorSpace, value: .short(1)) // sRGB
        structure.exifIFD!.set(tagID: Tag.pixelXDimension, value: .long(8256))
        structure.exifIFD!.set(tagID: Tag.pixelYDimension, value: .long(5504))

        XCTAssertEqual(structure.imageDescription, "Test Photo")
        XCTAssertEqual(structure.artist, "Photographer")
        XCTAssertEqual(structure.copyright, "2024")
        XCTAssertEqual(structure.dateTimeDigitized, "2024:01:15 14:30:00")
        XCTAssertEqual(structure.offsetTimeOriginal, "+09:00")
        XCTAssertEqual(structure.focalLength35mm, 50)
        XCTAssertEqual(structure.exposureBias!, -1.0/3.0, accuracy: 0.001)
        XCTAssertEqual(structure.lensMake, "NIKKOR")
        XCTAssertEqual(structure.flashFired, true)
        XCTAssertEqual(structure.colorSpace, 1)
        XCTAssertEqual(structure.pixelWidth, 8256)
        XCTAssertEqual(structure.pixelHeight, 5504)
    }

    // MARK: - Error descriptions

    func testErrorDescriptions() {
        let err1 = EXIFError.invalidJPEG("no SOI")
        XCTAssertTrue(err1.description.contains("JPEG"))
        XCTAssertNotNil(err1.errorDescription)

        let err2 = EXIFError.invalidHEIF("no meta")
        XCTAssertTrue(err2.description.contains("HEIF"))

        let err3 = EXIFError.writeFailed("size mismatch")
        XCTAssertTrue(err3.description.contains("Write"))
    }

    // MARK: - Rational number edge cases

    func testRationalZeroDenominator() {
        let r = URational(numerator: 1, denominator: 0)
        XCTAssertEqual(r.doubleValue, 0) // Not NaN or crash

        let sr = SRational(numerator: -1, denominator: 0)
        XCTAssertEqual(sr.doubleValue, 0)
    }

    func testRationalFromDouble() {
        let r = URational(3.14159)
        XCTAssertEqual(r.doubleValue, 3.14159, accuracy: 0.001)

        let sr = SRational(-2.5)
        XCTAssertEqual(sr.doubleValue, -2.5, accuracy: 0.001)
    }

    // MARK: - CRC32 (PNG)

    func testPNGRoundTrip() throws {
        // Build a minimal valid PNG
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var png = signature

        // IHDR chunk (13 bytes of data)
        let ihdrData = Data([
            0x00, 0x00, 0x00, 0x01, // width = 1
            0x00, 0x00, 0x00, 0x01, // height = 1
            0x08,                   // bit depth = 8
            0x02,                   // color type = RGB
            0x00, 0x00, 0x00        // compression, filter, interlace
        ])
        png.append(buildPNGChunk(type: "IHDR", data: ihdrData))

        // Minimal IDAT
        let idatData = Data([0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01])
        png.append(buildPNGChunk(type: "IDAT", data: idatData))

        // IEND
        png.append(buildPNGChunk(type: "IEND", data: Data()))

        // Create EXIF structure and write it into the PNG
        var structure = TIFFStructure(byteOrder: .bigEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("TestCam"))
        let withExif = try PNGContainer.writeEXIF(
            TIFFStructure(byteOrder: .bigEndian, ifd0: structure.ifd0),
            to: png
        )

        // Read it back
        let parsed = try PNGContainer.readEXIF(from: withExif)
        XCTAssertEqual(parsed.make, "TestCam")

        // Strip and verify
        let stripped = try PNGContainer.stripEXIF(from: withExif)
        XCTAssertThrowsError(try PNGContainer.readEXIF(from: stripped))
    }

    private func buildPNGChunk(type: String, data: Data) -> Data {
        var chunk = Data()
        var length = UInt32(data.count).bigEndian
        chunk.append(Data(bytes: &length, count: 4))
        let typeBytes = Array(type.utf8)
        chunk.append(contentsOf: typeBytes)
        chunk.append(data)
        // CRC32
        var crcInput = Data(typeBytes)
        crcInput.append(data)
        var crc = crc32(crcInput).bigEndian
        chunk.append(Data(bytes: &crc, count: 4))
        return chunk
    }

    private func crc32(_ data: Data) -> UInt32 {
        let table: [UInt32] = (0..<256).map { n -> UInt32 in
            var c = UInt32(n)
            for _ in 0..<8 {
                c = (c & 1 != 0) ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }

    // MARK: - Dump

    func testDumpOutput() {
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Apple"))
        structure.ifd0.set(tagID: Tag.model, value: .ascii("iPhone"))
        structure.exifIFD = IFD()
        structure.exifIFD!.set(tagID: Tag.isoSpeedRatings, value: .short(800))
        structure.setGPSCoordinates(latitude: 37.0, longitude: -122.0)

        let dump = EXIFKit.dump(structure)
        XCTAssertTrue(dump.contains("Apple"))
        XCTAssertTrue(dump.contains("iPhone"))
        XCTAssertTrue(dump.contains("800"))
        XCTAssertTrue(dump.contains("37.0"))
        XCTAssertTrue(dump.contains("Byte Order"))
    }

    // MARK: - JPEG Full Round-Trip

    private func buildMinimalJPEG() -> Data {
        var jpeg = Data()
        jpeg.append(contentsOf: [0xFF, 0xD8]) // SOI
        jpeg.append(contentsOf: [0xFF, 0xE0]) // APP0
        let jfifPayload = Data([0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00])
        let jfifLen = UInt16(jfifPayload.count + 2)
        jpeg.append(UInt8(jfifLen >> 8))
        jpeg.append(UInt8(jfifLen & 0xFF))
        jpeg.append(jfifPayload)
        jpeg.append(contentsOf: [0xFF, 0xDA, 0x00, 0x08, 0x01, 0x00, 0x00, 0x3F, 0x00, 0x7B])
        jpeg.append(contentsOf: [0x00, 0x01, 0x02, 0x03])
        jpeg.append(contentsOf: [0xFF, 0xD9]) // EOI
        return jpeg
    }

    func testJPEGWriteReadRoundTrip() throws {
        let jpeg = buildMinimalJPEG()
        XCTAssertEqual(ImageFormat.detect(from: jpeg), .jpeg)

        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("TestCamera"))
        structure.ifd0.set(tagID: Tag.model, value: .ascii("Model X"))
        structure.ifd0.set(tagID: Tag.orientation, value: .short(1))

        structure.exifIFD = IFD()
        structure.exifIFD!.set(tagID: Tag.isoSpeedRatings, value: .short(400))
        structure.exifIFD!.set(tagID: Tag.fNumber, value: .rational(URational(numerator: 28, denominator: 10)))
        structure.exifIFD!.set(tagID: Tag.dateTimeOriginal, value: .ascii("2024:06:15 10:30:00"))

        let withExif = try EXIFKit.write(structure, to: jpeg)
        let parsed = try EXIFKit.read(from: withExif)

        XCTAssertEqual(parsed.make, "TestCamera")
        XCTAssertEqual(parsed.model, "Model X")
        XCTAssertEqual(parsed.orientation, 1)
        XCTAssertEqual(parsed.iso, 400)
        XCTAssertEqual(parsed.fNumber!, 2.8, accuracy: 0.01)
        XCTAssertEqual(parsed.dateTimeOriginal, "2024:06:15 10:30:00")
    }

    func testJPEGWriteWithGPSThenModify() throws {
        let jpeg = buildMinimalJPEG()

        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Camera"))
        structure.setGPSCoordinates(latitude: 51.5074, longitude: -0.1278, altitude: 30.0)

        let withGPS = try EXIFKit.write(structure, to: jpeg)
        let parsed = try EXIFKit.read(from: withGPS)
        XCTAssertEqual(parsed.latitude!, 51.5074, accuracy: 0.001)
        XCTAssertEqual(parsed.longitude!, -0.1278, accuracy: 0.001)
        XCTAssertEqual(parsed.altitude!, 30.0, accuracy: 0.1)

        // Modify GPS
        var modified = parsed
        modified.setGPSCoordinates(latitude: 48.8566, longitude: 2.3522)
        modified.ifd0.set(tagID: Tag.software, value: .ascii("EXIFKit"))

        let rewritten = try EXIFKit.write(modified, to: withGPS)
        let reparsed = try EXIFKit.read(from: rewritten)
        XCTAssertEqual(reparsed.software, "EXIFKit")
        XCTAssertEqual(reparsed.latitude!, 48.8566, accuracy: 0.001)
        XCTAssertEqual(reparsed.longitude!, 2.3522, accuracy: 0.001)
    }

    func testJPEGStripEXIF() throws {
        let jpeg = buildMinimalJPEG()

        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Camera"))
        let withExif = try EXIFKit.write(structure, to: jpeg)

        // Verify EXIF exists
        let _ = try EXIFKit.read(from: withExif)

        // Strip
        let stripped = try EXIFKit.strip(from: withExif)
        XCTAssertThrowsError(try EXIFKit.read(from: stripped))
    }

    // MARK: - TIFF Container Round-Trip

    func testTIFFContainerAddGPS() throws {
        // Build a minimal TIFF
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Nikon"))
        structure.ifd0.set(tagID: Tag.model, value: .ascii("Z 8"))
        structure.exifIFD = IFD()
        structure.exifIFD!.set(tagID: Tag.isoSpeedRatings, value: .short(200))
        let tiff = TIFFSerializer.serialize(structure)

        let parsed = try EXIFKit.read(from: tiff, format: .tiff)
        XCTAssertEqual(parsed.make, "Nikon")
        XCTAssertNil(parsed.gpsIFD)

        // Add GPS
        var modified = parsed
        modified.setGPSCoordinates(latitude: 35.6762, longitude: 139.6503)
        let written = try EXIFKit.write(modified, to: tiff)
        let reparsed = try EXIFKit.read(from: written, format: .tiff)

        XCTAssertEqual(reparsed.make, "Nikon")
        XCTAssertEqual(reparsed.model, "Z 8")
        XCTAssertEqual(reparsed.iso, 200)
        XCTAssertEqual(reparsed.latitude!, 35.6762, accuracy: 0.001)
        XCTAssertEqual(reparsed.longitude!, 139.6503, accuracy: 0.001)
    }

    // MARK: - Big Endian Round-Trip

    func testBigEndianTIFFRoundTrip() throws {
        var structure = TIFFStructure(byteOrder: .bigEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Canon"))
        structure.exifIFD = IFD()
        structure.exifIFD!.set(tagID: Tag.lensSpecification, value: .rationals([
            URational(numerator: 24, denominator: 1),
            URational(numerator: 105, denominator: 1),
            URational(numerator: 40, denominator: 10),
            URational(numerator: 40, denominator: 10)
        ]))
        structure.exifIFD!.set(tagID: Tag.exifVersion, value: .undefined(Data([0x30, 0x32, 0x33, 0x32])))

        let tiffData = TIFFSerializer.serialize(structure)
        let parsed = try TIFFParser.parse(tiffData)

        XCTAssertEqual(parsed.make, "Canon")
        if case .rationals(let rats) = parsed.exifIFD?.value(for: Tag.lensSpecification) {
            XCTAssertEqual(rats.count, 4)
            XCTAssertEqual(rats[0].doubleValue, 24.0)
            XCTAssertEqual(rats[1].doubleValue, 105.0)
        } else {
            XCTFail("Expected rationals for lens spec")
        }
        if case .undefined(let data) = parsed.exifIFD?.value(for: Tag.exifVersion) {
            XCTAssertEqual(String(data: data, encoding: .ascii), "0232")
        } else {
            XCTFail("Expected undefined for exif version")
        }
    }

    // MARK: - All IFD Array Types Round-Trip

    func testArrayDataTypesRoundTrip() throws {
        var ifd = IFD()
        ifd.set(tagID: 0xF001, value: .float(3.14))
        ifd.set(tagID: 0xF002, value: .double(2.71828))
        ifd.set(tagID: 0xF003, value: .floats([1.0, 2.0, 3.0]))
        ifd.set(tagID: 0xF004, value: .doubles([4.0, 5.0]))
        ifd.set(tagID: 0xF005, value: .shorts([100, 200, 300]))
        ifd.set(tagID: 0xF006, value: .longs([1000, 2000]))
        ifd.set(tagID: 0xF007, value: .signedShorts([-1, -2, -3]))
        ifd.set(tagID: 0xF008, value: .signedLongs([-100, -200]))
        ifd.set(tagID: 0xF009, value: .srationals([
            SRational(numerator: -1, denominator: 3),
            SRational(numerator: 2, denominator: 3)
        ]))
        ifd.set(tagID: 0xF00A, value: .bytes([0x01, 0x02, 0x03, 0x04, 0x05]))
        ifd.set(tagID: 0xF00B, value: .signedBytes([-1, -2, 3, 4]))

        let written = IFDWriter.writeIFD(ifd, baseOffset: 0, byteOrder: .littleEndian)
        let parsed = try IFDReader.readIFD(from: written, at: 0, byteOrder: .littleEndian)

        if case .float(let f) = parsed.value(for: 0xF001) {
            XCTAssertEqual(f, 3.14, accuracy: 0.001)
        } else { XCTFail("float") }

        if case .double(let d) = parsed.value(for: 0xF002) {
            XCTAssertEqual(d, 2.71828, accuracy: 0.0001)
        } else { XCTFail("double") }

        if case .floats(let fs) = parsed.value(for: 0xF003) {
            XCTAssertEqual(fs, [1.0, 2.0, 3.0])
        } else { XCTFail("floats") }

        if case .doubles(let ds) = parsed.value(for: 0xF004) {
            XCTAssertEqual(ds, [4.0, 5.0])
        } else { XCTFail("doubles") }

        if case .shorts(let ss) = parsed.value(for: 0xF005) {
            XCTAssertEqual(ss, [100, 200, 300])
        } else { XCTFail("shorts") }

        if case .longs(let ls) = parsed.value(for: 0xF006) {
            XCTAssertEqual(ls, [1000, 2000])
        } else { XCTFail("longs") }

        if case .signedShorts(let ss) = parsed.value(for: 0xF007) {
            XCTAssertEqual(ss, [-1, -2, -3])
        } else { XCTFail("signedShorts") }

        if case .signedLongs(let sl) = parsed.value(for: 0xF008) {
            XCTAssertEqual(sl, [-100, -200])
        } else { XCTFail("signedLongs") }

        if case .srationals(let srs) = parsed.value(for: 0xF009) {
            XCTAssertEqual(srs.count, 2)
            XCTAssertEqual(srs[0].numerator, -1)
            XCTAssertEqual(srs[0].denominator, 3)
        } else { XCTFail("srationals") }

        if case .bytes(let bs) = parsed.value(for: 0xF00A) {
            XCTAssertEqual(bs, [0x01, 0x02, 0x03, 0x04, 0x05])
        } else { XCTFail("bytes") }

        if case .signedBytes(let sbs) = parsed.value(for: 0xF00B) {
            XCTAssertEqual(sbs, [-1, -2, 3, 4])
        } else { XCTFail("signedBytes") }
    }

    // MARK: - PNG Write + Modify Round-Trip

    func testPNGWriteModifyRoundTrip() throws {
        // Build minimal PNG
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var png = signature
        let ihdrData = Data([
            0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00
        ])
        png.append(buildPNGChunk(type: "IHDR", data: ihdrData))
        let idatData = Data([0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01])
        png.append(buildPNGChunk(type: "IDAT", data: idatData))
        png.append(buildPNGChunk(type: "IEND", data: Data()))

        // Write initial EXIF
        var s = TIFFStructure(byteOrder: .bigEndian)
        s.ifd0.set(tagID: Tag.make, value: .ascii("TestCam"))
        s.exifIFD = IFD()
        s.exifIFD!.set(tagID: Tag.isoSpeedRatings, value: .short(100))
        s.setGPSCoordinates(latitude: 37.0, longitude: -122.0)

        let withExif = try PNGContainer.writeEXIF(s, to: png)
        let parsed = try PNGContainer.readEXIF(from: withExif)
        XCTAssertEqual(parsed.make, "TestCam")
        XCTAssertEqual(parsed.iso, 100)
        XCTAssertEqual(parsed.latitude!, 37.0, accuracy: 0.01)

        // Modify
        var modified = parsed
        modified.setGPSCoordinates(latitude: 48.0, longitude: 2.0)
        let rewritten = try PNGContainer.writeEXIF(modified, to: withExif)
        let reparsed = try PNGContainer.readEXIF(from: rewritten)
        XCTAssertEqual(reparsed.make, "TestCam")
        XCTAssertEqual(reparsed.latitude!, 48.0, accuracy: 0.01)
        XCTAssertEqual(reparsed.longitude!, 2.0, accuracy: 0.01)
    }

    // MARK: - EXIFKit Auto-Detection Integration

    func testAutoDetectJPEG() throws {
        let jpeg = buildMinimalJPEG()
        var s = TIFFStructure(byteOrder: .littleEndian)
        s.ifd0.set(tagID: Tag.make, value: .ascii("Auto"))
        let withExif = try EXIFKit.write(s, to: jpeg)
        let parsed = try EXIFKit.read(from: withExif)
        XCTAssertEqual(parsed.make, "Auto")
    }

    func testAutoDetectPNG() throws {
        let signature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        var png = signature
        let ihdr = Data([0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01, 0x08, 0x02, 0x00, 0x00, 0x00])
        png.append(buildPNGChunk(type: "IHDR", data: ihdr))
        let idat = Data([0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00, 0x00, 0x00, 0x03, 0x00, 0x01])
        png.append(buildPNGChunk(type: "IDAT", data: idat))
        png.append(buildPNGChunk(type: "IEND", data: Data()))

        var s = TIFFStructure(byteOrder: .bigEndian)
        s.ifd0.set(tagID: Tag.make, value: .ascii("PNGCam"))
        let withExif = try EXIFKit.write(s, to: png)
        let parsed = try EXIFKit.read(from: withExif)
        XCTAssertEqual(parsed.make, "PNGCam")
    }

    func testUnsupportedFormat() {
        let garbage = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        XCTAssertThrowsError(try EXIFKit.read(from: garbage))
    }

    // MARK: - Tag Name Lookup

    func testTagNameLookup() {
        XCTAssertEqual(Tag.name(for: Tag.make), "Make")
        XCTAssertEqual(Tag.name(for: Tag.model), "Model")
        XCTAssertTrue(Tag.name(for: 0xFFFF).contains("Unknown"))
        XCTAssertEqual(Tag.gpsName(for: Tag.gpsLatitude), "GPSLatitude")
        XCTAssertTrue(Tag.gpsName(for: 0xFFFF).contains("Unknown"))
    }

    // MARK: - IFD Writer Big Endian

    func testIFDWriteReadBigEndian() throws {
        var ifd = IFD()
        ifd.set(tagID: Tag.make, value: .ascii("BigEndianCam"))
        ifd.set(tagID: Tag.orientation, value: .short(6))
        ifd.set(tagID: Tag.xResolution, value: .rational(URational(numerator: 300, denominator: 1)))

        let written = IFDWriter.writeIFD(ifd, baseOffset: 0, byteOrder: .bigEndian)
        let parsed = try IFDReader.readIFD(from: written, at: 0, byteOrder: .bigEndian)

        XCTAssertEqual(parsed.value(for: Tag.make)?.stringValue, "BigEndianCam")
        XCTAssertEqual(parsed.value(for: Tag.orientation)?.uint32Value, 6)
        XCTAssertEqual(parsed.value(for: Tag.xResolution)?.doubleValue, 300.0)
    }

    // MARK: - MakerNote Passthrough

    func testMakerNotePreservedAsUndefined() throws {
        // Simulate a MakerNote blob surviving a TIFF round-trip
        var structure = TIFFStructure(byteOrder: .littleEndian)
        structure.ifd0.set(tagID: Tag.make, value: .ascii("Canon"))
        structure.exifIFD = IFD()
        let fakeNote = Data(repeating: 0xAB, count: 256)
        structure.exifIFD!.set(tagID: Tag.makerNote, value: .undefined(fakeNote))

        let tiffData = TIFFSerializer.serialize(structure)
        let parsed = try TIFFParser.parse(tiffData)

        if case .undefined(let data) = parsed.exifIFD?.value(for: Tag.makerNote) {
            XCTAssertEqual(data.count, 256)
            XCTAssertEqual(data[0], 0xAB)
        } else {
            XCTFail("MakerNote should be preserved as undefined")
        }
    }
}
