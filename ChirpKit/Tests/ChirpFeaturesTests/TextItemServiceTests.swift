import ChirpCore
import Foundation
import XCTest

@testable import ChirpFeatures

/// Plan 022 Step 1: typed or pasted text as a Library item. Every text is synthetic.
final class TextItemServiceTests: XCTestCase {
    func testSavesACompletedTextItemTitledFromItsFirstLine() async throws {
        let store = FakeStore()
        let service = TextItemService(store: store)
        let saved = try await service.save(
            "\r\n  Synthetic follow-up plan\r\nCall the synthetic clinic on Thursday.\r\nBring the forms.  \n\n")
        XCTAssertEqual(saved.sourceType, .text)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertEqual(saved.privacyClass, .personal)
        XCTAssertNil(saved.mediaRelativePath)
        XCTAssertEqual(
            saved.rawTranscript, "Synthetic follow-up plan\nCall the synthetic clinic on Thursday.\nBring the forms.")
        XCTAssertEqual(saved.displayTitle, "Synthetic follow-up plan")
        XCTAssertEqual(saved.displayText, saved.rawTranscript)
        XCTAssertTrue(saved.isTextItem)
        XCTAssertTrue(saved.isTextOnly)
        let stored = try await store.fetch(id: saved.id)
        XCTAssertEqual(stored, saved)
    }

    func testEmptyTextIsRefusedAndNothingIsStored() async throws {
        let store = FakeStore()
        let service = TextItemService(store: store)
        for blank in ["", "   ", "\n\n\t \r\n"] {
            do {
                _ = try await service.save(blank)
                XCTFail("blank text was saved")
            } catch {
                XCTAssertEqual(error as? TextItemError, .empty)
            }
        }
        let all = try await store.fetchAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testTooLongTextIsRefused() async throws {
        let store = FakeStore()
        let service = TextItemService(store: store)
        do {
            _ = try await service.save(String(repeating: "a", count: TextItemService.maxCharacters + 1))
            XCTFail("an over-long text was saved")
        } catch {
            XCTAssertEqual(error as? TextItemError, .tooLong(limit: TextItemService.maxCharacters))
        }
    }

    func testClinicalClassIsStoredAsChosen() async throws {
        let store = FakeStore()
        let saved = try await TextItemService(store: store).save("Synthetic note", privacyClass: .clinical)
        let stored = try await store.fetch(id: saved.id)
        XCTAssertEqual(stored?.privacyClass, .clinical)
    }

    func testTitleDropsMarkdownMarkersAndCutsLongLinesAtAWord() {
        XCTAssertEqual(TextItemService.title(from: "# Synthetic heading\nbody"), "Synthetic heading")
        XCTAssertEqual(TextItemService.title(from: "- first bullet"), "first bullet")
        XCTAssertEqual(TextItemService.title(from: "   \n\n"), "Text")
        let long = String(repeating: "synthetic ", count: 20)
        let title = TextItemService.title(from: long)
        XCTAssertLessThanOrEqual(title.count, 80)
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertFalse(title.contains("synthetic synth…"))
    }

    // MARK: - Routes like any other item

    func testATextItemRunsATemplateLikeATranscript() async throws {
        let store = FakeStore()
        let deliverables = FakeDeliverableStore()
        let service = DeliverableService(
            transcripts: store, deliverables: deliverables, routingPolicy: { PrivacyRoutingPolicy() })
        try await service.installBuiltInTemplates()
        let item = try await TextItemService(store: store).save("Synthetic agenda\nReview the synthetic budget.")
        let model = RecordingLanguageModel(locality: .onDevice)
        var completed: Deliverable?
        for try await event in service.generate(
            templateID: BuiltInTemplates.summary.id, transcriptionID: item.id, model: model)
        {
            if case .completed(let deliverable) = event { completed = deliverable }
        }
        XCTAssertEqual(completed?.transcriptionID, item.id)
        XCTAssertTrue(model.everythingReceived.contains("Review the synthetic budget."))
        let unchanged = try await store.fetch(id: item.id)
        XCTAssertEqual(unchanged?.rawTranscript, item.rawTranscript, "generated text never overwrites the item")
    }

    func testAClinicalTextItemAsksBeforeACloudModel() async throws {
        let store = FakeStore()
        let deliverables = FakeDeliverableStore()
        let service = DeliverableService(
            transcripts: store, deliverables: deliverables, routingPolicy: { PrivacyRoutingPolicy() })
        try await service.installBuiltInTemplates()
        let item = try await TextItemService(store: store).save("Synthetic clinical note", privacyClass: .clinical)
        let cloud = RecordingLanguageModel(locality: .cloud)
        let decision = try await service.route(
            transcriptionID: item.id, templateID: BuiltInTemplates.summary.id, model: cloud)
        guard case .needsOverride(let request) = decision else {
            return XCTFail("a clinical text item went to the cloud without the confirmation")
        }
        XCTAssertEqual(request.route.privacyClass, .clinical)
        XCTAssertTrue(cloud.requests.isEmpty)
    }

    func testLibraryLocalFilterIncludesTextItems() {
        XCTAssertTrue(LibraryViewModel.Filter.local.includes(.text))
        XCTAssertFalse(LibraryViewModel.Filter.dictations.includes(.text))
    }
}
