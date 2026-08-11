import CoreGraphics
import Foundation
import ImageIO

/// Document processing pipeline — Swift port of engine/scandoc.py:
/// Otsu threshold → bed-edge removal → despeckle → content-cluster crop →
/// standard-paper-size snap.
public enum Pipeline {
    // MARK: Grayscale loading

    public struct GrayImage {
        public let width: Int
        public let height: Int
        public var pixels: [UInt8]  // row-major, 8-bit
    }

    public static func loadGray(_ url: URL) throws -> GrayImage {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let img = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else {
            throw ScanError.scanFailed("Cannot read image \(url.lastPathComponent)")
        }
        let w = img.width, h = img.height
        var pixels = [UInt8](repeating: 0, count: w * h)
        let cs = CGColorSpaceCreateDeviceGray()
        pixels.withUnsafeMutableBytes { buf in
            let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w, space: cs,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return GrayImage(width: w, height: h, pixels: pixels)
    }

    // MARK: Otsu

    public static func otsuThreshold(_ g: GrayImage) -> UInt8 {
        var hist = [Double](repeating: 0, count: 256)
        for p in g.pixels {
            hist[Int(p)] += 1
        }
        let total = Double(g.pixels.count)
        let sumAll = (0..<256).reduce(0.0) { $0 + Double($1) * hist[$1] }
        var bestT = 128, bestVar = -1.0, cum = 0.0, cumSum = 0.0
        for t in 1..<256 {
            cum += hist[t - 1]
            cumSum += Double(t - 1) * hist[t - 1]
            if cum == 0 || cum == total {
                continue
            }
            let m0 = cumSum / cum
            let m1 = (sumAll - cumSum) / (total - cum)
            let v = cum * (total - cum) * (m0 - m1) * (m0 - m1)
            if v > bestVar {
                bestVar = v
                bestT = t
            }
        }
        return UInt8(bestT)
    }

    // MARK: Binary image (true = ink/black)

    public struct BinaryImage {
        public let width: Int
        public let height: Int
        public var ink: [Bool]
        public subscript(x: Int, y: Int) -> Bool {
            ink[y * width + x]
        }
    }

    public static func threshold(_ g: GrayImage, at t: UInt8) -> BinaryImage {
        BinaryImage(
            width: g.width, height: g.height,
            ink: g.pixels.map { $0 < t }
        )
    }

    // MARK: Component cleanup (bed edges + specks)

    /// Whiten ink components touching the border (scanner-bed edges/shadows)
    /// and components smaller than minSpeck pixels (dust).
    public static func cleanComponents(_ bw: inout BinaryImage, minSpeck: Int = 4) {
        let w = bw.width, h = bw.height
        var labels = [Int32](repeating: 0, count: w * h)
        var sizes: [Int32] = [0]
        var touchesBorder = [false]
        var next: Int32 = 1
        var stack = [Int]()

        for start in 0..<(w * h) where bw.ink[start] && labels[start] == 0 {
            let label = next
            next += 1
            sizes.append(0)
            touchesBorder.append(false)
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            labels[start] = label
            while let idx = stack.popLast() {
                sizes[Int(label)] += 1
                let x = idx % w, y = idx / w
                if x == 0 || y == 0 || x == w - 1 || y == h - 1 {
                    touchesBorder[Int(label)] = true
                }
                // 8-connectivity
                for dy in -1...1 {
                    let ny = y + dy
                    if ny < 0 || ny >= h {
                        continue
                    }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nx = x + dx
                        if nx < 0 || nx >= w {
                            continue
                        }
                        let n = ny * w + nx
                        if bw.ink[n], labels[n] == 0 {
                            labels[n] = label
                            stack.append(n)
                        }
                    }
                }
            }
        }
        for i in 0..<(w * h) where bw.ink[i] {
            let l = Int(labels[i])
            if touchesBorder[l] || sizes[l] < Int32(minSpeck) {
                bw.ink[i] = false
            }
        }
    }

