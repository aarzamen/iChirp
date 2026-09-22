import ChirpCore
import GRDB
import XCTest

@testable import ChirpStore

final class GRDBDeliverableStoreTests: XCTestCase {
    private var database: DatabaseManager!
    private var store: GRDBDeliverableStore!
    private var transcripts: GRDBTranscriptionStore!

    override func setUp() async throws {
        database = try DatabaseManager.inMemory()
        store = GRDBDeliverableStore(database: database)
        transcripts = GRDBTranscriptionStore(database: database)
    }

    private func builtIn(
        _ key: String = "summary",
        revision: Int = 1,
        content: String = "Summarize.",
        output: PrivacyClass? = nil
    ) -> BuiltInPromptTemplate {
        BuiltInPromptTemplate(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, canonicalKey: key, revision: revision,
            name: "Summary", category: .deliverable, content: content, outputPrivacyClass: output, sortOrder: 0)
    }

    private func insertTranscript(_ privacy: PrivacyClass = .personal) async throws -> Transcription {
        var row = Transcription(fileName: "synthetic.m4a", status: .completed, privacyClass: privacy)
        row.rawTranscript = "Synthetic transcript about the blue heron."
        try await transcripts.insert(row)
        return row
    }

    private func deliverable(
        for transcript: Transcription,
        privacy: PrivacyClass,
        versionID: UUID? = nil,
        promptID: UUID? = nil
    ) -> Deliverable {
        Deliverable(
            transcriptionID: transcript.id, promptID: promptID, promptVersionID: versionID, title: "Summary",
            engineID: "http.ollama", provider: "Mac Studio", model: "llama3.1:8b", locality: .localNetwork,
            text: "Generated summary.", privacyClass: privacy)
    }

    // MARK: Migration

    func testMigrationCreatesTheLanguageModelTablesAfterV1() async throws {
        let (tables, applied) = try await database.writer.read { db in
            (
                try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"),
                try DatabaseManager.migrator.appliedIdentifiers(db)
            )
        }
        for table in ["transcriptions", "prompts", "prompt_versions", "deliverables", "llm_runs"] {
            XCTAssertTrue(tables.contains(table), table)
        }
        XCTAssertTrue(applied.contains("v1-transcriptions"))
        XCTAssertTrue(applied.contains("v3-language-models"))
    }

    func testRunLedgerHasNoContentColumns() async throws {
        let columns = try await database.writer.read { db in
            try db.columns(in: "llm_runs").map(\.name)
        }
        let forbidden = ["text", "prompt", "content", "output", "transcript", "question", "notes", "answer", "system"]
        for column in columns {
            for word in forbidden where column.lowercased() == word || column.lowercased().hasSuffix(word) {
                XCTFail("llm_runs has a content-like column: \(column)")
            }
        }
        XCTAssertEqual(
            Set(columns),
            [
                "id", "feature", "status", "transcriptionId", "deliverableId", "promptVersionId", "engineId",
                "provider", "model", "locality", "privacyClass", "privacyOverride", "errorType", "promptTokens",
                "completionTokens", "latencyMs", "inputCharacters", "outputCharacters", "callCount", "createdAt",
            ])
    }

    // MARK: Templates and immutable versions

    func testInstallBuiltInsIsIdempotentAndUpgradesUncustomizedOnes() async throws {
        try await store.installBuiltInTemplates([builtIn()])
        try await store.installBuiltInTemplates([builtIn()])
        var templates = try await store.fetchTemplates()
        XCTAssertEqual(templates.count, 1)
        let template = try XCTUnwrap(templates.first)
        XCTAssertTrue(template.isBuiltIn)
        let value1 = try await store.fetchVersions(promptID: template.id).count
        XCTAssertEqual(value1, 1)

        try await store.installBuiltInTemplates([builtIn(revision: 2, content: "Summarize, v2.")])
        templates = try await store.fetchTemplates()
        let upgraded = try XCTUnwrap(templates.first)
        let versions = try await store.fetchVersions(promptID: upgraded.id)
        XCTAssertEqual(versions.map(\.versionNumber), [1, 2])
        XCTAssertEqual(versions.last?.origin, .systemUpdate)
        XCTAssertEqual(upgraded.activeVersionID, versions.last?.id)
        XCTAssertEqual(versions.first?.content, "Summarize.", "old versions are kept unchanged")
    }

