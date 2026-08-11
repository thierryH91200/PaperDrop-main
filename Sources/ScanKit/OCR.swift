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
            throw ScanError.scanFailed("Cannot build image for OCR")
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: img).perform([request])
        var words: [Word] = []
        for obs in request.results ?? [] {
            guard let candidate = obs.topCandidates(1).first else { continue }
            words.append(Word(text: candidate.string, box: obs.boundingBox))
        }
        return words
    }
}
