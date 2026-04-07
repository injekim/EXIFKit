import Foundation

// MARK: - Tag Definitions

/// Well-known EXIF/TIFF/GPS tag IDs.
///
/// Not exhaustive — covers the most commonly used tags.
/// Unknown tags are still parsed; they just won't have a human-readable name.
public enum Tag {

    // MARK: TIFF Baseline (IFD0 / IFD1)
    public static let imageWidth:       UInt16 = 0x0100
    public static let imageHeight:      UInt16 = 0x0101
    public static let bitsPerSample:    UInt16 = 0x0102
    public static let compression:      UInt16 = 0x0103
    public static let photometricInterpretation: UInt16 = 0x0106
    public static let imageDescription: UInt16 = 0x010E
    public static let make:             UInt16 = 0x010F
    public static let model:            UInt16 = 0x0110
    public static let stripOffsets:     UInt16 = 0x0111
    public static let orientation:      UInt16 = 0x0112
    public static let samplesPerPixel:  UInt16 = 0x0115
    public static let rowsPerStrip:     UInt16 = 0x0116
    public static let stripByteCounts:  UInt16 = 0x0117
    public static let xResolution:      UInt16 = 0x011A
    public static let yResolution:      UInt16 = 0x011B
    public static let planarConfiguration: UInt16 = 0x011C
    public static let resolutionUnit:   UInt16 = 0x0128
    public static let software:         UInt16 = 0x0131
    public static let dateTime:         UInt16 = 0x0132
    public static let artist:           UInt16 = 0x013B
    public static let copyright:        UInt16 = 0x8298

    // MARK: Pointers to sub-IFDs
    public static let exifIFDPointer:   UInt16 = 0x8769
    public static let gpsIFDPointer:    UInt16 = 0x8825

    // MARK: EXIF sub-IFD
    public static let exposureTime:     UInt16 = 0x829A
    public static let fNumber:          UInt16 = 0x829D
    public static let exposureProgram:  UInt16 = 0x8822
    public static let isoSpeedRatings:  UInt16 = 0x8827
    public static let exifVersion:      UInt16 = 0x9000
    public static let dateTimeOriginal: UInt16 = 0x9003
    public static let dateTimeDigitized: UInt16 = 0x9004
    public static let offsetTime:       UInt16 = 0x9010
    public static let offsetTimeOriginal: UInt16 = 0x9011
    public static let shutterSpeedValue: UInt16 = 0x9201
    public static let apertureValue:    UInt16 = 0x9202
    public static let brightnessValue:  UInt16 = 0x9203
    public static let exposureBias:     UInt16 = 0x9204
    public static let maxAperture:      UInt16 = 0x9205
    public static let meteringMode:     UInt16 = 0x9207
    public static let lightSource:      UInt16 = 0x9208
    public static let flash:            UInt16 = 0x9209
    public static let focalLength:      UInt16 = 0x920A
    public static let makerNote:        UInt16 = 0x927C
    public static let userComment:      UInt16 = 0x9286
    public static let subSecTime:       UInt16 = 0x9290
    public static let subSecTimeOriginal: UInt16 = 0x9291
    public static let subSecTimeDigitized: UInt16 = 0x9292
    public static let colorSpace:       UInt16 = 0xA001
    public static let pixelXDimension:  UInt16 = 0xA002
    public static let pixelYDimension:  UInt16 = 0xA003
    public static let focalPlaneXRes:   UInt16 = 0xA20E
    public static let focalPlaneYRes:   UInt16 = 0xA20F
    public static let focalPlaneResUnit: UInt16 = 0xA210
    public static let sensingMethod:    UInt16 = 0xA217
    public static let customRendered:   UInt16 = 0xA401
    public static let exposureMode:     UInt16 = 0xA402
    public static let whiteBalance:     UInt16 = 0xA403
    public static let digitalZoomRatio: UInt16 = 0xA404
    public static let focalLength35mm:  UInt16 = 0xA405
    public static let sceneCaptureType: UInt16 = 0xA406
    public static let lensModel:        UInt16 = 0xA434
    public static let lensMake:         UInt16 = 0xA433
    public static let lensSpecification: UInt16 = 0xA432

