import Foundation
#if canImport(NetFS)
import NetFS
#endif

public struct MountRequest: Sendable {
    /// `nfs://host/export` or `smb://host/Share` (see `ShareURL.parse`).
    public var url: URL
    public var user: String?
    public var password: String?
    /// Connect to SMB as guest.
    public var guest = false
    /// Directory to mount into. `nil` lets macOS pick a folder in /Volumes.
    public var mountPoint: String?
    public var readOnly = false
    /// Let macOS show its own dialogs (password prompt, errors).
    public var allowUI = false

    public init(url: URL, user: String? = nil, password: String? = nil) {
        self.url = url
        self.user = user
        self.password = password
    }
}

/// Mounts network shares through Apple's NetFS framework, the same mechanism as
/// Finder's "Connect to Server". No root privileges are needed: shares are
/// mounted in /Volumes (or in a directory the user owns).
public enum ShareMounter {
    // NetFS.h defines its keys with CFSTR(), which Swift does not import.
    private static let uiOptionKey = "UIOption"            // kNAUIOptionKey
    private static let uiOptionNoUI = "NoUI"               // kNAUIOptionNoUI
    private static let uiOptionAllowUI = "AllowUI"         // kNAUIOptionAllowUI
    private static let useGuestKey = "Guest"               // kNetFSUseGuestKey
    private static let mountAtMountDirKey = "MountAtMountDir" // kNetFSMountAtMountDirKey
    private static let mountFlagsKey = "MountFlags"        // kNetFSMountFlagsKey
    private static let readOnlyFlag: Int32 = 0x1           // MNT_RDONLY

    /// Mounts the share and returns the mount point(s) created by macOS.
    public static func mount(_ request: MountRequest) async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try mountSync(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public static func mountSync(_ request: MountRequest) throws -> [String] {
        #if canImport(NetFS)
        let openOptions = NSMutableDictionary()
        openOptions[uiOptionKey] = request.allowUI ? uiOptionAllowUI : uiOptionNoUI
        if request.guest { openOptions[useGuestKey] = true }

        let mountOptions = NSMutableDictionary()
        var mountDirURL: URL?
        if let mountPoint = request.mountPoint {
            let url = URL(fileURLWithPath: (mountPoint as NSString).expandingTildeInPath, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            mountDirURL = url
            mountOptions[mountAtMountDirKey] = true
        }
        if request.readOnly {
            mountOptions[mountFlagsKey] = NSNumber(value: readOnlyFlag)
        }

        var mountPoints: Unmanaged<CFArray>?
        let status = NetFSMountURLSync(
            request.url as CFURL,
            mountDirURL.map { $0 as CFURL },
            request.user.map { $0 as CFString },
            request.password.map { $0 as CFString },
            openOptions as CFMutableDictionary,
            mountOptions as CFMutableDictionary,
            &mountPoints
        )
        let paths = (mountPoints?.takeRetainedValue() as? [String]) ?? []
        guard status == 0 else {
            throw ShareManError.mountFailed(code: status, message: describe(status: status, url: request.url))
        }
        return paths
        #else
        throw ShareManError.unsupportedPlatform
        #endif
    }

    /// Unmounts a volume previously mounted (by ShareMan or Finder).
    public static func unmount(path: String, force: Bool = false) async throws {
        #if os(macOS)
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        if force {
            let result = try await CommandRunner.run("/usr/sbin/diskutil", ["unmount", "force", url.path], timeout: 30)
            guard result.status == 0 else {
                throw ShareManError.unmountFailed(path: url.path, message: result.stderr.isEmpty ? result.stdout : result.stderr)
            }
            return
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            FileManager.default.unmountVolume(at: url, options: [.withoutUI]) { error in
                if let error {
                    continuation.resume(throwing: ShareManError.unmountFailed(path: url.path, message: error.localizedDescription))
                } else {
                    continuation.resume()
                }
            }
        }
        #else
        throw ShareManError.unsupportedPlatform
        #endif
    }

    /// Human-readable explanation of a NetFS / errno status code.
    public static func describe(status: Int32, url: URL) -> String {
        let isNFS = url.scheme?.lowercased() == "nfs"
        let target = url.absoluteString
        switch status {
        case 1, 13: // EPERM, EACCES
            if isNFS {
                return "Accès refusé par le serveur NFS pour \(target). Vérifie que l'export autorise l'adresse IP de ce Mac. "
                    + "Sur un serveur Linux, ajoute l'option « insecure » à l'export : macOS se connecte depuis un port non privilégié."
            }
            return "Accès refusé pour \(target) : identifiants ou droits insuffisants."
        case 2: // ENOENT
            return isNFS
                ? "L'export n'existe pas sur le serveur (\(target)). Liste les exports avec « shareman shares <hôte> »."
                : "Le partage n'existe pas sur le serveur (\(target))."
        case 17: // EEXIST
            return "\(target) est déjà monté. Vois « shareman mounts »."
        case 60: // ETIMEDOUT
            return "Le serveur ne répond pas (\(target))."
        case 61: // ECONNREFUSED
            return "Le serveur refuse la connexion (\(target)) : le service \(isNFS ? "NFS" : "SMB") est-il actif ?"
        case 64, 65: // EHOSTDOWN, EHOSTUNREACH
            return "Serveur injoignable (\(target))."
        case 80: // EAUTH
            return "Authentification refusée pour \(target). Vérifie l'utilisateur et le mot de passe."
        case -128: // userCanceledErr
            return "Montage annulé."
        case -5996: // ENETFSNOSHARESAVAIL
            return "Aucun partage disponible sur ce serveur."
        default:
            if status > 0, let message = strerror(status) {
                return "Échec du montage de \(target) : \(String(cString: message)) (code \(status))."
            }
            let hint = isNFS ? "" : " Si le serveur demande un compte, relance avec --user (et --ask-password)."
            return "Échec du montage de \(target) (code NetFS \(status))." + hint
        }
    }
}
