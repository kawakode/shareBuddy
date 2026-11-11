import Foundation

/// Network file-sharing protocols that ShareBuddy knows how to discover and mount.
public enum ShareProtocol: String, Codable, CaseIterable, Comparable, Sendable {
    case nfs
    case smb

    /// TCP port used to detect a server speaking this protocol.
    public var port: UInt16 {
        switch self {
        case .nfs: return 2049
        case .smb: return 445
        }
    }

    /// Bonjour (DNS-SD) service type advertised by servers of this protocol.
    public var bonjourType: String {
        switch self {
        case .nfs: return "_nfs._tcp"
        case .smb: return "_smb._tcp"
        }
    }

    public var displayName: String { rawValue.uppercased() }

    /// NFS sorts before SMB: it is the protocol ShareBuddy prioritises.
    public static func < (lhs: ShareProtocol, rhs: ShareProtocol) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// How a server was found.
public enum DiscoverySource: String, Codable, Comparable, Sendable {
    case bonjour
    case portScan = "port-scan"

    public static func < (lhs: DiscoverySource, rhs: DiscoverySource) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A host on the network that offers at least one file-sharing protocol.
public struct DiscoveredServer: Hashable, Codable, Sendable {
    /// Address used to reach the server (IPv4 address when known).
    public var address: String
    /// Bonjour service name, e.g. "DiskStation", when the server advertises itself.
    public var bonjourName: String?
    public var protocols: Set<ShareProtocol>
    public var sources: Set<DiscoverySource>

    public init(
        address: String,
        bonjourName: String? = nil,
        protocols: Set<ShareProtocol>,
        sources: Set<DiscoverySource>
    ) {
        self.address = address
        self.bonjourName = bonjourName
        self.protocols = protocols
        self.sources = sources
    }

    public var displayName: String { bonjourName ?? address }

    public var sortedProtocols: [ShareProtocol] { protocols.sorted() }
}

/// A single NFS export or SMB share offered by a server.
public struct NetworkShare: Hashable, Codable, Sendable {
    public var server: String
    public var kind: ShareProtocol
    /// NFS: absolute export path (e.g. "/volume1/media"). SMB: share name (e.g. "Public").
    public var path: String
    /// NFS only: clients allowed by the export ("Everyone", "192.168.1.0/24", ...).
    public var allowedClients: [String]
    /// SMB only: free-form comment returned by the server.
    public var comment: String?

    public init(
        server: String,
        kind: ShareProtocol,
        path: String,
        allowedClients: [String] = [],
        comment: String? = nil
    ) {
        self.server = server
        self.kind = kind
        self.path = path
        self.allowedClients = allowedClients
        self.comment = comment
    }

    /// URL understood by macOS (Finder "Connect to Server" and NetFS).
    public var url: URL? { ShareURL.make(kind: kind, host: server, path: path) }
}

public enum ShareBuddyError: LocalizedError, Equatable {
    case commandFailed(command: String, status: Int32, message: String)
    case commandTimedOut(command: String)
    case invalidTarget(String)
    case mountFailed(code: Int32, message: String)
    case unmountFailed(path: String, message: String)
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status, message):
            let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return "« \(command) » a échoué (code \(status))" + (detail.isEmpty ? "." : " : \(detail)")
        case let .commandTimedOut(command):
            return "« \(command) » n'a pas répondu à temps."
        case let .invalidTarget(target):
            return "Cible invalide : « \(target) ». Exemples : nfs://nas/volume1/data, nas:/volume1/data, smb://nas/Public, //nas/Public."
        case let .mountFailed(_, message):
            return message
        case let .unmountFailed(path, message):
            return "Impossible de démonter \(path) : \(message)"
        case .unsupportedPlatform:
            return "Cette fonction n'est disponible que sur macOS."
        }
    }
}
