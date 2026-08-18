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

    /// Apply a tone curve (from Pipeline.toneLUT) to every pixel.
    func toneMapped(_ lut: [UInt8]) -> Pipeline.GrayImage {
        Pipeline.GrayImage(width: width, height: height, pixels: pixels.map { lut[Int($0)] })
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

        /// Apply a tone curve (from Pipeline.toneLUT) to R, G and B.
        public func toneMapped(_ lut: [UInt8]) -> ColorImage {
            var px = pixels
            var i = 0
            while i < px.count {
                px[i] = lut[Int(px[i])]
                px[i + 1] = lut[Int(px[i + 1])]
                px[i + 2] = lut[Int(px[i + 2])]
                i += 4
            }
            return ColorImage(width: width, height: height, pixels: px)
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

    /// A 256-entry tone curve combining brightness (additive, −0.5…0.5),
    /// contrast (multiplicative around mid, 1 = none) and gamma (1 = none).
    /// Returns nil when all three are neutral, so callers can skip the pass.
    static func toneLUT(brightness: Double, contrast: Double, gamma: Double) -> [UInt8]? {
        guard brightness != 0 || contrast != 1 || gamma != 1 else { return nil }
        return (0..<256).map { i in
            var v = Double(i) / 255
            v = (v - 0.5) * contrast + 0.5 + brightness
            v = min(1, max(0, v))
            if gamma != 1 { v = pow(v, 1 / gamma) }
            return UInt8((min(1, max(0, v)) * 255).rounded())
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

    /// The scan's own resolution, read from the file's DPI metadata. The
    /// device may honour a request at a *different* resolution (a WF-3820
    /// asked for 400 dpi returns 600), and every mm↔px crop must use the
    /// resolution the pixels are actually at, not the one requested.
    public static func dpi(of url: URL) -> Int? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        else { return nil }
        // Prefer the explicit DPI; fall back to the JFIF/TIFF resolution tags.
        if let d = props[kCGImagePropertyDPIWidth] as? Double, d > 0 {
            return Int(d.rounded())
        }
        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any],
            let d = tiff[kCGImagePropertyTIFFXResolution] as? Double, d > 0
        {
            return Int(d.rounded())
        }
        return nil
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
