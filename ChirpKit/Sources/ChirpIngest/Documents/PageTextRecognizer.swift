import ChirpCore
import CoreGraphics
import Foundation
import Vision

/// Reads the text in a rendered page image, on this device.
public protocol PageTextRecognizing: Sendable {
    func recognizeText(in image: CGImage) async throws -> String
}

/// Vision's `RecognizeDocumentsRequest` (iOS 26), which returns the page's paragraphs in reading order; when it cannot
/// run (older hardware, some Simulator configurations) it falls back to `RecognizeTextRequest` lines. Runs entirely on
/// this device, so it is allowed for every privacy class, clinical included.
public struct VisionPageTextRecognizer: PageTextRecognizing {
    private let logger = Log.logger("documents")

    public init() {}

    public func recognizeText(in image: CGImage) async throws -> String {
        do {
            let observations = try await RecognizeDocumentsRequest().perform(on: image)
            guard let document = observations.first?.document else { return "" }
            let paragraphs = document.paragraphs.map(\.transcript).filter {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return paragraphs.isEmpty ? document.text.transcript : paragraphs.joined(separator: "\n\n")
        } catch {
            try Task.checkCancellation()
            logger.notice(
                "ocr_documents_request_failed fallback=text_request error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
        }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let lines = try await request.perform(on: image)
        return lines.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