    func testUserEditIsANewVersionAndBlocksBuiltInUpgrades() async throws {
        try await store.installBuiltInTemplates([builtIn()])
        let template = try await XCTUnwrapAsync(await store.fetchTemplates().first)
        let edited = try await store.addVersion(promptID: template.id, content: "My own summary prompt.")
        XCTAssertEqual(edited.versionNumber, 2)
        XCTAssertEqual(edited.origin, .user)

        try await store.installBuiltInTemplates([builtIn(revision: 5, content: "Newer built-in.")])
        let after = try await XCTUnwrapAsync(await store.fetchTemplate(id: template.id))
        XCTAssertEqual(after.activeVersionID, edited.id, "a user edit wins over a newer built-in")
        XCTAssertNotNil(after.userCustomizedAt)
        let value2 = try await store.fetchVersions(promptID: template.id).count
        XCTAssertEqual(value2, 2)
    }

    func testPromptVersionsAreImmutableInTheDatabase() async throws {
        try await store.installBuiltInTemplates([builtIn()])
        let template = try await XCTUnwrapAsync(await store.fetchTemplates().first)
        let versionID = template.activeVersionID
        do {
            try await database.writer.write { db in
                try db.execute(
                    sql: "UPDATE prompt_versions SET content = 'tampered' WHERE promptId = ?",
                    arguments: [template.id])
            }
            XCTFail("an UPDATE of prompt_versions must fail")
        } catch {}
        do {
            try await database.writer.write { db in
                _ = try PromptVersionRecord.deleteOne(db, key: versionID)
            }
            XCTFail("a DELETE of prompt_versions must fail")
        } catch {}
        let value3 = try await store.fetchVersion(id: versionID)?.content
        XCTAssertEqual(value3, "Summarize.")
    }

    func testCreateAndSoftDeleteTemplateKeepsVersionsAndDeliverables() async throws {
        let transcript = try await insertTranscript()
        let template = try await store.createTemplate(
            name: "Discharge summary", category: .deliverable, content: "Write it. {{transcript}}",
            outputPrivacyClass: .clinical)
        XCTAssertEqual(template.outputPrivacyClass, .clinical)
        let item = deliverable(
            for: transcript, privacy: .clinical, versionID: template.activeVersionID, promptID: template.id)
        try await store.insertDeliverable(item)

        try await store.softDeleteTemplate(id: template.id)
        let value4 = try await store.fetchTemplates().isEmpty
        XCTAssertTrue(value4)
        let value5 = try await store.fetchVersion(id: template.activeVersionID)
        XCTAssertNotNil(value5)
        let value6 = try await store.fetchDeliverable(id: item.id)?.promptVersionID
        XCTAssertEqual(value6, template.activeVersionID)
    }

    func testEmptyTemplateIsRejected() async {
        do {
            _ = try await store.createTemplate(
                name: "Blank", category: .transform, content: "  \n", outputPrivacyClass: nil)
            XCTFail("expected emptyTemplate")
        } catch {
            XCTAssertEqual(error as? GRDBDeliverableStore.StoreError, .emptyTemplate)
        }
    }

    // MARK: Deliverables

    func testDeliverableRoundTripEditAndNewestFirst() async throws {
        let transcript = try await insertTranscript()
        var first = deliverable(for: transcript, privacy: .personal)
        first.createdAt = Date(timeIntervalSinceNow: -60)
        first.updatedAt = first.createdAt
        let second = deliverable(for: transcript, privacy: .personal)
        try await store.insertDeliverable(first)
        try await store.insertDeliverable(second)

        let value7 = try await store.fetchDeliverables(transcriptionID: transcript.id).map(\.id)
        XCTAssertEqual(value7, [second.id, first.id])
        let value8 = try await store.fetchRecentDeliverables(limit: 1).map(\.id)
        XCTAssertEqual(value8, [second.id])

        let edited = try await store.updateDeliverableText(id: first.id, text: "Edited by the user.")
        XCTAssertEqual(edited?.text, "Edited by the user.")
        XCTAssertNotNil(edited?.editedAt)
        let value9 = try await store.updateDeliverableText(id: UUID(), text: "x")
        XCTAssertNil(value9)
    }