    // MARK: Content-cluster crop + paper snap

    public struct Crop {
        public let x0, y0, x1, y1: Int
        public init(x0: Int, y0: Int, x1: Int, y1: Int) {
            self.x0 = x0
            self.y0 = y0
            self.x1 = x1
            self.y1 = y1
        }
    }

    /// Portrait-normalised (w <= h) — snapping, naming and the app's
    /// landscape toggle all get the other orientation by swapping the pair.
    public static let paperSizesMM: [(name: String, w: Double, h: Double)] = [
        ("A6", 105, 148), ("A5", 148, 210), ("A4", 210, 297), ("Letter", 216, 279),
    ]

    /// Bounding box of the main ink cluster + margin, snapped to a standard
    /// paper size when within slack. Returns nil if the page is blank.
    public static func contentCrop(
        _ bw: BinaryImage, dpi: Int,
        marginMM: Double = 8, clusterMM: Double = 12,
        snapSlackMM: Double = 25,
        fixedMM: (w: Double, h: Double)? = nil
    ) -> Crop? {
        let w = bw.width, h = bw.height, ds = 8
        let sw = (w + ds - 1) / ds, sh = (h + ds - 1) / ds
        var small = [Bool](repeating: false, count: sw * sh)
        for y in 0..<h {
            for x in 0..<w where bw.ink[y * w + x] {
                small[(y / ds) * sw + (x / ds)] = true
            }
        }
        guard small.contains(true) else { return nil }

        // Dilate by cluster radius (iterative 4-neighbour)
        let r = max(1, Int(clusterMM / 25.4 * Double(dpi) / Double(ds)))
        var blob = small
        var tmp = blob
        for _ in 0..<r {
            for y in 0..<sh {
                for x in 0..<sw where !blob[y * sw + x] {
                    if (x > 0 && blob[y * sw + x - 1]) || (x < sw - 1 && blob[y * sw + x + 1])
                        || (y > 0 && blob[(y - 1) * sw + x])
                        || (y < sh - 1 && blob[(y + 1) * sw + x])
                    {
                        tmp[y * sw + x] = true
                    }
                }
            }
            blob = tmp
        }

        // Label blobs; keep the one containing the most ink
        var labels = [Int32](repeating: 0, count: sw * sh)
        var inkCount: [Int: Int] = [:]
        var next: Int32 = 1
        var stack = [Int]()
        for start in 0..<(sw * sh) where blob[start] && labels[start] == 0 {
            let label = next
            next += 1
            stack.removeAll(keepingCapacity: true)
            stack.append(start)
            labels[start] = label
            var count = 0
            while let idx = stack.popLast() {
                if small[idx] {
                    count += 1
                }
                let x = idx % sw, y = idx / sw
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] {
                    if nx < 0 || ny < 0 || nx >= sw || ny >= sh {
                        continue
                    }
                    let n = ny * sw + nx
                    if blob[n], labels[n] == 0 {
                        labels[n] = label
                        stack.append(n)
                    }
                }
            }
            inkCount[Int(label)] = count
        }
        // Keep every blob with a meaningful amount of ink — dropping only
        // debris. (Keeping just the largest blob loses distant page elements
        // like signature boxes below a dense table.)
        let largest = inkCount.values.max() ?? 0
        let minInk = max(8, largest / 200)
        var kept = [Bool](repeating: false, count: Int(next))
        for (label, count) in inkCount where count >= minInk {
            kept[label] = true
        }

        // Bounding box + ink mass profiles of kept blobs, at full resolution
        var x0 = w, y0 = h, x1 = 0, y1 = 0
        var colMass = [Int](repeating: 0, count: w)
        var rowMass = [Int](repeating: 0, count: h)
        for y in 0..<h {
            for x in 0..<w where bw.ink[y * w + x] {
                if kept[Int(labels[(y / ds) * sw + (x / ds)])] {
                    x0 = min(x0, x)
                    x1 = max(x1, x)
                    y0 = min(y0, y)
                    y1 = max(y1, y)
                    colMass[x] += 1
                    rowMass[y] += 1
                }
            }
        }
        guard x0 <= x1 else { return nil }

