#if os(macOS)
import AppKit
#endif
import Foundation

public protocol FocusedAppContextProviding: Sendable {
    @MainActor
    func currentContext() -> AppPromptContext?
}

public struct FocusedAppContextService: FocusedAppContextProviding {
    public init() {}

    @MainActor
    public func currentContext() -> AppPromptContext? {
        #if os(macOS)
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return AppPromptContext(
            bundleIdentifier: app.bundleIdentifier,
            displayName: app.localizedName
        )
        #else
        return nil
        #endif
    }
}

