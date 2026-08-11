import CoreGraphics
import XCTest

@testable import ScanKit

/// Synthetic scans small enough to keep tests fast.
private let dpi = 50

/// White bed with black rectangles, dimensions in mm.
private func makeGray(
    bedW: Double, bedH: Double,
    inkRectsMM: [CGRect]
) -> Pipeline.GrayImage {
    let px = { (mm: Double) in Int(mm / 25.4 * Double(dpi)) }
    let w = px(bedW), h = px(bedH)
    var pixels = [UInt8](repeating: 230, count: w * h)
    for rect in inkRectsMM {
        for y in px(rect.minY)..<min(h, px(rect.maxY)) {
            for x in px(rect.minX)..<min(w, px(rect.maxX)) {
                pixels[y * w + x] = 20
            }
        }
    }
    return Pipeline.GrayImage(width: w, height: h, pixels: pixels)
}

private func mm(_ px: Int) -> Double {
    Double(px) / Double(dpi) * 25.4
}

private func cleanedBinary(_ gray: Pipeline.GrayImage) -> Pipeline.BinaryImage {
    var bw = Pipeline.threshold(gray, at: 128)
    Pipeline.cleanComponents(&bw)
    return bw
}

final class OtsuTests: XCTestCase {
    func test_otsuThreshold_splitsABimodalHistogram() {
        // Arrange
        let gray = makeGray(
            bedW: 50, bedH: 50,
            inkRectsMM: [CGRect(x: 10, y: 10, width: 20, height: 20)])

        // Act
        let t = Pipeline.otsuThreshold(gray)

        // Assert
        XCTAssertTrue(t > 20 && t <= 230)
    }
}

final class CleanComponentsTests: XCTestCase {
    func test_cleanComponents_removesBorderTouchingInk() {
        // Arrange — one blob touching the top edge, one interior
        let gray = makeGray(
            bedW: 60, bedH: 60,
            inkRectsMM: [
                CGRect(x: 20, y: 0, width: 10, height: 10),
                CGRect(x: 20, y: 30, width: 10, height: 10),
            ])
        var bw = Pipeline.threshold(gray, at: Pipeline.otsuThreshold(gray))

        // Act
        Pipeline.cleanComponents(&bw)

        // Assert
        let borderY = Int(5 / 25.4 * Double(dpi))
        let interiorY = Int(35 / 25.4 * Double(dpi))
        let x = Int(25 / 25.4 * Double(dpi))
        XCTAssertFalse(bw[x, borderY], "border blob should be whitened")
        XCTAssertTrue(bw[x, interiorY], "interior blob should survive")
    }

    func test_cleanComponents_removesTinySpecks() {
        // Arrange — a 1px speck and a solid block
        let w = 100, h = 100
        var ink = [Bool](repeating: false, count: w * h)
        ink[50 * w + 50] = true
        for y in 70..<80 {
            for x in 70..<80 {
                ink[y * w + x] = true
            }
        }
        var bw = Pipeline.BinaryImage(width: w, height: h, ink: ink)

        // Act
        Pipeline.cleanComponents(&bw)

        // Assert
        XCTAssertFalse(bw[50, 50], "1px speck should be removed")
        XCTAssertTrue(bw[75, 75], "solid block should survive")
    }
}

final class ContentCropTests: XCTestCase {
    func test_contentCrop_snapsA4ContentToA4() throws {
        // Arrange — content block a little smaller than A4 on a full bed
        let gray = makeGray(
            bedW: 216.7, bedH: 300,
            inkRectsMM: [
                CGRect(x: 15, y: 15, width: 180, height: 265)
            ])

        // Act
        let crop = Pipeline.contentCrop(cleanedBinary(gray), dpi: dpi)

        // Assert
        let c = try XCTUnwrap(crop)
        XCTAssertEqual(mm(c.x1 - c.x0), 210, accuracy: 3, "width should snap to A4")
        XCTAssertEqual(mm(c.y1 - c.y0), 297, accuracy: 3, "height should snap to A4")
    }

    func test_contentCrop_prefersA4OverLetterWhenBothFit() throws {
        // Arrange — 190x260mm content (+8mm margins) fits both A4 and
        // Letter within the snap slack
        let gray = makeGray(
            bedW: 216.7, bedH: 300,
            inkRectsMM: [
                CGRect(x: 8, y: 8, width: 190, height: 260)
            ])

        // Act
        let crop = Pipeline.contentCrop(cleanedBinary(gray), dpi: dpi)

        // Assert — metric A4 must win over Letter
        let c = try XCTUnwrap(crop)
        XCTAssertEqual(mm(c.y1 - c.y0), 297, accuracy: 3)
    }

