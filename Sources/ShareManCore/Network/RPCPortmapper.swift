import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Finds NFS servers by asking their portmapper / rpcbind (port 111) whether
/// the NFS program is registered, using Sun RPC `PMAP_GETPORT` calls.
///
/// This catches servers that the TCP scan of port 2049 misses: NFS served over
/// UDP only, a firewall that only lets RPC through, or a slow host.
public enum RPCPortmapper {
    public static let portmapperPort: UInt16 = 111
    static let portmapperProgram: UInt32 = 100_000
    static let nfsProgram: UInt32 = 100_003
    static let ipprotoTCP: UInt32 = 6
    static let ipprotoUDP: UInt32 = 17

    /// (NFS version, transport) pairs asked to each server.
    static let nfsQueries: [(version: UInt32, transport: UInt32)] = [
        (3, ipprotoTCP), (3, ipprotoUDP), (4, ipprotoTCP), (2, ipprotoUDP),
    ]

    // MARK: XDR encoding

    /// Encodes an RPC CALL to PMAP_GETPORT (portmapper v2, procedure 3).
    static func getPortCall(xid: UInt32, program: UInt32, version: UInt32, transport: UInt32) -> [UInt8] {
        let words: [UInt32] = [
            xid,
            0,                  // msg_type CALL
            2,                  // RPC version
            portmapperProgram,
            2,                  // portmapper version
            3,                  // PMAPPROC_GETPORT
            0, 0,               // credentials: AUTH_NONE, length 0
            0, 0,               // verifier: AUTH_NONE, length 0
            program, version, transport, 0,
        ]
        return words.flatMap { word in
            [UInt8(word >> 24 & 0xFF), UInt8(word >> 16 & 0xFF), UInt8(word >> 8 & 0xFF), UInt8(word & 0xFF)]
        }
    }

