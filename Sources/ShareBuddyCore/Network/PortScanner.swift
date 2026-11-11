import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Fast TCP "connect" scanner.
///
/// Every connection of a batch is started in non-blocking mode at once, then a
/// single `poll()` waits for all of them. The batch size follows the process's
/// open-file limit, which is raised first, so a whole /22 usually fits in a
/// few batches.
public enum PortScanner {
    public struct Result: Sendable {
        /// Open ports per host.
        public var open: [UInt32: Set<UInt16>] = [:]
        public var probeCount = 0
        /// Probes the kernel refused immediately, by `errno`.
        public var immediateFailures: [Int32: Int] = [:]

        /// True when every probe was refused by the Mac itself before reaching
        /// the network: the typical symptom of a denied "Local Network" permission.
        public var looksBlockedLocally: Bool {
            guard probeCount > 0, open.isEmpty else { return false }
            let blocked = [EHOSTUNREACH, ENETUNREACH, EPERM, EACCES]
                .reduce(0) { $0 + (immediateFailures[$1] ?? 0) }
            return blocked == probeCount
        }
    }

    /// Returns, for every host that answered, the set of open ports.
    public static func scan(
        hosts: [UInt32],
        ports: [UInt16],
        timeout: TimeInterval = 0.6
    ) async -> Result {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: scanSync(hosts: hosts, ports: ports, timeout: timeout))
            }
        }
    }

    /// Blocking variant of `scan`.
    public static func scanSync(
        hosts: [UInt32],
        ports: [UInt16],
        timeout: TimeInterval = 0.6,
        batchSize requestedBatchSize: Int? = nil
    ) -> Result {
        let fileLimit = Sockets.raiseOpenFileLimit()
        let batchSize = max(1, min(requestedBatchSize ?? 1024, fileLimit - 64))
        let probes = hosts.flatMap { host in ports.map { (host: host, port: $0) } }
        var result = Result()
        result.probeCount = probes.count

        var start = 0
        while start < probes.count {
            let end = min(start + batchSize, probes.count)
            probeBatch(Array(probes[start..<end]), timeout: timeout, into: &result)
            start = end
        }
        return result
    }

    /// Convenience check of a single host/port.
    public static func isOpen(host: UInt32, port: UInt16, timeout: TimeInterval = 1) -> Bool {
        var result = Result()
        probeBatch([(host: host, port: port)], timeout: timeout, into: &result)
        return !result.open.isEmpty
    }

    private static func probeBatch(
        _ probes: [(host: UInt32, port: UInt16)],
        timeout: TimeInterval,
        into result: inout Result
    ) {
        // fd -> probe, for connections still in progress.
        var pending: [Int32: (host: UInt32, port: UInt16)] = [:]
        defer { pending.keys.forEach { _ = close($0) } }

        for probe in probes {
            switch Sockets.startConnect(host: probe.host, port: probe.port) {
            case .connected(let fd):
                close(fd)
                result.open[probe.host, default: []].insert(probe.port)
            case .inProgress(let fd):
                pending[fd] = probe
            case .failed(let error):
                result.immediateFailures[error, default: 0] += 1
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while !pending.isEmpty {
            let remainingMs = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            if remainingMs == 0 { break }

            var pollFds = pending.keys.map { pollfd(fd: $0, events: Int16(POLLOUT), revents: 0) }
            let ready = poll(&pollFds, nfds_t(pollFds.count), remainingMs)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { break }

            for pfd in pollFds where pfd.revents != 0 {
                guard let probe = pending.removeValue(forKey: pfd.fd) else { continue }
                if Sockets.socketError(pfd.fd) == 0 && pfd.revents & Int16(POLLOUT) != 0 {
                    result.open[probe.host, default: []].insert(probe.port)
                }
                close(pfd.fd)
            }
        }
    }
}