        let m = Int(marginMM / 25.4 * Double(dpi))
        let raw = Crop(
            x0: max(0, x0 - m), y0: max(0, y0 - m),
            x1: min(w, x1 + m), y1: min(h, y1 + m)
        )

        /// For the paper-size decision, ignore outlier tails holding under
        /// 0.3% of the ink each — a paper-edge shadow or stray mark must not
        /// veto a standard size the real content fits.
        func trim(_ mass: [Int], _ lo: Int, _ hi: Int) -> (Int, Int) {
            let total = mass[lo...hi].reduce(0, +)
            let budget = total * 3 / 1000
            var a = lo, b = hi, spent = 0
            while a < b, spent + mass[a] <= budget {
                spent += mass[a]
                a += 1
            }
            spent = 0
            while b > a, spent + mass[b] <= budget {
                spent += mass[b]
                b -= 1
            }
            return (a, b)
        }
        let (tx0, tx1) = trim(colMass, x0, x1)
        let (ty0, ty1) = trim(rowMass, y0, y1)

        // Explicit paper size: exactly that size in the orientation the
        // caller asked for, anchored at the content's top-left. The only
        // override is content that plainly cannot fit that way round but
        // fits rotated — a wrong orientation must never chop the page.
        if let f = fixedMM {
            let pxPerMM = Double(dpi) / 25.4
            var (tw, th) = (f.w, f.h)
            let cw = Double(tx1 - tx0) / pxPerMM
            let ch = Double(ty1 - ty0) / pxPerMM
            let fitsAsIs = cw <= tw && ch <= th
            let fitsRotated = cw <= th && ch <= tw
            if !fitsAsIs, fitsRotated {
                swap(&tw, &th)
            }
            return paperCrop(
                anchorX: tx0 - m, anchorY: ty0 - m,
                wMM: tw, hMM: th, imageW: w, imageH: h, dpi: dpi
            )
        }

