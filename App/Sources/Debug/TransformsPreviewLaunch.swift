import ChirpFeatures
import ChirpText
import SwiftUI

/// DEBUG-only launch arguments for checking a generated document's screen in the Simulator without tapping
/// (screenshots, QA; UX audit F23). Release builds ignore both.
///
/// - `-ChirpOpenDeliverable <uuid>`: once launch housekeeping is done, opens `DeliverableDetailScreen` for that
///   document id.
/// - `-ChirpCopyDeliverable`: with the above, also runs the Copy toolbar button's own action (`LocalPasteboard.copy
///   (PlainTextFlattener.flatten(...))`) on that document's text, so `xcrun simctl pbpaste` shows exactly what a
///   real tap on Copy would put on the clipboard.
enum TransformsPreviewLaunch {
    static let openDeliverableArgument = "-ChirpOpenDeliverable"
    static let copyDeliverableArgument = "-ChirpCopyDeliverable"
}

extension View {
    /// Applies the DEBUG launch argument above. A no-op in Release builds.
    func transformsPreviewLaunch(environment: AppEnvironment) -> some View {
        #if DEBUG
        modifier(TransformsPreviewLaunchModifier(environment: environment))
        #else
        self
        #endif
    }
}

#if DEBUG
private struct DeliverableIDItem: Identifiable {
    let id: UUID
}

private struct TransformsPreviewLaunchModifier: ViewModifier {
    let environment: AppEnvironment
    @State private var deliverable: DeliverableIDItem?

    func body(content: Content) -> some View {
        content
            .sheet(item: $deliverable) { item in
                NavigationStack { DeliverableDetailScreen(id: item.id, environment: environment) }
                    .environment(environment)
            }
            .task { await apply() }
    }

    private func apply() async {
        guard
            let value = IngestPreviewLaunch.value(after: TransformsPreviewLaunch.openDeliverableArgument),
            let id = UUID(uuidString: value)
        else { return }
        await environment.launch()
        deliverable = DeliverableIDItem(id: id)

        guard IngestPreviewLaunch.isSet(TransformsPreviewLaunch.copyDeliverableArgument) else { return }
        if let found = try? await environment.deliverableStore.fetchDeliverable(id: id) {
            LocalPasteboard.copy(PlainTextFlattener.flatten(found.text))
        }
    }
}
#endif
