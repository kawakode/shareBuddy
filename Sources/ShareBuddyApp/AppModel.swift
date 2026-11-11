import AppKit
import Foundation
import ShareBuddyCore

/// State of the ShareBuddy window.
@MainActor
final class AppModel: ObservableObject {
    enum ProtocolFilter: String, CaseIterable, Identifiable {
        case nfs, smb, both
        var id: String { rawValue }
        var label: String {
            switch self {
            case .nfs: return "NFS"
            case .smb: return "SMB"
            case .both: return "NFS + SMB"
            }
        }
        var protocols: Set<ShareProtocol> {
            switch self {
            case .nfs: return [.nfs]
            case .smb: return [.smb]
            case .both: return [.nfs, .smb]
            }
        }
    }

    enum ListingState {
        case loading
        case loaded([NetworkShare])
        case failed(String)
    }

    struct AlertItem: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Published var servers: [DiscoveredServer] = []
    @Published var selectedServerID: String?
    @Published var listings: [String: [ShareProtocol: ListingState]] = [:]
    @Published var mounted: [MountedShare] = []

    @Published var filter: ProtocolFilter = .both
    @Published var deepScan = false
    /// Optional subnets typed by the user, e.g. "10.0.0.0/24, 192.168.1.0/24".
    @Published var subnetText = ""

    @Published var isScanning = false
    @Published var hasScanned = false
    @Published var status = "Clique sur « Scanner » pour chercher les partages du réseau."
    @Published var warnings: [String] = []
    /// URLs of shares being mounted or unmounted.
    @Published var busy: Set<String> = []
    @Published var alert: AlertItem?

    var selectedServer: DiscoveredServer? {
        servers.first { $0.address == selectedServerID }
    }

    // MARK: Scan

    func scan() async {
        guard !isScanning else { return }
        var options = ScanOptions()
        options.protocols = filter.protocols
        options.deepNFS = deepScan
        let typed = subnetText
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == ";" })
            .map(String.init)
        if !typed.isEmpty {
            var subnets: [IPv4Subnet] = []
            for raw in typed {
                guard let subnet = IPv4Subnet(cidr: raw) else {
                    alert = AlertItem(title: "Sous-réseau invalide", message: "« \(raw) » n'est pas valide. Exemple : 10.0.0.0/24")
                    return
                }
                subnets.append(subnet)
            }
            options.subnets = subnets
        }

        isScanning = true
        warnings = []
        let scanned = NetworkScanner.subnetsToScan(options).map(\.description).joined(separator: ", ")
        status = deepScan
            ? "Scan approfondi de \(scanned.isEmpty ? "Bonjour" : scanned)…"
            : "Scan de \(scanned.isEmpty ? "Bonjour" : scanned)…"

        let result = await NetworkScanner.run(options: options)
        let manual = servers.filter { $0.sources.contains(.manual) }
        servers = NetworkScanner.merge(result.servers + manual)
        warnings = result.warnings
        listings = [:]
        isScanning = false
        hasScanned = true

        let nfsCount = servers.filter { $0.protocols.contains(.nfs) }.count
        let smbCount = servers.filter { $0.protocols.contains(.smb) }.count
        status = servers.isEmpty
            ? (deepScan ? "Aucun serveur trouvé." : "Aucun serveur trouvé. Essaie le scan approfondi.")
            : "\(servers.count) serveur(s) : \(nfsCount) NFS, \(smbCount) SMB."
        if selectedServer == nil { selectedServerID = servers.first?.address }
        refreshMounts()
    }

    /// Adds a server by hand (name or IP), for hosts the scan cannot see.
    func addServer(_ rawHost: String) {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        let manual = DiscoveredServer(address: host, protocols: filter.protocols, sources: [.manual])
        servers = NetworkScanner.merge(servers + [manual])
        listings[host] = nil
        selectedServerID = host
    }

    // MARK: Shares

    func loadSharesIfNeeded(for server: DiscoveredServer) async {
        for kind in server.sortedProtocols where filter.protocols.contains(kind) {
            if listings[server.address]?[kind] == nil {
                await loadShares(for: server, kind: kind)
            }
        }
    }

    func loadShares(for server: DiscoveredServer, kind: ShareProtocol) async {
        listings[server.address, default: [:]][kind] = .loading
        do {
            let shares = try await ShareLister.shares(of: server.address, kind: kind)
            listings[server.address, default: [:]][kind] = .loaded(shares)
        } catch {
            listings[server.address, default: [:]][kind] = .failed(error.localizedDescription)
        }
    }

    // MARK: Mounting

    func refreshMounts() {
        mounted = MountedShares.list()
    }

    func mountedShare(for share: NetworkShare) -> MountedShare? {
        mounted.first { mountedShare in
            guard mountedShare.kind == share.kind,
                  let server = mountedShare.server,
                  Self.sameHost(server, share.server)
            else { return false }
            switch share.kind {
            case .nfs:
                guard let colon = mountedShare.source.range(of: ":/") else { return false }
                let path = String(mountedShare.source[mountedShare.source.index(before: colon.upperBound)...])
                return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    == share.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            case .smb:
                let name = mountedShare.source.split(separator: "/").last.map(String.init) ?? ""
                let decoded = name.removingPercentEncoding ?? name
                return decoded.caseInsensitiveCompare(share.path) == .orderedSame
            }
        }
    }

    private static func sameHost(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ host: String) -> String {
            var host = host.lowercased()
            for suffix in ["._smb._tcp.local", "._nfs._tcp.local", ".local"] where host.hasSuffix(suffix) {
                host = String(host.dropLast(suffix.count))
            }
            return host
        }
        return normalized(lhs) == normalized(rhs)
    }

    func mount(_ share: NetworkShare) async {
        guard let url = share.url else { return }
        let key = url.absoluteString
        busy.insert(key)
        defer { busy.remove(key) }

        var request = MountRequest(url: url)
        // Let macOS ask for a password itself when the server needs one.
        request.allowUI = true
        do {
            let points = try await ShareMounter.mount(request)
            refreshMounts()
            if let first = points.first ?? mountedShare(for: share)?.mountPoint {
                NSWorkspace.shared.open(URL(fileURLWithPath: first))
            }
        } catch {
            refreshMounts()
            alert = AlertItem(title: "Montage impossible", message: error.localizedDescription)
        }
    }

    func unmount(_ mountedShare: MountedShare) async {
        busy.insert(mountedShare.mountPoint)
        defer { busy.remove(mountedShare.mountPoint) }
        do {
            try await ShareMounter.unmount(path: mountedShare.mountPoint)
        } catch {
            alert = AlertItem(title: "Démontage impossible", message: error.localizedDescription)
        }
        refreshMounts()
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    /// Hands an SMB server to Finder, which asks for credentials and lists the shares.
    func openInFinder(server: DiscoveredServer, kind: ShareProtocol) {
        if let url = URL(string: "\(kind.rawValue)://\(server.address)") {
            NSWorkspace.shared.open(url)
        }
    }
}
