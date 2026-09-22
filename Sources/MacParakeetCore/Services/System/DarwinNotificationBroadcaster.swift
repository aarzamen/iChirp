import CoreFoundation
import Foundation

/// Lightweight, cross-process notification broadcaster using the Darwin notify center (`CFNotificationCenterGetDarwinNotifyCenter`).
/// Enables instantaneous, low-overhead IPC between the host app and App Extensions (Share Extension, Keyboard Extension, Widget/Live Activity).
public final class DarwinNotificationBroadcaster: @unchecked Sendable {
    public static let shared = DarwinNotificationBroadcaster()

    private let center: CFNotificationCenter
    private let lock = NSLock()
    private var observers: [String: [(UUID, @Sendable () -> Void)]] = [:]

    private init() {
        self.center = CFNotificationCenterGetDarwinNotifyCenter()
    }

    /// Posts a Darwin notification across all processes running under the current user.
    public func post(_ name: String) {
        let cfName = CFNotificationName(name as CFString)
        CFNotificationCenterPostNotification(center, cfName, nil, nil, true)
    }

    /// Registers a closure to be executed whenever the specified Darwin notification is received.
    /// Returns a registration token for unregistering.
    @discardableResult
    public func observe(_ name: String, handler: @escaping @Sendable () -> Void) -> UUID {
        let id = UUID()
        lock.lock()
        let shouldRegisterCenter = observers[name] == nil || observers[name]!.isEmpty
        observers[name, default: []].append((id, handler))
        lock.unlock()

        if shouldRegisterCenter {
            let cfName = CFNotificationName(name as CFString)
            let observerPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

            CFNotificationCenterAddObserver(
                center,
                observerPtr,
                { _, observer, name, _, _ in
                    guard let observer, let name else { return }
                    let broadcaster = Unmanaged<DarwinNotificationBroadcaster>.fromOpaque(observer).takeUnretainedValue()
                    let nameString = (name.rawValue as String)
                    broadcaster.notifyObservers(for: nameString)
                },
                cfName.rawValue,
                nil,
                .deliverImmediately
            )
        }

        return id
    }

    /// Removes an observer by its token.
    public func removeObserver(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }

        for (name, list) in observers {
            let filtered = list.filter { $0.0 != id }
            if filtered.isEmpty {
                observers.removeValue(forKey: name)
                let cfName = CFNotificationName(name as CFString)
                let observerPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
                CFNotificationCenterRemoveObserver(center, observerPtr, cfName, nil)
            } else {
                observers[name] = filtered
            }
        }
    }

    private func notifyObservers(for name: String) {
        lock.lock()
        let handlers = observers[name]?.map { $0.1 } ?? []
        lock.unlock()

        for handler in handlers {
            handler()
        }
    }
}
