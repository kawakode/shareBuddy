import Foundation

/// An IPv4 address with its prefix length, e.g. 192.168.1.23/24.
/// Addresses are stored as host-order `UInt32`.
public struct IPv4Subnet: Hashable, Sendable, CustomStringConvertible {
    public let address: UInt32
    public let prefixLength: Int
    public let interfaceName: String?

    public init(address: UInt32, prefixLength: Int, interfaceName: String? = nil) {
        self.address = address
        self.prefixLength = max(0, min(32, prefixLength))
        self.interfaceName = interfaceName
    }

    /// Parses "192.168.1.0/24" (or a bare address, treated as /32).
    public init?(cidr: String) {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let address = IPv4Subnet.parseAddress(String(parts[0]))
        else { return nil }
        var prefix = 32
        if parts.count == 2 {
            guard let p = Int(parts[1]), (0...32).contains(p) else { return nil }
            prefix = p
        }
        self.init(address: address, prefixLength: prefix)
    }

    public var mask: UInt32 {
        prefixLength == 0 ? 0 : UInt32.max << UInt32(32 - prefixLength)
    }

    public var network: UInt32 { address & mask }
    public var broadcast: UInt32 { network | ~mask }

    public var description: String {
        "\(IPv4Subnet.format(network))/\(prefixLength)"
    }

    /// Host addresses to probe. Subnets larger than `maxPrefix` (e.g. a /16) are
    /// narrowed to the `maxPrefix` block that contains our own address, so that a
    /// scan stays short.
    public func hostAddresses(maxPrefix: Int = 22) -> [UInt32] {
        let effective = narrowed(to: maxPrefix)
        if effective.prefixLength >= 31 {
            return Array(Set([effective.network, effective.broadcast])).sorted()
        }
        let first = effective.network + 1
        let last = effective.broadcast - 1
        return Array(first...last)
    }

    /// The block of size `maxPrefix` that contains our address, when this subnet is larger.
    public func narrowed(to maxPrefix: Int) -> IPv4Subnet {
        prefixLength < maxPrefix
            ? IPv4Subnet(address: address, prefixLength: maxPrefix, interfaceName: interfaceName)
            : self
    }

    /// Directed broadcast address, if the subnet has one.
    public var broadcastAddress: UInt32? {
        prefixLength <= 30 ? broadcast : nil
    }

    public static func parseAddress(_ string: String) -> UInt32? {
        let octets = string.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var value: UInt32 = 0
        for octet in octets {
            guard !octet.isEmpty, octet.count <= 3, octet.allSatisfy(\.isASCII),
                  let byte = UInt8(octet)
            else { return nil }
            value = (value << 8) | UInt32(byte)
        }
        return value
    }

    public static func format(_ address: UInt32) -> String {
        "\(address >> 24 & 0xFF).\(address >> 16 & 0xFF).\(address >> 8 & 0xFF).\(address & 0xFF)"
    }
}
