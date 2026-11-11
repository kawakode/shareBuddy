import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Small POSIX socket helpers shared by the scanners.
enum Sockets {
    enum ConnectStart {
        case connected(Int32)
        case inProgress(Int32)
        /// The kernel refused at once; carries `errno`.
        case failed(Int32)
    }

    static func makeSocket(udp: Bool = false) -> Int32 {
        #if canImport(Darwin)
        let fd = socket(AF_INET, udp ? SOCK_DGRAM : SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(udp ? SOCK_DGRAM.rawValue : SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return fd }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        #if canImport(Darwin)
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return fd
    }

    static func makeAddress(host: UInt32, port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: host.bigEndian)
        return address
    }

    /// Starts a non-blocking TCP connection.
    static func startConnect(host: UInt32, port: UInt16) -> ConnectStart {
        let fd = makeSocket()
        guard fd >= 0 else { return .failed(errno) }
        var address = makeAddress(host: host, port: port)
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return .connected(fd) }
        let error = errno
        if error == EINPROGRESS { return .inProgress(fd) }
        close(fd)
        return .failed(error)
    }

    /// Opens a TCP connection, waiting at most `timeout`. Returns the (non-blocking) socket.
    static func connectWithTimeout(host: UInt32, port: UInt16, timeout: TimeInterval) -> Int32? {
        switch startConnect(host: host, port: port) {
        case .connected(let fd):
            return fd
        case .failed:
            return nil
        case .inProgress(let fd):
            guard wait(fd: fd, events: Int16(POLLOUT), timeout: timeout), socketError(fd) == 0 else {
                close(fd)
                return nil
            }
            return fd
        }
    }

    static func socketError(_ fd: Int32) -> Int32 {
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0 else { return errno }
        return socketError
    }

    /// Waits until `fd` is ready for `events`. Returns false on timeout or error.
    static func wait(fd: Int32, events: Int16, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let remainingMs = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            var pfd = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&pfd, 1, remainingMs)
            if ready < 0 && errno == EINTR { continue }
            return ready > 0 && pfd.revents & events != 0
        }
    }

    /// Raises the soft limit of open files (256 by default on macOS) so that
    /// large scan batches fit. Returns the usable limit.
    @discardableResult
    static func raiseOpenFileLimit(to wanted: rlim_t = 4096) -> Int {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return 256 }
        if limit.rlim_cur < wanted {
            var raised = limit
            raised.rlim_cur = min(wanted, limit.rlim_max)
            if setrlimit(RLIMIT_NOFILE, &raised) == 0 {
                limit = raised
            }
        }
        return Int(min(limit.rlim_cur, rlim_t(Int32.max)))
    }
}
