import Foundation

/// Lists the NFS exports and SMB shares offered by a server, using the tools
/// that ship with macOS (`showmount`, `smbutil`).
public enum ShareLister {
    public static let showmountPath = "/usr/bin/showmount"
    public static let smbutilPath = "/usr/bin/smbutil"

    /// NFS exports announced by `host` (RPC mountd).
    public static func nfsExports(host: String, timeout: TimeInterval = 10) async throws -> [NetworkShare] {
        let result = try await CommandRunner.run(showmountPath, ["-e", host], timeout: timeout)
        guard result.status == 0 else {
            throw ShareBuddyError.commandFailed(
                command: "showmount -e \(host)",
                status: result.status,
                message: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return ShowmountParser.parse(result.stdout).map {
            NetworkShare(server: host, kind: .nfs, path: $0.path, allowedClients: $0.clients)
        }
    }

    /// SMB shares of `host`.
    ///
    /// Without `user`, a guest listing is attempted and no password is ever asked.
    /// With `user`, `smbutil` uses the password stored in the keychain, or asks
    /// for it on the terminal when `interactive` is true.
    public static func smbShares(
        host: String,
        user: String? = nil,
        interactive: Bool = false,
        includeHidden: Bool = false,
        timeout: TimeInterval = 15
    ) async throws -> [NetworkShare] {
        var arguments = ["view"]
        let target: String
        if let user, !user.isEmpty {
            if !interactive { arguments.append("-N") }
            target = "//\(user)@\(ShareURL.formatHost(host))"
        } else {
            arguments += ["-G", "-N"]
            target = "//\(ShareURL.formatHost(host))"
        }
        arguments.append(target)

        let result = try await CommandRunner.run(
            smbutilPath,
            arguments,
            timeout: interactive ? max(timeout, 120) : timeout
        )
        guard result.status == 0 else {
            throw ShareBuddyError.commandFailed(
                command: "smbutil view \(target)",
                status: result.status,
                message: result.stderr.isEmpty ? result.stdout : result.stderr
            )
        }
        return SmbutilParser.parse(result.stdout)
            .filter { $0.isDisk && (includeHidden || !$0.isHidden) }
            .map { NetworkShare(server: host, kind: .smb, path: $0.name, comment: $0.comment) }
    }

    /// Exports or shares of `host` for the given protocol (SMB as guest).
    public static func shares(of host: String, kind: ShareProtocol) async throws -> [NetworkShare] {
        switch kind {
        case .nfs: return try await nfsExports(host: host)
        case .smb: return try await smbShares(host: host)
        }
    }
}
