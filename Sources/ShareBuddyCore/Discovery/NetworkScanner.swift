import Foundation

public struct ScanOptions: Sendable {
    /// Protocols to look for. NFS is ShareBuddy's priority, SMB comes second.
    public var protocols: Set<ShareProtocol> = [.nfs, .smb]
    /// Listen for Bonjour advertisements (`_nfs._tcp`, `_smb._tcp`).
    public var useBonjour = true
    /// Probe every address of the local subnets on the protocol ports.
    public var usePortScan = true
    /// Subnets to scan. `nil` means the subnets of the Mac's active interfaces.
    public var subnets: [IPv4Subnet]?
    /// Larger subnets are narrowed to the block of this size around our address.
    public var maxPrefix = 24
    public var bonjourDuration: TimeInterval = 3
    public var connectTimeout: TimeInterval = 0.6

    public init() {}
}

/// Finds NFS and SMB servers on the local network.
public enum NetworkScanner {
    public static func scan(options: ScanOptions = ScanOptions()) async -> [DiscoveredServer] {
        let protocols = ShareProtocol.allCases.filter { options.protocols.contains($0) }
        guard !protocols.isEmpty else { return [] }

        async let bonjourResults: [DiscoveredServer] = options.useBonjour
            ? bonjourScan(protocols: protocols, duration: options.bonjourDuration)
            : []
        async let portResults: [DiscoveredServer] = options.usePortScan
            ? portScan(protocols: protocols, options: options)
            : []

        return merge(await bonjourResults + portResults)
    }

    /// Subnets that a scan with these options would cover.
    public static func subnetsToScan(_ options: ScanOptions) -> [IPv4Subnet] {
        let subnets = options.subnets ?? LocalNetwork.activeIPv4Subnets()
        // Two interfaces on the same network (Wi-Fi + Ethernet) are scanned once.
        var seen = Set<String>()
        return subnets.filter { subnet in
            let key = IPv4Subnet(address: subnet.address, prefixLength: max(subnet.prefixLength, options.maxPrefix)).description
            return seen.insert(key).inserted
        }
    }

    static func bonjourScan(protocols: [ShareProtocol], duration: TimeInterval) async -> [DiscoveredServer] {
        await withTaskGroup(of: [DiscoveredServer].self) { group in
            for kind in protocols {
                group.addTask {
                    await BonjourBrowser.discover(serviceType: kind.bonjourType, browseDuration: duration).map {
                        DiscoveredServer(address: $0.address, bonjourName: $0.name, protocols: [kind], sources: [.bonjour])
                    }
                }
            }
            var all: [DiscoveredServer] = []
            for await servers in group { all += servers }
            return all
        }
    }

    static func portScan(protocols: [ShareProtocol], options: ScanOptions) async -> [DiscoveredServer] {
        let hosts = Array(Set(subnetsToScan(options).flatMap { $0.hostAddresses(maxPrefix: options.maxPrefix) })).sorted()
        guard !hosts.isEmpty else { return [] }
        let ports = protocols.map(\.port)
        let open = await PortScanner.scan(hosts: hosts, ports: ports, timeout: options.connectTimeout)
        return open.map { host, openPorts in
            DiscoveredServer(
                address: IPv4Subnet.format(host),
                protocols: Set(protocols.filter { openPorts.contains($0.port) }),
                sources: [.portScan]
            )
        }
    }

    /// Merges duplicates (same address) and sorts: NFS servers first, then by address.
    public static func merge(_ servers: [DiscoveredServer]) -> [DiscoveredServer] {
        var byAddress: [String: DiscoveredServer] = [:]
        for server in servers {
            if var existing = byAddress[server.address] {
                existing.protocols.formUnion(server.protocols)
                existing.sources.formUnion(server.sources)
                existing.bonjourName = existing.bonjourName ?? server.bonjourName
                byAddress[server.address] = existing
            } else {
                byAddress[server.address] = server
            }
        }
        return byAddress.values.sorted { lhs, rhs in
            let lhsNFS = lhs.protocols.contains(.nfs)
            let rhsNFS = rhs.protocols.contains(.nfs)
            if lhsNFS != rhsNFS { return lhsNFS }
            return addressSortKey(lhs.address) < addressSortKey(rhs.address)
        }
    }

    private static func addressSortKey(_ address: String) -> String {
        if let ip = IPv4Subnet.parseAddress(address) {
            return String(format: "0-%010u", ip)
        }
        return "1-" + address.lowercased()
    }
}
