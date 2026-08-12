import CoreGraphics
import Foundation
import Vision

/// Native OCR via the Vision framework.
public enum OCR {
    public struct Word: Sendable {
        public let text: String
        /// Normalised bounding box, bottom-left origin (Vision/PDF convention).
        public let box: CGRect
    }

    /// Recognise text on a 1-bit page (works on the packed page directly).
    public static func recognize(_ page: Pipeline.ProcessedPage) throws -> [Word] {
        guard let img = page.cgImage else {
            throw ScanError.scanFailed(String(localized: "Cannot build image for OCR"))
        }
        return try recognize(img)
    }

    /// Recognise text on any image. Bounding boxes are normalised, so they
    /// apply regardless of the page's colour space or size.
    public static func recognize(_ image: CGImage) throws -> [Word] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request])
        var words: [Word] = []
        for obs in request.results ?? [] {
            guard let candidate = obs.topCandidates(1).first else { continue }
            words.append(Word(text: candidate.string, box: obs.boundingBox))
        }
        return words
    }
}
