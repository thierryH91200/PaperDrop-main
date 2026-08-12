import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public extension Pipeline.ProcessedPage {
    /// The 1-bit page as a CGImage (for thumbnails and OCR).
    var cgImage: CGImage? {
        let rowBytes = (width + 7) / 8
        guard let provider = CGDataProvider(data: packed as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 1, bitsPerPixel: 1,
            bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent
        )
    }
}

public extension Pipeline.GrayImage {
    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent
        )
    }

    func cropped(_ c: Pipeline.Crop) -> Pipeline.GrayImage {
        let cw = c.x1 - c.x0, ch = c.y1 - c.y0
        var out = [UInt8](repeating: 0, count: cw * ch)
        for y in 0..<ch {
            let src = (y + c.y0) * width + c.x0
            out.replaceSubrange(
                y * cw..<(y * cw + cw),
                with: pixels[src..<(src + cw)]
            )
        }
        return Pipeline.GrayImage(width: cw, height: ch, pixels: out)
    }
}

public extension Pipeline {
    /// A colour scan held as an RGBA buffer. Deliberately mirrors GrayImage
    /// (same context orientation, same crop maths) so a colour page crops and
    /// renders exactly like the grayscale path does.
    struct ColorImage {
        public let width: Int
        public let height: Int
        public var pixels: [UInt8]  // RGBA, 4 bytes/px
        public init(width: Int, height: Int, pixels: [UInt8]) {
            self.width = width
            self.height = height
            self.pixels = pixels
        }

        public func cropped(_ c: Pipeline.Crop) -> ColorImage {
            let cw = c.x1 - c.x0, ch = c.y1 - c.y0
            var out = [UInt8](repeating: 0, count: cw * ch * 4)
            for y in 0..<ch {
                let src = ((y + c.y0) * width + c.x0) * 4
                out.replaceSubrange(
                    (y * cw * 4)..<(y * cw * 4 + cw * 4),
                    with: pixels[src..<(src + cw * 4)]
                )
            }
            return ColorImage(width: cw, height: ch, pixels: out)
        }

        public var cgImage: CGImage? {
            guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
            return CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil,
                shouldInterpolate: true, intent: .defaultIntent
            )
        }

        /// Rec.601 luminance copy, so crop analysis can run on colour scans
        /// without decoding the source file a second time.
        public func grayscale() -> Pipeline.GrayImage {
            var out = [UInt8](repeating: 0, count: width * height)
            for i in 0..<(width * height) {
                let r = Double(pixels[i * 4])
                let g = Double(pixels[i * 4 + 1])
                let b = Double(pixels[i * 4 + 2])
                out[i] = UInt8((0.299 * r + 0.587 * g + 0.114 * b).rounded())
            }
            return Pipeline.GrayImage(width: width, height: height, pixels: out)
        }
    }

    /// Load a scan in colour (RGBA), the colour counterpart of loadGray.
    static func loadColor(_ url: URL) throws -> ColorImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            throw ScanError.scanFailed(String(localized: "Cannot read image \(url.lastPathComponent)"))
        }
        let w = img.width, h = img.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        pixels.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return ColorImage(width: w, height: h, pixels: pixels)
    }
}

/// Decode compressed image data (e.g. a stored JPEG) back to a CGImage,
/// so a page's text layer can be OCR'd lazily from what will be embedded.
public enum ImageDecode {
    public static func cgImage(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// Shared ImageIO encoding (used for JPEG pages and G4 TIFFs).
public enum ImageEncode {
    public static func jpeg(
        _ image: CGImage, quality: Double = 0.7,
        dpi: Int
    ) -> Data? {
        encode(
            image, uti: UTType.jpeg.identifier as CFString,
            properties: [
                kCGImageDestinationLossyCompressionQuality: quality,
                kCGImagePropertyDPIWidth: dpi,
                kCGImagePropertyDPIHeight: dpi,
            ]
        )
    }

    static func encode(
        _ image: CGImage, uti: CFString,
        properties: [CFString: Any]
    ) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, uti, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
