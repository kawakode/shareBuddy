import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A network file system currently mounted on this Mac.
public struct MountedShare: Hashable, Codable, Sendable {
    public let kind: ShareProtocol
    /// What the kernel reports as the source, e.g. "nas:/volume1/media" or "//bob@nas/Public".
    public let source: String
    public let mountPoint: String

    public init(kind: ShareProtocol, source: String, mountPoint: String) {
        self.kind = kind
        self.source = source
        self.mountPoint = mountPoint
    }

    /// Server name or address extracted from `source`.
    public var server: String? {
        switch kind {
        case .nfs:
            guard let colon = source.range(of: ":/") else { return nil }
            return String(source[..<colon.lowerBound])
        case .smb:
            var rest = Substring(source)
            guard rest.hasPrefix("//") else { return nil }
            rest = rest.dropFirst(2)
            if let at = rest.lastIndex(of: "@") { rest = rest[rest.index(after: at)...] }
            return rest.split(separator: "/").first.map(String.init)
        }
    }
}

public enum MountedShares {
    /// Maps a kernel file-system type to a ShareBuddy protocol.
    public static func kind(forFileSystemType type: String) -> ShareProtocol? {
        switch type.lowercased() {
        case "nfs": return .nfs
        case "smbfs": return .smb
        default: return nil
        }
    }

    /// NFS and SMB file systems currently mounted.
    public static func list() -> [MountedShare] {
        #if os(macOS)
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }

        var shares: [MountedShare] = []
        for index in 0..<Int(count) {
            var entry = buffer[index]
            let type = cString(&entry.f_fstypename)
            guard let shareKind = kind(forFileSystemType: type) else { continue }
            shares.append(MountedShare(
                kind: shareKind,
                source: cString(&entry.f_mntfromname),
                mountPoint: cString(&entry.f_mntonname)
            ))
        }
        return shares.sorted { $0.mountPoint < $1.mountPoint }
        #else
        return []
        #endif
    }

    /// Reads a fixed-size C char array (imported by Swift as a tuple).
    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