    func testGeneratedTextNeverTouchesTheTranscript() async throws {
        let transcript = try await insertTranscript()
        try await store.insertDeliverable(deliverable(for: transcript, privacy: .personal))
        let stored = try await transcripts.fetch(id: transcript.id)
        XCTAssertEqual(stored?.rawTranscript, transcript.rawTranscript)
        XCTAssertNil(stored?.cleanTranscript)
    }

    func testRaisingPrivacyNeverLowersAClass() async throws {
        let transcript = try await insertTranscript()
        let general = deliverable(for: transcript, privacy: .general)
        let clinical = deliverable(for: transcript, privacy: .clinical)
        try await store.insertDeliverable(general)
        try await store.insertDeliverable(clinical)

        let value10 = try await store.raiseDeliverablePrivacyClass(transcriptionID: transcript.id, to: .personal)
        XCTAssertEqual(value10, 1)
        let value11 = try await store.fetchDeliverable(id: general.id)?.privacyClass
        XCTAssertEqual(value11, .personal)
        let value12 = try await store.fetchDeliverable(id: clinical.id)?.privacyClass
        XCTAssertEqual(value12, .clinical)
        let value13 = try await store.raiseDeliverablePrivacyClass(transcriptionID: transcript.id, to: .general)
        XCTAssertEqual(value13, 0)
    }

    func testUnknownStoredPrivacyClassReadsAsClinical() async throws {
        let transcript = try await insertTranscript()
        let item = deliverable(for: transcript, privacy: .general)
        try await store.insertDeliverable(item)
        try await database.writer.write { db in
            guard var record = try DeliverableRecord.fetchOne(db, key: item.id) else { return }
            record.privacyClass = "secret-from-a-newer-build"
            try record.update(db)
        }
        let value14 = try await store.fetchDeliverable(id: item.id)?.privacyClass
        XCTAssertEqual(value14, .clinical)
    }

    func testDeletingTheTranscriptDeletesItsDeliverablesButKeepsTheLedger() async throws {
        let transcript = try await insertTranscript()
        let item = deliverable(for: transcript, privacy: .personal)
        try await store.insertDeliverable(item)
        let run = LanguageModelRun(
            feature: .deliverable, status: .succeeded, transcriptionID: transcript.id, deliverableID: item.id,
            engineID: "http.ollama", provider: "Mac Studio", model: "llama3.1:8b", locality: .localNetwork,
            privacyClass: .personal, privacyOverride: false, inputCharacters: 40, outputCharacters: 18, callCount: 1)
        try await store.recordRun(run)

        try await transcripts.delete(id: transcript.id)

        let value15 = try await store.fetchDeliverable(id: item.id)
        XCTAssertNil(value15)
        let runs = try await store.fetchRuns(limit: 10)
        XCTAssertEqual(runs.count, 1)
        XCTAssertNil(runs.first?.transcriptionID)
        XCTAssertNil(runs.first?.deliverableID)
    }

    func testRunRoundTrip() async throws {
        let run = LanguageModelRun(
            feature: .ask, status: .refused, transcriptionID: nil, engineID: "http.anthropic", provider: "Claude",
            model: "claude-x", locality: .cloud, privacyClass: .clinical, privacyOverride: false,
            errorType: "privacy_override_required", inputCharacters: 0, callCount: 0,
            createdAt: Date(timeIntervalSinceReferenceDate: 800_000_000))
        try await store.recordRun(run)
        let value16 = try await store.fetchRuns(limit: 5)
        XCTAssertEqual(value16, [run])
    }

    func testTranscriptPrivacyClassHasAFieldLevelSetter() async throws {
        let transcript = try await insertTranscript(.personal)
        let updated = try await transcripts.updatePrivacyClass(id: transcript.id, privacyClass: .clinical)
        XCTAssertEqual(updated?.privacyClass, .clinical)
        XCTAssertEqual(updated?.rawTranscript, transcript.rawTranscript)
        let value17 = try await transcripts.updatePrivacyClass(id: UUID(), privacyClass: .general)
        XCTAssertNil(value17)
    }
}

/// `XCTUnwrap` for an awaited optional.
func XCTUnwrapAsync<T>(
    _ expression: @autoclosure () async throws -> T?,
    file: StaticString = #filePath,
    line: UInt = #line
) async throws -> T {
    let value = try await expression()
    return try XCTUnwrap(value, file: file, line: line)
}
