import Foundation

/// A Bonjour service resolved to an address.
public struct BonjourService: Hashable, Sendable {
    public let name: String
    public let type: String
    public let address: String
    public let port: UInt16
}

#if canImport(Network)
import Network

/// Finds servers that advertise themselves with Bonjour (DNS-SD), e.g. NAS
/// boxes announcing `_nfs._tcp` or `_smb._tcp`.
public enum BonjourBrowser {
    public static func discover(
        serviceType: String,
        browseDuration: TimeInterval = 3,
        resolveTimeout: TimeInterval = 2
    ) async -> [BonjourService] {
        let endpoints = await browse(serviceType: serviceType, duration: browseDuration)
        return await withTaskGroup(of: BonjourService?.self) { group in
            for (name, endpoint) in endpoints {
                group.addTask {
                    await resolve(name: name, type: serviceType, endpoint: endpoint, timeout: resolveTimeout)
                }
            }
            var services: [BonjourService] = []
            for await service in group {
                if let service { services.append(service) }
            }
            return services
        }
    }

    /// Collects the services visible during `duration` seconds.
    static func browse(serviceType: String, duration: TimeInterval) async -> [(String, NWEndpoint)] {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "sharebuddy.bonjour.browse")
            let browser = NWBrowser(for: .bonjour(type: serviceType, domain: "local."), using: NWParameters())
            let state = BrowseState()

            let finish: @Sendable () -> Void = {
                guard state.markFinished() else { return }
                browser.cancel()
                continuation.resume(returning: state.endpoints)
            }

            browser.browseResultsChangedHandler = { results, _ in
                for result in results {
                    if case let .service(name, _, _, _) = result.endpoint {
                        state.add(name: name, endpoint: result.endpoint)
                    }
                }
            }
            browser.stateUpdateHandler = { browserState in
                switch browserState {
                case .failed, .cancelled:
                    finish()
                default:
                    break
                }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + duration) { finish() }
        }
    }

    /// Resolves a service endpoint to an IPv4 address by opening (and closing) a TCP connection.
    static func resolve(name: String, type: String, endpoint: NWEndpoint, timeout: TimeInterval) async -> BonjourService? {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "sharebuddy.bonjour.resolve")
            let parameters = NWParameters.tcp
            if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
                ip.version = .v4
            }
            let connection = NWConnection(to: endpoint, using: parameters)
            let once = OnceFlag()

            let finish: @Sendable (BonjourService?) -> Void = { service in
                guard once.markFinished() else { return }
                connection.cancel()
                continuation.resume(returning: service)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        finish(BonjourService(
                            name: name,
                            type: type,
                            address: BonjourBrowser.hostString(host),
                            port: port.rawValue
                        ))
                    } else {
                        finish(nil)
                    }
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        }
    }

    static func hostString(_ host: NWEndpoint.Host) -> String {
        let raw: String
        switch host {
        case .ipv4(let address): raw = "\(address)"
        case .ipv6(let address): raw = "\(address)"
        case .name(let name, _): raw = name
        @unknown default: raw = "\(host)"
        }
        // Drop the interface scope ("192.168.1.10%en0").
        return raw.split(separator: "%").first.map(String.init) ?? raw
    }
}
/// Thread-safe accumulator for browse results.
private final class BrowseState: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [String: NWEndpoint] = [:]
    private var finished = false

    func add(name: String, endpoint: NWEndpoint) {
        lock.lock()
        found[name] = endpoint
        lock.unlock()
    }

    var endpoints: [(String, NWEndpoint)] {
        lock.lock()
        defer { lock.unlock() }
        return found.map { ($0.key, $0.value) }
    }

    /// Returns true the first time only.
    func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}

/// Returns true the first time `markFinished` is called, false afterwards.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func markFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}
#else
public enum BonjourBrowser {
    public static func discover(
        serviceType: String,
        browseDuration: TimeInterval = 3,
        resolveTimeout: TimeInterval = 2
    ) async -> [BonjourService] {
        []
    }
}
#endif