    // MARK: GPS IFD
    public static let gpsVersionID:     UInt16 = 0x0000
    public static let gpsLatitudeRef:   UInt16 = 0x0001
    public static let gpsLatitude:      UInt16 = 0x0002
    public static let gpsLongitudeRef:  UInt16 = 0x0003
    public static let gpsLongitude:     UInt16 = 0x0004
    public static let gpsAltitudeRef:   UInt16 = 0x0005
    public static let gpsAltitude:      UInt16 = 0x0006
    public static let gpsTimeStamp:     UInt16 = 0x0007
    public static let gpsSatellites:    UInt16 = 0x0008
    public static let gpsMapDatum:      UInt16 = 0x0012
    public static let gpsDateStamp:     UInt16 = 0x001D

    // MARK: Tag Name Lookup

    /// Human-readable name for a tag in the TIFF/EXIF IFD
    public static func name(for tagID: UInt16) -> String {
        tiffExifNames[tagID] ?? "Unknown(0x\(String(tagID, radix: 16, uppercase: true)))"
    }

    /// Human-readable name for a tag in the GPS IFD
    public static func gpsName(for tagID: UInt16) -> String {
        gpsNames[tagID] ?? "GPSUnknown(0x\(String(tagID, radix: 16, uppercase: true)))"
    }

    private static let tiffExifNames: [UInt16: String] = [
        imageWidth: "ImageWidth",
        imageHeight: "ImageHeight",
        bitsPerSample: "BitsPerSample",
        compression: "Compression",
        imageDescription: "ImageDescription",
        make: "Make",
        model: "Model",
        orientation: "Orientation",
        xResolution: "XResolution",
        yResolution: "YResolution",
        resolutionUnit: "ResolutionUnit",
        software: "Software",
        dateTime: "DateTime",
        artist: "Artist",
        copyright: "Copyright",
        exifIFDPointer: "ExifIFDPointer",
        gpsIFDPointer: "GPSInfoIFDPointer",
        exposureTime: "ExposureTime",
        fNumber: "FNumber",
        exposureProgram: "ExposureProgram",
        isoSpeedRatings: "ISOSpeedRatings",
        exifVersion: "ExifVersion",
        dateTimeOriginal: "DateTimeOriginal",
        dateTimeDigitized: "DateTimeDigitized",
        offsetTime: "OffsetTime",
        offsetTimeOriginal: "OffsetTimeOriginal",
        shutterSpeedValue: "ShutterSpeedValue",
        apertureValue: "ApertureValue",
        brightnessValue: "BrightnessValue",
        exposureBias: "ExposureBiasValue",
        maxAperture: "MaxApertureValue",
        meteringMode: "MeteringMode",
        lightSource: "LightSource",
        flash: "Flash",
        focalLength: "FocalLength",
        makerNote: "MakerNote",
        userComment: "UserComment",
        colorSpace: "ColorSpace",
        pixelXDimension: "PixelXDimension",
        pixelYDimension: "PixelYDimension",
        focalLength35mm: "FocalLengthIn35mmFilm",
        lensModel: "LensModel",
        lensMake: "LensMake",
        lensSpecification: "LensSpecification",
        exposureMode: "ExposureMode",
        whiteBalance: "WhiteBalance",
        sceneCaptureType: "SceneCaptureType",
    ]

    private static let gpsNames: [UInt16: String] = [
        gpsVersionID: "GPSVersionID",
        gpsLatitudeRef: "GPSLatitudeRef",
        gpsLatitude: "GPSLatitude",
        gpsLongitudeRef: "GPSLongitudeRef",
        gpsLongitude: "GPSLongitude",
        gpsAltitudeRef: "GPSAltitudeRef",
        gpsAltitude: "GPSAltitude",
        gpsTimeStamp: "GPSTimeStamp",
        gpsSatellites: "GPSSatellites",
        gpsMapDatum: "GPSMapDatum",
        gpsDateStamp: "GPSDateStamp",
    ]
}
