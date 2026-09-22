import AVFoundation
#if os(macOS)
import ApplicationServices
import AppKit
import CoreGraphics
#elseif os(iOS)
import UIKit
#endif
import Foundation

public protocol PermissionServiceProtocol: Sendable {
    func checkMicrophonePermission() async -> PermissionStatus
    func requestMicrophonePermission() async -> Bool
    func checkScreenRecordingPermission() -> Bool
    func requestScreenRecordingPermission() -> Bool
    func openMicrophoneSettings()
    func openScreenRecordingSettings()
    func checkAccessibilityPermission() -> Bool
    func requestAccessibilityPermission(prompt: Bool) -> Bool
}

public enum PermissionStatus: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
}

public final class PermissionService: PermissionServiceProtocol, Sendable {
    public init() {}

    public func checkMicrophonePermission() async -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    public func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func checkScreenRecordingPermission() -> Bool {
        #if os(macOS)
        CGPreflightScreenCaptureAccess()
        #else
        false
        #endif
    }

    public func requestScreenRecordingPermission() -> Bool {
        #if os(macOS)
        CGRequestScreenCaptureAccess()
        #else
        false
        #endif
    }

    public func openMicrophoneSettings() {
        #if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") else {
            return
        }
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
        #endif
    }

    public func openScreenRecordingSettings() {
        #if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else {
            return
        }
        NSWorkspace.shared.open(url)
        #elseif os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        DispatchQueue.main.async {
            UIApplication.shared.open(url)
        }
        #endif
    }

    public func checkAccessibilityPermission() -> Bool {
        #if os(macOS)
        return AXIsProcessTrusted()
        #else
        return true
        #endif
    }

    public func requestAccessibilityPermission(prompt: Bool = true) -> Bool {
        #if os(macOS)
        let options: CFDictionary = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
        #else
        return true
        #endif
    }
}

