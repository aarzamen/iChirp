import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Cross-platform abstraction layer for shared system operations (pasteboard, workspace, haptics)
/// bridging macOS AppKit and iOS UIKit capabilities cleanly.
public enum PlatformPasteboard {
    @MainActor
    public static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }

    @MainActor
    public static func string() -> String? {
        #if os(macOS)
        return NSPasteboard.general.string(forType: .string)
        #elseif os(iOS)
        return UIPasteboard.general.string
        #else
        return nil
        #endif
    }
}

public enum PlatformWorkspace {
    @discardableResult
    public static func open(_ url: URL) -> Bool {
        #if os(macOS)
        return NSWorkspace.shared.open(url)
        #elseif os(iOS)
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                    return true
                }
                return false
            }
        } else {
            Task { @MainActor in
                if UIApplication.shared.canOpenURL(url) {
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
            }
            return true
        }
        #else
        return false
        #endif
    }
}

public enum PlatformHaptics {
    public enum FeedbackStyle: Sendable {
        case light
        case medium
        case heavy
        case success
        case warning
        case error
    }

    @MainActor
    public static func trigger(_ style: FeedbackStyle) {
        #if os(iOS)
        switch style {
        case .light:
            let generator = UIImpactFeedbackGenerator(style: .light)
            generator.prepare()
            generator.impactOccurred()
        case .medium:
            let generator = UIImpactFeedbackGenerator(style: .medium)
            generator.prepare()
            generator.impactOccurred()
        case .heavy:
            let generator = UIImpactFeedbackGenerator(style: .heavy)
            generator.prepare()
            generator.impactOccurred()
        case .success:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.success)
        case .warning:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.warning)
        case .error:
            let generator = UINotificationFeedbackGenerator()
            generator.prepare()
            generator.notificationOccurred(.error)
        }
        #elseif os(macOS)
        // No-op on macOS; NSHapticFeedbackManager is reserved for trackpad clicks
        #endif
    }
}

#if !os(macOS)
public typealias CGKeyCode = UInt16

public final class Process: @unchecked Sendable {
    public var executableURL: URL?
    public var currentDirectoryURL: URL?
    public var arguments: [String]?
    public var environment: [String: String]?
    public var standardInput: Any?
    public var standardOutput: Any?
    public var standardError: Any?
    public var terminationHandler: (@Sendable (Process) -> Void)?
    public var terminationStatus: Int32 = 1
    public var processIdentifier: Int32 = 0
    public var isRunning: Bool = false

    public init() {}

    public func run() throws {
        throw CocoaError(.featureUnsupported)
    }

    public func waitUntilExit() {}
    public func terminate() {}
    public func interrupt() {}
}

public typealias AudioDeviceID = UInt32
public typealias AudioObjectID = UInt32
public typealias AudioObjectPropertySelector = UInt32

public let kAudioDeviceTransportTypeBuiltIn: UInt32 = 0x62696c74
public let kAudioDeviceTransportTypeBluetooth: UInt32 = 0x626c7565
public let kAudioDeviceTransportTypeBluetoothLE: UInt32 = 0x626c6561
public let kAudioDeviceTransportTypeUSB: UInt32 = 0x75736220
public let kAudioDeviceTransportTypeAggregate: UInt32 = 0x67727020
public let kAudioDeviceTransportTypeVirtual: UInt32 = 0x76697274
#endif


