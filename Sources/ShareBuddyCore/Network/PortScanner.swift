import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Fast TCP "connect" scanner.
///
/// Every connection of a batch is started in non-blocking mode at once, then a
/// single `poll()` waits for all of them. A /24 subnet for two ports takes
/// roughly `ceil(508 / batchSize) * timeout` seconds in the worst case.
public enum PortScanner {
    /// Returns, for every host that answered, the set of open ports.
    public static func scan(
        hosts: [UInt32],
        ports: [UInt16],
        timeout: TimeInterval = 0.6,
        batchSize: Int = 128
    ) async -> [UInt32: Set<UInt16>] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: scanSync(hosts: hosts, ports: ports, timeout: timeout, batchSize: batchSize))
            }
        }
    }

    /// Blocking variant of `scan`.
    public static func scanSync(
        hosts: [UInt32],
        ports: [UInt16],
        timeout: TimeInterval = 0.6,
        batchSize: Int = 128
    ) -> [UInt32: Set<UInt16>] {
        // Stay well under the default macOS limit of 256 open files per process.
        let batchSize = max(1, min(batchSize, 200))
        let probes = hosts.flatMap { host in ports.map { (host: host, port: $0) } }
        var open: [UInt32: Set<UInt16>] = [:]

        var start = 0
        while start < probes.count {
            let end = min(start + batchSize, probes.count)
            for hit in probeBatch(Array(probes[start..<end]), timeout: timeout) {
                open[hit.host, default: []].insert(hit.port)
            }
            start = end
        }
        return open
    }

    /// Convenience check of a single host/port.
    public static func isOpen(host: UInt32, port: UInt16, timeout: TimeInterval = 1) -> Bool {
        !probeBatch([(host: host, port: port)], timeout: timeout).isEmpty
    }

    private static func probeBatch(
        _ probes: [(host: UInt32, port: UInt16)],
        timeout: TimeInterval
    ) -> [(host: UInt32, port: UInt16)] {
        var hits: [(host: UInt32, port: UInt16)] = []
        // fd -> probe, for connections still in progress.
        var pending: [Int32: (host: UInt32, port: UInt16)] = [:]
        defer { pending.keys.forEach { _ = close($0) } }

        for probe in probes {
            switch startConnect(host: probe.host, port: probe.port) {
            case .connected(let fd):
                close(fd)
                hits.append(probe)
            case .inProgress(let fd):
                pending[fd] = probe
            case .failed:
                break
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
                var socketError: Int32 = 0
                var length = socklen_t(MemoryLayout<Int32>.size)
                let rc = getsockopt(pfd.fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
                if rc == 0 && socketError == 0 && pfd.revents & Int16(POLLOUT) != 0 {
                    hits.append(probe)
                }
                close(pfd.fd)
            }
        }
        return hits
    }

    private enum ConnectStart {
        case connected(Int32)
        case inProgress(Int32)
        case failed
    }

    private static func startConnect(host: UInt32, port: UInt16) -> ConnectStart {
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return .failed }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: host.bigEndian)

        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return .connected(fd) }
        if errno == EINPROGRESS { return .inProgress(fd) }
        close(fd)
        return .failed
    }
}