        let trimmed = Crop(
            x0: max(0, tx0 - m), y0: max(0, ty0 - m),
            x1: min(w, tx1 + m), y1: min(h, ty1 + m)
        )
        return snapToPaper(
            trimmed, imageW: w, imageH: h, dpi: dpi,
            slackMM: snapSlackMM
        ) ?? raw
    }

    /// Photo print sizes — used for naming and explicit selection,
    /// deliberately NOT auto-snap candidates (too easy to mis-snap documents).
    public static let photoSizesMM: [(name: String, w: Double, h: Double)] = [
        ("4×6″", 101.6, 152.4), ("5×7″", 127, 177.8), ("8×10″", 203.2, 254),
    ]

    /// Name of the standard paper size matching the given dimensions, or nil.
    public static func paperSizeName(
        widthMM: Double, heightMM: Double,
        toleranceMM: Double = 3
    ) -> String? {
        for (name, pw, ph) in paperSizesMM + photoSizesMM {
            if abs(widthMM - pw) <= toleranceMM, abs(heightMM - ph) <= toleranceMM {
                return name
            }
            if abs(widthMM - ph) <= toleranceMM, abs(heightMM - pw) <= toleranceMM {
                return name + " landscape"
            }
        }
        return nil
    }

    /// A page-sized window anchored at the content's margined top-left and
    /// clamped inside the scan. The grown area extends toward bottom/right,
    /// like the physical page does from the bed origin. Both the forced size
    /// and auto-snap place their page this way — one home for the policy.
    static func paperCrop(
        anchorX: Int, anchorY: Int,
        wMM: Double, hMM: Double,
        imageW: Int, imageH: Int, dpi: Int
    ) -> Crop {
        let pxPerMM = Double(dpi) / 25.4
        let tpw = Int(wMM * pxPerMM), tph = Int(hMM * pxPerMM)
        let nx0 = min(max(0, anchorX), max(0, imageW - tpw))
        let ny0 = min(max(0, anchorY), max(0, imageH - tph))
        return Crop(
            x0: nx0, y0: ny0,
            x1: min(imageW, nx0 + tpw), y1: min(imageH, ny0 + tph)
        )
    }

    static func snapToPaper(
        _ c: Crop, imageW: Int, imageH: Int, dpi: Int,
        slackMM: Double
    ) -> Crop? {
        let pxPerMM = Double(dpi) / 25.4
        let wMM = Double(c.x1 - c.x0) / pxPerMM
        let hMM = Double(c.y1 - c.y0) / pxPerMM
        // Declaration order is preference order: metric sizes before Letter,
        // so an A4 page never snaps to the similar-but-wrong Letter.
        let candidates = paperSizesMM.flatMap { [($0.w, $0.h), ($0.h, $0.w)] }
        for (tw, th) in candidates {
            guard wMM <= tw, tw <= wMM + slackMM,
                hMM <= th, th <= hMM + slackMM
            else { continue }
            return paperCrop(
                anchorX: c.x0, anchorY: c.y0,
                wMM: tw, hMM: th, imageW: imageW, imageH: imageH, dpi: dpi
            )
        }
        return nil
    }

    // MARK: Full document pipeline

    public struct ProcessedPage {
        public let width: Int
        public let height: Int
        public let dpi: Int
        /// Crop origin on the scanner bed, in pixels — where this content
        /// physically sat. Used to reproduce layout when padding pages.
        public let originX: Int
        public let originY: Int
        /// Packed 1-bit rows, MSB first, 1 = white (min-is-black convention).
        public let packed: Data

        /// Crop origin on the scanner bed, in PDF points.
        public var bedOriginPt: (x: Double, y: Double) {
            (Double(originX) / Double(dpi) * 72, Double(originY) / Double(dpi) * 72)
        }
    }

    /// Threshold, clean, and detect the content crop — the shared front half
    /// of document processing, also used directly by grayscale (photo) pages.
    public static func analyze(
        _ gray: GrayImage, dpi: Int,
        snapSlackMM: Double = 25,
        fixedMM: (w: Double, h: Double)? = nil
    )
        -> (bw: BinaryImage, crop: Crop)
    {
        var bw = threshold(gray, at: otsuThreshold(gray))
        cleanComponents(&bw)
        let crop =
            contentCrop(
                bw, dpi: dpi, snapSlackMM: snapSlackMM,
                fixedMM: fixedMM
            )
            ?? Crop(x0: 0, y0: 0, x1: bw.width, y1: bw.height)
        return (bw, crop)
    }

    public static func processDocument(
        _ gray: GrayImage, dpi: Int,
        crop: Bool = true,
        snapSlackMM: Double = 25,
        fixedMM: (w: Double, h: Double)? = nil
    )
        -> ProcessedPage
    {
        let (bw, detected) = analyze(
            gray, dpi: dpi, snapSlackMM: snapSlackMM,
            fixedMM: fixedMM
        )
        let c =
            crop
            ? detected
            : Crop(x0: 0, y0: 0, x1: bw.width, y1: bw.height)
        let cw = c.x1 - c.x0, ch = c.y1 - c.y0
        let rowBytes = (cw + 7) / 8
        var packed = Data(count: rowBytes * ch)
        packed.withUnsafeMutableBytes { buf in
            let p = buf.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<ch {
                let src = (y + c.y0) * bw.width + c.x0
                for x in 0..<cw where !bw.ink[src + x] {  // white bit = 1
                    p[y * rowBytes + x / 8] |= 0x80 >> (x % 8)
                }
            }
        }
        return ProcessedPage(
            width: cw, height: ch, dpi: dpi,
            originX: c.x0, originY: c.y0, packed: packed
        )
    }
}
