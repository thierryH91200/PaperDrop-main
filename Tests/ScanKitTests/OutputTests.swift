import Foundation
import XCTest

@testable import ScanKit

/// A white 200x100px page with a black bar, packed 1-bit.
private func makePage(
    width: Int = 200, height: Int = 100,
    dpi: Int = 100
) -> Pipeline.ProcessedPage {
    let rowBytes = (width + 7) / 8
    var packed = Data(repeating: 0xFF, count: rowBytes * height)
    for y in 20..<40 {
        for xb in 2..<10 {
            packed[y * rowBytes + xb] = 0x00
        }
    }
    return Pipeline.ProcessedPage(
        width: width, height: height, dpi: dpi,
        originX: 0, originY: 0, packed: packed)
}

final class G4Tests: XCTestCase {
    func test_g4Tiff_roundTripPreservesGeometry() throws {
        // Arrange
        let page = makePage()

        // Act
        let tiff = try G4.tiff(from: page)
        let stream = try G4.extractStream(fromTIFF: tiff)

        // Assert
        XCTAssertEqual(stream.width, page.width)
        XCTAssertEqual(stream.height, page.height)
        XCTAssertFalse(stream.data.isEmpty)
        XCTAssertLessThan(
            stream.data.count, page.packed.count,
            "G4 should compress a mostly-white page")
    }
}

final class PDFWriterTests: XCTestCase {
    func test_build_producesAWellFormedPDF() throws {
        // Arrange
        let page = makePage()
        let stream = try G4.extractStream(fromTIFF: G4.tiff(from: page))

        // Act
        let pdf = PDFWriter.build(pages: [.init(content: .g4(stream), dpi: 100)])
        let text = String(decoding: pdf, as: UTF8.self)

        // Assert
        XCTAssertTrue(text.hasPrefix("%PDF-1.4"))
        XCTAssertTrue(text.contains("/CCITTFaxDecode"))
        XCTAssertTrue(text.contains("/Count 1"))
        XCTAssertTrue(text.hasSuffix("%%EOF"))
    }

    func test_build_padsToUniformPageSizeTopAnchored() throws {
        // Arrange — 200x100px at 100dpi = 144x72pt natural
        let page = makePage()
        let stream = try G4.extractStream(fromTIFF: G4.tiff(from: page))
        var pdfPage = PDFWriter.Page(content: .g4(stream), dpi: 100)
        pdfPage.pageSizePt = (200, 200)

        // Act
        let text = String(decoding: PDFWriter.build(pages: [pdfPage]), as: UTF8.self)

        // Assert — MediaBox is the padded size; image sits at the top
        XCTAssertTrue(text.contains("/MediaBox[0 0 200.00 200.00]"))
        XCTAssertTrue(
            text.contains("0.00 128.00 cm"),
            "image should sit at the page top (200-72=128)")
    }

    func test_build_escapesOCRTextAndMarksItInvisible() throws {
        // Arrange
        let page = makePage()
        let stream = try G4.extractStream(fromTIFF: G4.tiff(from: page))
        let words = [
            OCR.Word(
                text: "with (parens) \\ done",
                box: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05))
        ]

        // Act
        let text = String(
            decoding: PDFWriter.build(pages: [
                .init(content: .g4(stream), dpi: 100, ocrWords: words)
            ]), as: UTF8.self)

        // Assert
        XCTAssertTrue(text.contains("BT 3 Tr"), "OCR text must be invisible")
        XCTAssertTrue(text.contains("with \\(parens\\) \\\\ done"))
    }
}

final class ScannerInfoTests: XCTestCase {
    func test_sameModel_toleratesVendorSpellings() {
        // Arrange / Act / Assert
        XCTAssertTrue(ScannerInfo.sameModel("Canon LiDE 110 (SANE)", "CanoScan LiDE 110"))
        XCTAssertFalse(ScannerInfo.sameModel("Canon LiDE 110", "EPSON Perfection V600"))
    }

    func test_baseName_stripsBackendSuffix() {
        // Arrange
        let info = ScannerInfo(id: "sane:x", name: "Canon LiDE 110 (SANE)")

        // Act / Assert
        XCTAssertEqual(info.baseName, "Canon LiDE 110")
    }
}
