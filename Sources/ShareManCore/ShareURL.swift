import Foundation

/// Builds and parses the share locations that ShareMan accepts.
///
/// Accepted forms:
/// - `nfs://host/export/path`, `smb://[user@]host/Share` (also `cifs://`)
/// - `host:/export/path` (classic NFS notation)
/// - `//[user@]host/Share` (classic SMB notation)
public enum ShareURL {
    /// Characters allowed in a URL path segment (no "/" — it separates segments).
    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove("/")
        set.remove(";")
        return set
    }()

    /// Builds a `nfs://` or `smb://` URL for a share on `host`.
    public static func make(kind: ShareProtocol, host: String, path: String, user: String? = nil) -> URL? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encodedPath = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { $0.addingPercentEncoding(withAllowedCharacters: segmentAllowed) ?? String($0) }
            .joined(separator: "/")
        var userPart = ""
        if let user, !user.isEmpty {
            let encodedUser = user.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? user
            userPart = encodedUser + "@"
        }
        return URL(string: "\(kind.rawValue)://\(userPart)\(formatHost(host))/\(encodedPath)")
    }

    /// Wraps bare IPv6 literals in brackets so they can be used in a URL.
    static func formatHost(_ host: String) -> String {
        // More than one ":" means IPv6; a single one is "host:port".
        if host.filter({ $0 == ":" }).count > 1 && !host.hasPrefix("[") {
            return "[\(host)]"
        }
        return host
    }

    /// Parses a user-supplied share location into a mountable URL.
    public static func parse(_ raw: String, user: String? = nil) throws -> URL {
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { throw ShareManError.invalidTarget(raw) }

        if let schemeRange = target.range(of: "://") {
            let scheme = target[..<schemeRange.lowerBound].lowercased()
            let kind: ShareProtocol
            switch scheme {
            case "nfs": kind = .nfs
            case "smb", "cifs": kind = .smb
            default: throw ShareManError.invalidTarget(raw)
            }
            let rest = String(target[schemeRange.upperBound...])
            return try fromAuthorityAndPath(rest, kind: kind, user: user, raw: raw)
        }

        if target.hasPrefix("//") {
            return try fromAuthorityAndPath(String(target.dropFirst(2)), kind: .smb, user: user, raw: raw)
        }

        // NFS "host:/path". Requires ":/" so that IPv6 literals are not mistaken for it.
        if let sep = target.range(of: ":/") {
            let host = String(target[..<sep.lowerBound])
            let path = String(target[target.index(before: sep.upperBound)...])
            guard !host.isEmpty, let url = make(kind: .nfs, host: host, path: path) else {
                throw ShareManError.invalidTarget(raw)
            }
            return url
        }

        throw ShareManError.invalidTarget(raw)
    }

    private static func fromAuthorityAndPath(_ rest: String, kind: ShareProtocol, user: String?, raw: String) throws -> URL {
        guard let slash = rest.firstIndex(of: "/") else { throw ShareManError.invalidTarget(raw) }
        var authority = String(rest[..<slash])
        let path = String(rest[slash...]).removingPercentEncoding ?? String(rest[slash...])
        var effectiveUser = user
        if let at = authority.lastIndex(of: "@") {
            let embeddedUser = String(authority[..<at]).removingPercentEncoding
            if effectiveUser == nil { effectiveUser = embeddedUser }
            authority = String(authority[authority.index(after: at)...])
        }
        if authority.hasPrefix("["), authority.hasSuffix("]") {
            authority = String(authority.dropFirst().dropLast())
        }
        let pathIsEmpty = path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty
        guard !authority.isEmpty, !pathIsEmpty,
              let url = make(kind: kind, host: authority, path: path, user: effectiveUser)
        else {
            throw ShareManError.invalidTarget(raw)
        }
        return url
    }
}