    func test_contentCrop_fixedSizeRotatesWhenContentCannotFit() throws {
        // Arrange — content wider than 5x7 portrait (a landscape photo)
        let gray = makeGray(
            bedW: 216.7, bedH: 300,
            inkRectsMM: [
                CGRect(x: 20, y: 20, width: 160, height: 100)
            ])

        // Act — force 5x7 inch paper, portrait
        let crop = Pipeline.contentCrop(
            cleanedBinary(gray), dpi: dpi,
            fixedMM: (w: 127, h: 177.8))

        // Assert — rotated to landscape, the only way the content fits
        let c = try XCTUnwrap(crop)
        XCTAssertEqual(mm(c.x1 - c.x0), 177.8, accuracy: 3)
        XCTAssertEqual(mm(c.y1 - c.y0), 127, accuracy: 3)
    }

    func test_contentCrop_fixedA4KeepsPortraitForWideInk() throws {
        // Arrange — a portrait A4 sheet whose ink is wider than tall
        // (letterhead plus a paragraph, empty lower half)
        let gray = makeGray(
            bedW: 216, bedH: 297,
            inkRectsMM: [
                CGRect(x: 20, y: 20, width: 170, height: 120)
            ])

        // Act — force A4
        let crop = Pipeline.contentCrop(
            cleanedBinary(gray), dpi: dpi,
            fixedMM: (w: 210, h: 297))

        // Assert — full-height portrait page, not a landscape band that
        // discards the bottom third of the sheet
        let c = try XCTUnwrap(crop)
        XCTAssertEqual(mm(c.x1 - c.x0), 210, accuracy: 3)
        XCTAssertEqual(mm(c.y1 - c.y0), 297, accuracy: 3)
    }

    func test_contentCrop_fixedSizeHonoursRequestedLandscape() throws {
        // Arrange — ink taller than wide, but small enough to fit either way
        let gray = makeGray(
            bedW: 216, bedH: 297,
            inkRectsMM: [
                CGRect(x: 20, y: 20, width: 100, height: 130)
            ])

        // Act — force A5 landscape
        let crop = Pipeline.contentCrop(
            cleanedBinary(gray), dpi: dpi,
            fixedMM: (w: 210, h: 148))

        // Assert — the requested orientation wins over the ink's shape
        let c = try XCTUnwrap(crop)
        XCTAssertEqual(mm(c.x1 - c.x0), 210, accuracy: 3)
        XCTAssertEqual(mm(c.y1 - c.y0), 148, accuracy: 3)
    }

    func test_contentCrop_keepsDistantSparseContent() throws {
        // Arrange — dense block plus a small distant signature-like mark
        let gray = makeGray(
            bedW: 216.7, bedH: 300,
            inkRectsMM: [
                CGRect(x: 15, y: 15, width: 120, height: 60),
                CGRect(x: 20, y: 200, width: 40, height: 12),
            ])

        // Act
        let crop = Pipeline.contentCrop(cleanedBinary(gray), dpi: dpi)

        // Assert — crop must extend past the distant mark's top edge
        let c = try XCTUnwrap(crop)
        XCTAssertGreaterThanOrEqual(mm(c.y1), 208, "distant mark must be inside the crop")
    }

    func test_contentCrop_nilOnBlankPage() {
        // Arrange
        let gray = makeGray(bedW: 60, bedH: 60, inkRectsMM: [])

        // Act
        let crop = Pipeline.contentCrop(cleanedBinary(gray), dpi: dpi)

        // Assert
        XCTAssertNil(crop)
    }
}

final class PaperSizeNameTests: XCTestCase {
    func test_paperSizeName_namesStandardAndPhotoSizes() {
        // Arrange / Act / Assert
        XCTAssertEqual(Pipeline.paperSizeName(widthMM: 210, heightMM: 297), "A4")
        XCTAssertEqual(Pipeline.paperSizeName(widthMM: 148, heightMM: 210), "A5")
        XCTAssertEqual(Pipeline.paperSizeName(widthMM: 101.6, heightMM: 152.4), "4×6″")
        XCTAssertEqual(
            Pipeline.paperSizeName(widthMM: 152.4, heightMM: 101.6),
            "4×6″ landscape")
        XCTAssertNil(Pipeline.paperSizeName(widthMM: 100, heightMM: 100))
    }
}

final class ProcessDocumentTests: XCTestCase {
    func test_processDocument_recordsBedOriginOfCrop() {
        // Arrange — content well away from the bed origin
        let gray = makeGray(
            bedW: 216.7, bedH: 300,
            inkRectsMM: [
                CGRect(x: 50, y: 80, width: 60, height: 40)
            ])

        // Act
        let page = Pipeline.processDocument(gray, dpi: dpi)

        // Assert — origin ≈ content position minus the 8mm margin
        XCTAssertEqual(mm(page.originX), 42, accuracy: 3)
        XCTAssertEqual(mm(page.originY), 72, accuracy: 3)
    }
}
