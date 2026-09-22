#if DEBUG
import ChirpCore
import CoreTelephony
import Foundation
import Network

/// DEBUG-only connectivity probe for the model-download path.
///
/// Launch with `-ChirpNetCheck` (e.g. `scripts/run_device.sh -- -ChirpNetCheck`). Writes `Documents/net-check.json`
/// with the network path the phone reports, whether Settings has cellular data turned off for this app, raw TCP/TLS
/// connects (an IP literal, so DNS is out of the picture, then the Hugging Face host), and, for each endpoint the
/// Parakeet download depends on, the HTTP status, bytes received, final URL after redirects, and the full error.
/// Pull it back with `xcrun devicectl device copy from … --source Documents/net-check.json`.
enum NetworkDiagnostics {
    static let launchArgument = "-ChirpNetCheck"
    static let resultFileName = "net-check.json"
    private static let repo = "FluidInference/parakeet-tdt-0.6b-v3-coreml"

    struct Check: Codable, Sendable {
        var name: String
        var url: String
        var statusCode: Int?
        var bytes: Int
        var elapsedMs: Int
        var finalURL: String?
        var errorDomain: String?
        var errorCode: Int?
        var errorDescription: String?
        var failingURL: String?
        var underlyingError: String?
    }

    struct PathInfo: Codable, Sendable {
        var status: String
        var interfaces: [String]
        var isExpensive: Bool
        var isConstrained: Bool
        var supportsDNS: Bool
        var supportsIPv4: Bool
        var supportsIPv6: Bool
    }

    struct Report: Codable, Sendable {
        var finishedAt: String
        var build: String
        var path: PathInfo
        /// `restricted` means Settings → Apps → Parakeet → Cellular Data is off.
        var cellularData: String
        var checks: [Check]
    }

    static func isRequested(in arguments: [String]) -> Bool { arguments.contains(launchArgument) }

