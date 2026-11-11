import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Information about the Mac's own network interfaces.
public enum LocalNetwork {
    /// IPv4 subnets of the interfaces that are up, excluding loopback,
    /// point-to-point links (VPN tunnels) and link-local (169.254.x.x) addresses.
    public static func activeIPv4Subnets() -> [IPv4Subnet] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var subnets: [IPv4Subnet] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let ifa = entry.pointee
            let flags = Int32(bitPattern: UInt32(ifa.ifa_flags))
            guard flags & Int32(IFF_UP) != 0,
                  flags & Int32(IFF_RUNNING) != 0,
                  flags & Int32(IFF_LOOPBACK) == 0,
                  flags & Int32(IFF_POINTOPOINT) == 0,
                  let addr = ifa.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let netmask = ifa.ifa_netmask
            else { continue }

            let address = ipv4(from: addr)
            let mask = ipv4(from: netmask)
            // Skip link-local 169.254.0.0/16.
            if address >> 16 == 0xA9FE { continue }

            let name = String(cString: ifa.ifa_name)
            subnets.append(IPv4Subnet(address: address, prefixLength: mask.nonzeroBitCount, interfaceName: name))
        }
        return subnets
    }

    private static func ipv4(from sockaddrPointer: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        sockaddrPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
        }
    }
}
