import ChirpCore
import CoreGraphics
import Foundation
import Vision

/// Reads the text in a rendered page image, on this device.
public protocol PageTextRecognizing: Sendable {
    func recognizeText(in image: CGImage) async throws -> String
}

/// Vision's `RecognizeDocumentsRequest` (iOS 26), which returns the page's paragraphs in reading order; when it cannot
/// run (older hardware, some Simulator configurations) or reads no text at all (small print it does not take for a
/// document), it falls back to `RecognizeTextRequest` lines. Every document it detects is kept, top to bottom then
/// left to right. Runs entirely on this device, so it is allowed for every privacy class, clinical included.
public struct VisionPageTextRecognizer: PageTextRecognizing {
    private static let logger = Log.logger("documents")

    public init() {}

    public func recognizeText(in image: CGImage) async throws -> String {
        try await Self.recognize(
            documents: {
                try await RecognizeDocumentsRequest().perform(on: image).map { observation in
                    RecognizedDocument(
                        box: observation.document.boundingRegion.boundingBox.cgRect,
                        paragraphs: observation.document.paragraphs.map(\.transcript),
                        text: observation.document.text.transcript)
                }
            },
            lines: {
                var request = RecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                return try await request.perform(on: image).compactMap { $0.topCandidates(1).first?.string }
            })
    }

    /// One document Vision detected on the page: where it is (normalized, origin bottom-left), its paragraphs and its
    /// whole text.
    struct RecognizedDocument: Sendable {
        var box: CGRect
        var paragraphs: [String]
        var text: String
    }

    /// The documents' text (`joined(_:)`); when that request fails or reads nothing, the lines, one per line.
    static func recognize(
        documents: () async throws -> [RecognizedDocument],
        lines: () async throws -> [String]
    ) async throws -> String {
        do {
            let text = joined(try await documents())
            if !text.isEmpty { return text }
            logger.notice("ocr_documents_empty fallback=text_request")
        } catch {
            try Task.checkCancellation()
            logger.notice(
                "ocr_documents_request_failed fallback=text_request error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
        }
        return try await lines().joined(separator: "\n")
    }

    /// Every document's paragraphs (else its whole text), top to bottom, then left to right; blank ones dropped.
    static func joined(_ documents: [RecognizedDocument]) -> String {
        let ordered = documents.sorted { lhs, rhs in
            lhs.box.maxY != rhs.box.maxY ? lhs.box.maxY > rhs.box.maxY : lhs.box.minX < rhs.box.minX
        }
        return ordered.map { document in
            let paragraphs = document.paragraphs.filter { !isBlank($0) }
            return paragraphs.isEmpty ? document.text : paragraphs.joined(separator: "\n\n")
        }
        .filter { !isBlank($0) }
        .joined(separator: "\n\n")
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