    static var resultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(resultFileName)
    }

    /// Runs every probe sequentially and writes the report. Never throws; failures are data.
    @discardableResult
    static func runAndWrite() async -> Report {
        let log = Log.logger("net-check")
        let path = await currentPath()
        let cellularData = await cellularDataRestriction()
        var checks: [Check] = []
        checks.append(await connect("tcp-ip", host: "1.1.1.1", port: 443, tls: false))
        checks.append(await connect("tcp-host", host: "huggingface.co", port: 443, tls: false))
        checks.append(await connect("tls-host", host: "huggingface.co", port: 443, tls: true))
        checks.append(await fetch("apple", "https://www.apple.com/library/test/success.html"))
        let api = await fetchAPI("hf-api", "https://huggingface.co/api/models/\(repo)")
        checks.append(api.check)
        checks.append(await fetch("hf-resolve-small", "https://huggingface.co/\(repo)/resolve/main/README.md"))
        if let large = api.largeFile {
            // Large files redirect to Hugging Face's storage CDN; fetch only the first 1 KB.
            let largeURL = "https://huggingface.co/\(repo)/resolve/main/\(large)"
            checks.append(await fetch("hf-resolve-large-range", largeURL, range: "bytes=0-1023"))
        }
        let formatter = ISO8601DateFormatter()
        let report = Report(
            finishedAt: formatter.string(from: Date()),
            build: BuildIdentity.current.summary,
            path: path,
            cellularData: cellularData,
            checks: checks
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: resultURL, options: .atomic)
            log.info("net-check written: \(checks.count, privacy: .public) checks")
        } catch {
            log.error("net-check write failed: \(error.localizedDescription, privacy: .public)")
        }
        return report
    }

    // MARK: - Probes

    private static func fetch(_ name: String, _ urlString: String, range: String? = nil) async -> Check {
        await fetchWithBody(name, urlString, range: range).check
    }

    private static func fetchAPI(_ name: String, _ urlString: String) async -> (check: Check, largeFile: String?) {
        let result = await fetchWithBody(name, urlString, range: nil)
        guard name == "hf-api", let body = result.body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let siblings = json["siblings"] as? [[String: Any]]
        else { return (result.check, nil) }
        let files = siblings.compactMap { $0["rfilename"] as? String }
        let large = files.first { $0.hasSuffix("weight.bin") } ?? files.first { $0.hasSuffix(".bin") }
        return (result.check, large)
    }

    private static func fetchWithBody(
        _ name: String, _ urlString: String, range: String?
    ) async -> (check: Check, body: Data?) {
        let started = Date()
        var check = Check(name: name, url: urlString, bytes: 0, elapsedMs: 0)
        guard let url = URL(string: urlString) else {
            check.errorDescription = "bad URL"
            return (check, nil)
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: request)
            check.bytes = data.count
            check.statusCode = (response as? HTTPURLResponse)?.statusCode
            check.finalURL = response.url?.absoluteString
            check.elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            return (check, data)
        } catch {
            let ns = error as NSError
            check.errorDomain = ns.domain
            check.errorCode = ns.code
            check.errorDescription = ns.localizedDescription
            check.failingURL = ns.userInfo[NSURLErrorFailingURLStringErrorKey] as? String
            if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                check.underlyingError = "\(underlying.domain) \(underlying.code) \(underlying.localizedDescription)"
            }
            check.elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
            return (check, nil)
        }
    }

    /// Opens a raw TCP (or TLS) connection and reports the first terminal state: `ready`, `failed`, or `waiting` (the
    /// system is holding the connection back and says why). No HTTP, so this separates transport from URLSession.
    private static func connect(_ name: String, host: String, port: UInt16, tls: Bool) async -> Check {
        let started = Date()
        var check = Check(name: name, url: "\(tls ? "tls" : "tcp")://\(host):\(port)", bytes: 0, elapsedMs: 0)
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return check }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: tls ? .tls : .tcp)
        let queue = DispatchQueue(label: "ichirp.net-check.\(name)")
        let states = LockedStrings()
        let outcome: String = await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            connection.stateUpdateHandler = { state in
                let terminal: String?
                switch state {
                case .setup: states.append("setup"); terminal = nil
                case .preparing: states.append("preparing"); terminal = nil
                case .ready: terminal = "ready"
                case .waiting(let error): terminal = "waiting: \(error)"
                case .failed(let error): terminal = "failed: \(error)"
                case .cancelled: terminal = "cancelled"
                @unknown default: terminal = nil
                }
                if let terminal, resumed.setIfUnset() { continuation.resume(returning: terminal) }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) {
                if resumed.setIfUnset() {
                    continuation.resume(returning: "no terminal state after 15 s (seen: \(states.joined))")
                }
            }
        }
        connection.cancel()
        check.elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        if outcome == "ready" {
            check.statusCode = 0
        } else {
            check.errorDescription = outcome
        }
        return check
    }

    /// Settings → Apps → <app> → Cellular Data, as CoreTelephony reports it for this app.
    private static func cellularDataRestriction() async -> String {
        let holder = CellularDataHolder()
        return await withCheckedContinuation { continuation in
            let resumed = LockedFlag()
            // The notifier fires once with the current state after it is set; the timeout covers a phone without
            // cellular hardware or a notifier that never fires.
            holder.data.cellularDataRestrictionDidUpdateNotifier = { state in
                if resumed.setIfUnset() { continuation.resume(returning: describe(state)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                if resumed.setIfUnset() { continuation.resume(returning: describe(holder.data.restrictedState)) }
            }
        }
    }

    private static func describe(_ state: CTCellularDataRestrictedState) -> String {
        switch state {
        case .restricted: "restricted"
        case .notRestricted: "notRestricted"
        case .restrictedStateUnknown: "unknown"
        @unknown default: "unknown(\(state.rawValue))"
        }
    }

    private static func currentPath() async -> PathInfo {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "ichirp.net-check.path")
            let resumed = LockedFlag()
            monitor.pathUpdateHandler = { path in
                guard resumed.setIfUnset() else { return }
                var interfaces: [String] = []
                if path.usesInterfaceType(.wifi) { interfaces.append("wifi") }
                if path.usesInterfaceType(.cellular) { interfaces.append("cellular") }
                if path.usesInterfaceType(.wiredEthernet) { interfaces.append("wired") }
                if path.usesInterfaceType(.other) { interfaces.append("other") }
                if path.usesInterfaceType(.loopback) { interfaces.append("loopback") }
                let status: String
                switch path.status {
                case .satisfied: status = "satisfied"
                case .unsatisfied: status = "unsatisfied (\(path.unsatisfiedReason))"
                case .requiresConnection: status = "requiresConnection"
                @unknown default: status = "unknown"
                }
                monitor.cancel()
                continuation.resume(
                    returning: PathInfo(
                        status: status,
                        interfaces: interfaces,
                        isExpensive: path.isExpensive,
                        isConstrained: path.isConstrained,
                        supportsDNS: path.supportsDNS,
                        supportsIPv4: path.supportsIPv4,
                        supportsIPv6: path.supportsIPv6
                    )
                )
            }
            monitor.start(queue: queue)
        }
    }
}

/// Keeps the CTCellularData alive while its notifier and the timeout read it from other queues.
private final class CellularDataHolder: @unchecked Sendable {
    let data = CTCellularData()
}

/// Append-only list of connection states, written from the NWConnection queue.
private final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values.append(value)
    }

    var joined: String {
        lock.lock()
        defer { lock.unlock() }
        return values.isEmpty ? "none" : values.joined(separator: " → ")
    }
}

/// One-shot flag, safe to flip from the NWPathMonitor queue.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    /// Returns true exactly once.
    func setIfUnset() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if isSet { return false }
        isSet = true
        return true
    }
}
#endif
