import SwiftUI

/// DEBUG-only launch arguments for checking the M5 screens in the Simulator without tapping (screenshots, QA):
///
/// - `-ChirpPasteLink <text>`: opens Capture → Paste a link with `<text>` filled in. Nothing is fetched: only the
///   Transcribe tap goes online.
/// - `-ChirpImportDocument <path>`: reads the file at `<path>` as a document at launch, as if picked in Files.
/// - `-ChirpOpenLatest`: opens the newest Library item once launch housekeeping is done.
///
/// Release builds ignore every one of them (`ingestPreviewLaunch` is a no-op there).
enum IngestPreviewLaunch {
    static let pasteLinkArgument = "-ChirpPasteLink"
    static let importDocumentArgument = "-ChirpImportDocument"
    static let openLatestArgument = "-ChirpOpenLatest"

    static func value(after flag: String, in arguments: [String] = ProcessInfo.processInfo.arguments) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
        return arguments[index + 1]
    }

    static func isSet(_ flag: String, in arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        arguments.contains(flag)
    }
}

extension View {
    /// Applies the DEBUG launch arguments above to Capture: opens Paste a link, imports a document, opens the newest
    /// item. A no-op in Release builds.
    func ingestPreviewLaunch(
        environment: AppEnvironment, isPastingLink: Binding<Bool>, path: Binding<[UUID]>
    ) -> some View {
        #if DEBUG
        task {
            await environment.launch()
            if let pathArgument = IngestPreviewLaunch.value(after: IngestPreviewLaunch.importDocumentArgument) {
                environment.importDocuments([URL(fileURLWithPath: pathArgument)])
            }
            if IngestPreviewLaunch.value(after: IngestPreviewLaunch.pasteLinkArgument) != nil {
                isPastingLink.wrappedValue = true
            }
            if IngestPreviewLaunch.isSet(IngestPreviewLaunch.openLatestArgument) {
                // Wait (at most ten seconds) for the newest item to finish, so the screen shows its result.
                for _ in 0..<40 where environment.library.items.first?.status == .processing {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                if let newest = environment.library.items.first {
                    path.wrappedValue.append(newest.id)
                }
            }
        }
        #else
        self
        #endif
    }
}
