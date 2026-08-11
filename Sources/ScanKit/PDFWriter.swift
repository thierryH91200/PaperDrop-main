import Foundation

/// Minimal PDF writer. Pages are either CCITT G4 streams (1-bit documents,
/// embedded losslessly) or grayscale JPEGs (photo-ish pages, DCTDecode).
/// An invisible OCR text layer (render mode 3) makes pages searchable.
public enum PDFWriter {
    public enum Content {
        case g4(G4.Stream)
        case jpegGray(Data, width: Int, height: Int)

        var size: (w: Int, h: Int) {
            switch self {
            case let .g4(s): (s.width, s.height)
            case let .jpegGray(_, w, h): (w, h)
            }
        }
    }

    public struct Page {
        public let content: Content
        public let dpi: Int
        public let ocrWords: [OCR.Word]
        /// Page size override in points; nil = natural image size.
        public var pageSizePt: (w: Double, h: Double)?
        /// Where the content sat on the scanner bed (points, from top-left).
        /// When the page is padded, the image is placed back at this
        /// physical position so the original layout is reproduced.
        public var bedOriginPt: (x: Double, y: Double)
        public init(
            content: Content, dpi: Int, ocrWords: [OCR.Word] = [],
            pageSizePt: (w: Double, h: Double)? = nil,
            bedOriginPt: (x: Double, y: Double) = (0, 0)
        ) {
            self.content = content
            self.dpi = dpi
            self.ocrWords = ocrWords
            self.pageSizePt = pageSizePt
            self.bedOriginPt = bedOriginPt
        }

        public var naturalSizePt: (w: Double, h: Double) {
            let (w, h) = content.size
            return (Double(w) / Double(dpi) * 72, Double(h) / Double(dpi) * 72)
        }
    }

    public static func build(pages: [Page]) -> Data {
        var objects: [Data] = []
        var pageObjectIDs: [Int] = []

        // obj 1 = catalog, obj 2 = pages tree, obj 3 = OCR font (filled at end)
        objects.append(Data())
        objects.append(Data())
        objects.append(Data())

        for page in pages {
            let (w, h) = page.content.size
            let (ptW, ptH) = page.naturalSizePt
            let boxW = max(page.pageSizePt?.w ?? ptW, ptW)
            let boxH = max(page.pageSizePt?.h ?? ptH, ptH)
            // Place the image at its physical position on the scanner bed
            // (clamped into the page box) so padded pages keep the original
            // layout. PDF origin is bottom-left; bed origin is top-left.
            let ox = min(page.bedOriginPt.x, boxW - ptW)
            let oyTop = min(page.bedOriginPt.y, boxH - ptH)
            let oy = boxH - ptH - oyTop

            let imgID = objects.count + 1
            var img: Data
            switch page.content {
            case let .g4(stream):
                // Empirically (ImageIO G4 + Preview): a min-is-black TIFF
                // stream needs BlackIs1 true to render upright.
                img = Data(
                    """
                    <</Type/XObject/Subtype/Image/Width \(w)/Height \(h)\
                    /ColorSpace/DeviceGray/BitsPerComponent 1\
                    /Filter/CCITTFaxDecode/DecodeParms<</K -1/Columns \(w)/Rows \(h)\
                    /BlackIs1 \(stream.minIsBlack ? "true" : "false")>>\
                    /Length \(stream.data.count)>>\nstream\n
                    """.utf8
                )
                img.append(stream.data)
            case let .jpegGray(jpeg, _, _):
                img = Data(
                    """
                    <</Type/XObject/Subtype/Image/Width \(w)/Height \(h)\
                    /ColorSpace/DeviceGray/BitsPerComponent 8/Filter/DCTDecode\
                    /Length \(jpeg.count)>>\nstream\n
                    """.utf8
                )
                img.append(jpeg)
            }
            img.append(Data("\nendstream".utf8))
            objects.append(img)

            let contentID = objects.count + 1
            var content = "q \(fmt(ptW)) 0 0 \(fmt(ptH)) \(fmt(ox)) \(fmt(oy)) cm /Im0 Do Q"
            if !page.ocrWords.isEmpty {
                content += "\nBT 3 Tr"
                for word in page.ocrWords {
                    let text = pdfEscape(word.text)
                    guard !text.isEmpty else { continue }
                    let x = ox + word.box.minX * ptW
                    let y = oy + word.box.minY * ptH
                    let boxW = word.box.width * ptW
                    let size = max(4, word.box.height * ptH)
                    // Horizontal scale so the string spans the detected box.
                    let nominal = Double(text.count) * size * 0.5
                    let tz = nominal > 0 ? boxW / nominal * 100 : 100
                    content += "\n/F1 \(fmt(size)) Tf \(fmt(min(500, max(20, tz)))) Tz"
                    content += " 1 0 0 1 \(fmt(x)) \(fmt(y)) Tm (\(text)) Tj"
                }
                content += "\nET"
            }
            var cobj = Data("<</Length \(content.utf8.count)>>\nstream\n".utf8)
            cobj.append(Data(content.utf8))
            cobj.append(Data("\nendstream".utf8))
            objects.append(cobj)

            let fontRes = page.ocrWords.isEmpty ? "" : "/Font<</F1 3 0 R>>"
            let pageID = objects.count + 1
            objects.append(
                Data(
                    """
                    <</Type/Page/Parent 2 0 R/MediaBox[0 0 \(fmt(boxW)) \(fmt(boxH))]\
                    /Resources<</XObject<</Im0 \(imgID) 0 R>>\(fontRes)>>/Contents \(contentID) 0 R>>
                    """.utf8
                )
            )
            pageObjectIDs.append(pageID)
        }

        objects[0] = Data("<</Type/Catalog/Pages 2 0 R>>".utf8)
        let kids = pageObjectIDs.map { "\($0) 0 R" }.joined(separator: " ")
        objects[1] = Data("<</Type/Pages/Kids[\(kids)]/Count \(pageObjectIDs.count)>>".utf8)
        objects[2] = Data("<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>".utf8)

        var out = Data("%PDF-1.4\n%\u{00E2}\u{00E3}\u{00CF}\u{00D3}\n".utf8)
        var offsets: [Int] = []
        for (i, obj) in objects.enumerated() {
            offsets.append(out.count)
            out.append(Data("\(i + 1) 0 obj\n".utf8))
            out.append(obj)
            out.append(Data("\nendobj\n".utf8))
        }
        let xrefStart = out.count
        out.append(Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for off in offsets {
            out.append(Data(String(format: "%010d 00000 n \n", off).utf8))
        }
        out.append(
            Data(
                """
                trailer\n<</Size \(objects.count + 1)/Root 1 0 R>>\nstartxref\n\(xrefStart)\n%%EOF
                """.utf8
            )
        )
        return out
    }

    private static func fmt(_ d: Double) -> String {
        String(format: "%.2f", d)
    }

    private static func pdfEscape(_ s: String) -> String {
        var out = ""
        for ch in s.unicodeScalars {
            switch ch {
            case "(": out += "\\("
            case ")": out += "\\)"
            case "\\": out += "\\\\"
            case let c where c.isASCII && c.value >= 32: out.unicodeScalars.append(c)
            default: out += " "  // non-Latin fallback; searchability over fidelity
            }
        }
        return out
    }
}
