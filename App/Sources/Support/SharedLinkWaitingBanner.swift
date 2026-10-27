import ChirpUI
import SwiftUI

/// Plan 029: on the Dictating and Meeting screens while a link shared to Parakeet waits for the recording to finish.
struct SharedLinkWaitingBanner: View {
    var body: some View {
        if IncomingLinkRouter.shared.hasPending {
            Label("Link received. It opens when you finish.", systemImage: "link")
                .chirpFont(13, .semibold)
                .foregroundStyle(Tokens.Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
        }
    }
}
