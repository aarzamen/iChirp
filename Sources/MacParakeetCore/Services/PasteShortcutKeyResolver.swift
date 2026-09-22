#if os(macOS)
import Carbon
import Foundation
import OSLog

enum KeyboardLayoutLookupResult {
    case data(CFData)
    case missingInputSource
    case missingLayoutData
    case inaccessibleLayoutBytes
}

struct PasteShortcutKeyResolver {
    private let logger = Logger(subsystem: "com.macparakeet.core", category: "ClipboardService")
    private let keyboardLayoutProvider: () -> KeyboardLayoutLookupResult
    private let keyboardTypeProvider: () -> UInt32
    private let translatedCharacterProvider: (CFData, UInt16, UInt32, UInt32) -> UniChar?

    init(
        keyboardLayoutProvider: @escaping () -> KeyboardLayoutLookupResult = Self.liveKeyboardLayout,
        keyboardTypeProvider: @escaping () -> UInt32 = { UInt32(LMGetKbdType()) },
        translatedCharacterProvider: @escaping (CFData, UInt16, UInt32, UInt32) -> UniChar? = Self.translatedCharacter
    ) {
        self.keyboardLayoutProvider = keyboardLayoutProvider
        self.keyboardTypeProvider = keyboardTypeProvider
        self.translatedCharacterProvider = translatedCharacterProvider
    }

    func virtualKeyCode(for character: Character, modifierKeyState: UInt32 = 0) -> CGKeyCode {
        let fallbackKeyCode = Self.qwertyFallbackKeyCode(for: character)
        let layoutLookup = keyboardLayoutProvider()

        let layoutData: CFData
        switch layoutLookup {
        case .data(let data):
            layoutData = data
        case .missingInputSource:
            logger.error("Failed to get current keyboard input source; falling back to QWERTY keycode \(fallbackKeyCode, privacy: .public)")
            return fallbackKeyCode
        case .missingLayoutData:
            logger.error("Failed to resolve keyboard layout data for paste shortcut; falling back to QWERTY keycode \(fallbackKeyCode, privacy: .public)")
            return fallbackKeyCode
        case .inaccessibleLayoutBytes:
            logger.error("Failed to access keyboard layout bytes for paste shortcut; falling back to QWERTY keycode \(fallbackKeyCode, privacy: .public)")
            return fallbackKeyCode
        }

        guard let target = String(character).utf16.first else {
            logger.error("Failed to encode character for paste shortcut lookup; falling back to QWERTY keycode \(fallbackKeyCode, privacy: .public)")
            return fallbackKeyCode
        }

        let keyboardType = keyboardTypeProvider()
        for keyCode: UInt16 in 0..<128 {
            guard let translated = translatedCharacterProvider(layoutData, keyCode, modifierKeyState, keyboardType) else {
                continue
            }

            if translated == target {
                return CGKeyCode(keyCode)
            }
        }

        logger.error("Failed to resolve dynamic virtual keycode for character \(String(character), privacy: .public); falling back to QWERTY keycode \(fallbackKeyCode, privacy: .public)")
        return fallbackKeyCode
    }

    private static func liveKeyboardLayout() -> KeyboardLayoutLookupResult {
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return .missingInputSource
        }

        guard let layoutProperty = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
            return .missingLayoutData
        }

        return .data(unsafeBitCast(layoutProperty, to: CFData.self))
    }

    private static func translatedCharacter(
        layoutData: CFData,
        keyCode: UInt16,
        modifierKeyState: UInt32,
        keyboardType: UInt32
    ) -> UniChar? {
        guard let layoutBytes = CFDataGetBytePtr(layoutData) else {
            return nil
        }

        let layout = layoutBytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { $0 }
        var deadKeyState: UInt32 = 0
        var actualStringLength: Int = 0
        var unicodeString: [UniChar] = [0, 0, 0, 0]

        let status = UCKeyTranslate(
            layout,
            keyCode,
            UInt16(kUCKeyActionDown),
            modifierKeyState,
            keyboardType,
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            4,
            &actualStringLength,
            &unicodeString
        )

        guard status == noErr, actualStringLength > 0 else {
            return nil
        }

        return unicodeString[0]
    }

    private static func qwertyFallbackKeyCode(for character: Character) -> CGKeyCode {
        switch character.lowercased() {
        case "c":
            return 8
        case "v":
            return 9
        default:
            return 9
        }
    }
}
#endif
