import SwiftUI
import UIKit

/// Windows above the app's own for the screens that must appear whatever the person has open (review R6a-4).
///
/// SwiftUI presents one modal at a time per window: a root `fullScreenCover` cannot appear while a tab screen shows a
/// sheet (Type or paste, Notes, Transform…). So the Action Button's Dictating screen, the Meeting screen and the audio
/// track choice each live in a window of their own, stacked above the app's window, and appear over any sheet.
///
/// Each window is see-through and lets touches through until it presents something (`PassthroughWindow`). While one
/// presents, it becomes the key window and the windows below it are hidden from VoiceOver, so focus stays on the
/// screen the person sees; when it is done, the app's window gets both back.
@MainActor final class RootOverlayWindows {
    /// The layers, bottom to top. A higher layer covers a lower one (Dictating covers a meeting and a track choice).
    enum Layer: Int, CaseIterable {
        case meeting = 1
        case trackChoice = 2
        case dictating = 3
    }

    private weak var mainWindow: UIWindow?
    private var windows: [Layer: PassthroughWindow] = [:]
    private var active: Set<Layer> = []

    /// Whether the layers are installed (once per scene).
    var isInstalled: Bool { !windows.isEmpty }

    /// Puts one window per layer above `mainWindow`, each showing `content(layer)`.
    func install(above mainWindow: UIWindow, content: (Layer) -> AnyView) {
        guard !isInstalled, let scene = mainWindow.windowScene else { return }
        self.mainWindow = mainWindow
        for layer in Layer.allCases {
            let window = PassthroughWindow(windowScene: scene)
            let host = UIHostingController(rootView: content(layer))
            host.view.backgroundColor = .clear
            // The root itself never takes a touch; what it presents lives in the window's own container views.
            host.view.isUserInteractionEnabled = false
            window.rootViewController = host
            window.backgroundColor = .clear
            window.windowLevel = .normal + CGFloat(layer.rawValue)
            window.isHidden = false
            windows[layer] = window
        }
    }

    /// A layer started or stopped presenting: the topmost presenting window (or the app's) is key and the only one
    /// VoiceOver reads.
    func setActive(_ isActive: Bool, layer: Layer) {
        if isActive { active.insert(layer) } else { active.remove(layer) }
        let top = Self.topLayer(of: active)
        mainWindow?.accessibilityElementsHidden = top != nil
        for (candidate, window) in windows {
            window.accessibilityElementsHidden = top.map { candidate.rawValue < $0.rawValue } ?? true
        }
        if let top, let window = windows[top] {
            window.makeKey()
        } else {
            mainWindow?.makeKey()
        }
    }

    /// The highest presenting layer, if any.
    static func topLayer(of active: Set<Layer>) -> Layer? {
        active.max { $0.rawValue < $1.rawValue }
    }
}

/// A window that takes a touch only when something it presents is under it: touches on its empty, clear root view go
/// to the windows below.
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        return Self.passesThrough(hit, window: self, root: rootViewController?.view) ? nil : hit
    }

    /// A hit on the window or its root view (nothing presented there) passes through.
    static func passesThrough(_ hit: UIView, window: UIView, root: UIView?) -> Bool {
        hit === window || hit === root
    }
}

/// Reports the `UIWindow` this view lands in (to stack the overlay windows above it).
struct HostWindowReader: UIViewRepresentable {
    let onWindow: (UIWindow) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onWindow = onWindow
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: ReaderView, context: Context) {}

    final class ReaderView: UIView {
        var onWindow: ((UIWindow) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