    /// Decodes a PMAP_GETPORT reply. Returns nil if it is not a successful reply.
    static func parseGetPortReply(_ bytes: [UInt8]) -> (xid: UInt32, port: UInt32)? {
        func word(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        guard let xid = word(0),
              word(4) == 1,                 // msg_type REPLY
              word(8) == 0,                 // MSG_ACCEPTED
              let verifierLength = word(16), verifierLength <= 400
        else { return nil }
        let acceptOffset = 20 + Int((verifierLength + 3) / 4 * 4)
        guard word(acceptOffset) == 0,      // SUCCESS
              let port = word(acceptOffset + 4)
        else { return nil }
        return (xid, port)
    }

    // MARK: UDP sweep

    /// Sends GETPORT(NFS) over UDP to every host and to the broadcast addresses,
    /// and collects the hosts that report NFS as registered.
    ///
    /// - Returns: hosts running NFS, with the NFS port they announce.
    public static func findNFSServers(
        hosts: [UInt32],
        broadcastAddresses: [UInt32] = [],
        timeout: TimeInterval = 2
    ) async -> [UInt32: UInt16] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: findNFSServersSync(
                    hosts: hosts,
                    broadcastAddresses: broadcastAddresses,
                    timeout: timeout
                ))
            }
        }
    }

    public static func findNFSServersSync(
        hosts: [UInt32],
        broadcastAddresses: [UInt32] = [],
        timeout: TimeInterval = 2
    ) -> [UInt32: UInt16] {
        let fd = Sockets.makeSocket(udp: true)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        var enable: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &enable, socklen_t(MemoryLayout<Int32>.size))

        let baseXID = UInt32.random(in: 1...(UInt32.max - 64))
        let packets = nfsQueries.enumerated().map { index, query in
            getPortCall(xid: baseXID + UInt32(index), program: nfsProgram, version: query.version, transport: query.transport)
        }
        let validXIDs = baseXID..<(baseXID + UInt32(packets.count))

        var found: [UInt32: UInt16] = [:]
        let targets = broadcastAddresses + hosts
        let deadline = Date().addingTimeInterval(timeout)

        func send(to targets: [UInt32]) {
            for target in targets where found[target] == nil {
                var address = Sockets.makeAddress(host: target, port: portmapperPort)
                for packet in packets {
                    sendDatagram(fd: fd, packet: packet, to: &address)
                }
                // Read replies as we go, so the receive buffer never overflows.
                receive(fd: fd, until: Date(), validXIDs: validXIDs, into: &found)
            }
        }

        // First round, then one resend for hosts that did not answer (UDP may drop).
        send(to: targets)
        receive(fd: fd, until: min(deadline, Date().addingTimeInterval(timeout / 2)), validXIDs: validXIDs, into: &found)
        send(to: hosts)
        receive(fd: fd, until: deadline, validXIDs: validXIDs, into: &found)
        return found
    }

    private static func sendDatagram(fd: Int32, packet: [UInt8], to address: inout sockaddr_in) {
        for _ in 0..<5 {
            let sent = packet.withUnsafeBytes { buffer in
                withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, buffer.baseAddress, buffer.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            // The interface queue is full: give it a moment and retry.
            if sent < 0 && (errno == ENOBUFS || errno == EAGAIN) {
                usleep(2_000)
                continue
            }
            return
        }
    }

    /// Reads replies until `deadline` (a deadline in the past drains what is queued).
    private static func receive(fd: Int32, until deadline: Date, validXIDs: Range<UInt32>, into found: inout [UInt32: UInt16]) {
        var buffer = [UInt8](repeating: 0, count: 1500)
        while true {
            let remainingMs = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, remainingMs)
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0 else { return }

            var source = sockaddr_in()
            var sourceLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &source) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &sourceLength)
                    }
                }
            }
            guard count > 0 else { continue }
            guard let reply = parseGetPortReply(Array(buffer[0..<count])),
                  validXIDs.contains(reply.xid),
                  reply.port > 0, reply.port <= UInt32(UInt16.max)
            else { continue }
            let host = UInt32(bigEndian: source.sin_addr.s_addr)
            if found[host] == nil { found[host] = UInt16(reply.port) }
        }
    }

    // MARK: TCP query

    /// Asks the portmapper of `host` over TCP whether NFS is registered.
    /// Useful when UDP is filtered. Returns the NFS port, or nil.
    public static func nfsPortOverTCP(host: UInt32, timeout: TimeInterval = 2) -> UInt16? {
        guard let fd = Sockets.connectWithTimeout(host: host, port: portmapperPort, timeout: timeout) else { return nil }
        defer { close(fd) }

        let baseXID = UInt32.random(in: 1...(UInt32.max - 64))
        for (index, query) in nfsQueries.enumerated() {
            let xid = baseXID + UInt32(index)
            let call = getPortCall(xid: xid, program: nfsProgram, version: query.version, transport: query.transport)
            // Record marking: last fragment bit + length.
            let marker = UInt32(0x8000_0000) | UInt32(call.count)
            let record = [UInt8(marker >> 24), UInt8(marker >> 16 & 0xFF), UInt8(marker >> 8 & 0xFF), UInt8(marker & 0xFF)] + call
            guard writeAll(fd: fd, bytes: record, timeout: timeout),
                  let header = readExactly(fd: fd, count: 4, timeout: timeout)
            else { return nil }
            let length = Int((UInt32(header[0]) << 24 | UInt32(header[1]) << 16 | UInt32(header[2]) << 8 | UInt32(header[3])) & 0x7FFF_FFFF)
            guard length > 0, length < 4096,
                  let body = readExactly(fd: fd, count: length, timeout: timeout)
            else { return nil }
            if let reply = parseGetPortReply(body), reply.xid == xid,
               reply.port > 0, reply.port <= UInt32(UInt16.max) {
                return UInt16(reply.port)
            }
        }
        return nil
    }

    private static func writeAll(fd: Int32, bytes: [UInt8], timeout: TimeInterval) -> Bool {
        var offset = 0
        while offset < bytes.count {
            guard Sockets.wait(fd: fd, events: Int16(POLLOUT), timeout: timeout) else { return false }
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    private static func readExactly(fd: Int32, count: Int, timeout: TimeInterval) -> [UInt8]? {
        var data = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: count)
        while data.count < count {
            guard Sockets.wait(fd: fd, events: Int16(POLLIN), timeout: timeout) else { return nil }
            let wanted = count - data.count
            let got = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, wanted) }
            if got < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                return nil
            }
            if got == 0 { return nil }
            data += chunk[0..<got]
        }
        return data
    }
}
