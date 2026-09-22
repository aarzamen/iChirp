import XCTest
import SwiftUI
@testable import MacParakeetCore
@testable import MacParakeetMobileUI

final class MobileExtensionsTests: XCTestCase {

    override func setUp() {
        super.setUp()
        AppGroupConstants.sharedUserDefaults.removeObject(forKey: "ParakeetKeyboardDictationState")
    }

    override func tearDown() {
        AppGroupConstants.sharedUserDefaults.removeObject(forKey: "ParakeetKeyboardDictationState")
        super.tearDown()
    }

    func testDarwinNotificationBroadcasterObserveAndPost() {
        let broadcaster = DarwinNotificationBroadcaster.shared
        let expectation = expectation(description: "Darwin notification received")
        let notificationName = "com.macparakeet.test.\(UUID().uuidString)"

        let token = broadcaster.observe(notificationName) {
            expectation.fulfill()
        }

        broadcaster.post(notificationName)
        wait(for: [expectation], timeout: 2.0)

        broadcaster.removeObserver(token)
    }

    func testAppGroupConstantsDirectories() {
        XCTAssertEqual(AppGroupConstants.groupIdentifier, "group.com.macparakeet.app")
        XCTAssertNotNil(AppGroupConstants.sharedContainerURL)
        XCTAssertNotNil(AppGroupConstants.sharedQueueDirectoryURL)
        XCTAssertNotNil(AppGroupConstants.keyboardDirectoryURL)

        guard let queueDir = AppGroupConstants.sharedQueueDirectoryURL else {
            XCTFail("sharedQueueDirectoryURL should not be nil")
            return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueDir.path))
    }

    func testSharedMediaQueueManagerEnqueueAndFetch() {
        let queueManager = SharedMediaQueueManager.shared
        _ = queueManager.fetchPendingItems().count

        let item = SharedMediaItem(
            title: "Test Voice Memo",
            originalURL: URL(string: "https://example.com/audio.m4a"),
            localFilename: "test_\(UUID().uuidString).m4a",
            mediaType: .audio
        )

        queueManager.enqueue(item)

        let pending = queueManager.fetchPendingItems()
        XCTAssertTrue(pending.contains(where: { $0.id == item.id }))

        queueManager.markItemProcessed(id: item.id)
        let pendingAfterProcess = queueManager.fetchPendingItems()
        XCTAssertFalse(pendingAfterProcess.contains(where: { $0.id == item.id }))

        queueManager.deleteItem(id: item.id)
        let allAfterDelete = queueManager.fetchAllItems()
        XCTAssertFalse(allAfterDelete.contains(where: { $0.id == item.id }))
    }

    func testKeyboardDictationStateCodable() throws {
        let state = KeyboardDictationState(
            status: .recording,
            partialTranscript: "Testing keyboard dictation",
            finalTranscript: "",
            audioLevel: 0.75,
            errorMessage: nil,
            timestamp: Date()
        )

        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(KeyboardDictationState.self, from: encoded)

        XCTAssertEqual(decoded.status, .recording)
        XCTAssertEqual(decoded.partialTranscript, "Testing keyboard dictation")
        XCTAssertEqual(decoded.audioLevel, 0.75)
    }

    @MainActor
    func testKeyboardDictationClientLifecycle() {
        let client = KeyboardDictationClient()
        XCTAssertEqual(client.currentState.status, .idle)

        client.startDictation()
        XCTAssertEqual(client.currentState.status, .requesting)

        client.stopDictation()
        XCTAssertEqual(client.currentState.status, .transcribing)

        client.cancelDictation()
        XCTAssertEqual(client.currentState.status, .idle)
    }

    func testKeyboardDictationServerStateUpdate() {
        let server = KeyboardDictationServer.shared
        server.updateState(
            status: .recording,
            partialTranscript: "Hello world",
            audioLevel: 0.5
        )

        let data = AppGroupConstants.sharedUserDefaults.data(forKey: "ParakeetKeyboardDictationState")
        XCTAssertNotNil(data)
        if let data, let state = try? JSONDecoder().decode(KeyboardDictationState.self, from: data) {
            XCTAssertEqual(state.status, .recording)
            XCTAssertEqual(state.partialTranscript, "Hello world")
            XCTAssertEqual(state.audioLevel, 0.5)
        }
    }
}
