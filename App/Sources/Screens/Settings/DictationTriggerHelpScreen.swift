import ChirpUI
import SwiftUI

/// Settings → Capture → Action Button / Back Tap (M2): how to start Parakeet dictation without opening the app. iOS
/// lets only the person assign the Action Button or Back Tap, so this screen explains the steps; Parakeet provides
/// the "Dictate" shortcut and Control they pick.
struct DictationTriggerHelpScreen: View {
    enum Topic: Hashable {
        case actionButton, backTap
    }

    let topic: Topic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(intro)
                    .chirpFont(15)
                    .foregroundStyle(Tokens.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .chirpFont(15, .bold)
                            .foregroundStyle(AppColor.accentText)
                            .frame(width: 22, alignment: .trailing)
                        Text(step)
                            .chirpFont(15)
                            .foregroundStyle(Tokens.Color.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(footer)
                    .chirpFont(13)
                    .foregroundStyle(Tokens.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .padding(24)
        }
        .background(Tokens.Color.ground)
        .navigationTitle(topic == .actionButton ? "Action Button" : "Back Tap")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
    }

    private var intro: String {
        switch topic {
        case .actionButton:
            "Press the Action Button to start dictating from anywhere, even the Lock Screen. Press it again to stop: "
                + "Parakeet transcribes on this iPhone and copies the text."
        case .backTap:
            "Back Tap runs a shortcut when you double- or triple-tap the back of the iPhone. It is an iOS "
                + "Accessibility setting, so you turn it on yourself."
        }
    }

    private var steps: [String] {
        switch topic {
        case .actionButton:
            [
                "Open the Settings app and tap Action Button.",
                "Swipe to Controls, tap Choose a Control, and pick Parakeet → Dictate. (Or swipe to Shortcut and pick "
                    + "Parakeet → Dictate.)",
                "Press the Action Button: Parakeet opens and starts recording, with a Live Activity in the Dynamic "
                    + "Island.",
                "Press it again, or tap Stop & copy, to get the text on your clipboard.",
            ]
        case .backTap:
            [
                "Open the Settings app → Accessibility → Touch → Back Tap.",
                "Choose Double Tap (or Triple Tap).",
                "Under Shortcuts, pick Dictate (Parakeet).",
                "Tap the back of the iPhone to start dictating; tap again to stop and copy.",
            ]
        }
    }

    private var footer: String {
        "The same “Dictate with Parakeet” shortcut works from Siri, Spotlight and the Shortcuts app. Recording always "
            + "starts with Parakeet on screen: iOS does not let apps start the microphone in the background."
    }
}
