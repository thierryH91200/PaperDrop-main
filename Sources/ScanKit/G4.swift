import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// CCITT G4 encoding via ImageIO, and extraction of the raw G4 stream
/// from the TIFF container so it can be embedded in a PDF losslessly.
public enum G4 {
    /// Encode a processed 1-bit page as a G4-compressed TIFF (bytes).
    public static func tiff(from page: Pipeline.ProcessedPage) throws -> Data {
        guard let img = page.cgImage else {
            throw ScanError.scanFailed("Cannot build 1-bit image")
        }
        let dpi = page.dpi
        guard
            let data = ImageEncode.encode(
                img, uti: UTType.tiff.identifier as CFString,
                properties: [
                    kCGImagePropertyTIFFDictionary: [
                        kCGImagePropertyTIFFCompression: 4,
                        kCGImagePropertyTIFFXResolution: dpi,
                        kCGImagePropertyTIFFYResolution: dpi,
                    ],
                    kCGImagePropertyDPIWidth: dpi,
                    kCGImagePropertyDPIHeight: dpi,
                ]
            )
        else { throw ScanError.scanFailed("TIFF encode failed") }
        return data
    }

    public struct Stream {
        public let data: Data  // raw G4 codestream
        public let width: Int
        public let height: Int
        public let minIsBlack: Bool  // photometric: true → 0 bits are black
    }

    /// Extract the G4 codestream from a single-strip G4 TIFF.
    public static func extractStream(fromTIFF tiff: Data) throws -> Stream {
        func fail(_ s: String) -> ScanError {
            .scanFailed("TIFF parse: \(s)")
        }
        guard tiff.count > 8 else { throw fail("too short") }
        let big: Bool
        switch (tiff[0], tiff[1]) {
        case (0x4D, 0x4D): big = true
        case (0x49, 0x49): big = false
        default: throw fail("bad byte order")
        }
        func u16(_ o: Int) -> Int {
            let a = Int(tiff[o]), b = Int(tiff[o + 1])
            return big ? a << 8 | b : b << 8 | a
        }
        func u32(_ o: Int) -> Int {
            let a = Int(tiff[o]), b = Int(tiff[o + 1]),
                c = Int(tiff[o + 2]), d = Int(tiff[o + 3])
            return big
                ? a << 24 | b << 16 | c << 8 | d
                : d << 24 | c << 16 | b << 8 | a
        }
        let ifd = u32(4)
        let count = u16(ifd)
        var width = 0, height = 0, photometric = 0, compression = 0
        var stripOffset = -1, stripBytes = -1, stripCount = 0
        for i in 0..<count {
            let e = ifd + 2 + i * 12
            let tag = u16(e), n = u32(e + 4)
            let value = u16(e + 2) == 3 ? u16(e + 8) : u32(e + 8)
            switch tag {
            case 256: width = value
            case 257: height = value
            case 259: compression = value
            case 262: photometric = value
            case 273:
                stripCount = n
                stripOffset = n == 1 ? value : u32(e + 8)
            case 279: stripBytes = n == 1 ? value : u32(e + 8)
            default: break
            }
        }
        guard compression == 4 else { throw fail("not G4 (compression \(compression))") }
        guard stripCount == 1 else { throw fail("multi-strip (\(stripCount))") }
        guard stripOffset >= 0, stripBytes > 0,
            stripOffset + stripBytes <= tiff.count
        else { throw fail("bad strip") }
        return Stream(
            data: tiff.subdata(in: stripOffset..<(stripOffset + stripBytes)),
            width: width, height: height,
            minIsBlack: photometric == 1
        )
    }
}
