import ArgumentParser
import Foundation
import ShareBuddyCore

@main
struct ShareBuddyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sharebuddy",
        abstract: "Découvre les partages NFS et SMB du réseau local et les monte sur macOS.",
        version: "0.1.0",
        subcommands: [Scan.self, Shares.self, Mount.self, Mounts.self, Unmount.self],
        defaultSubcommand: Scan.self
    )
}

// MARK: - Shared options

struct ProtocolOptions: ParsableArguments {
    @Flag(name: .customLong("nfs"), help: "Uniquement NFS.")
    var nfsOnly = false

    @Flag(name: .customLong("smb"), help: "Uniquement SMB.")
    var smbOnly = false

    var protocols: Set<ShareProtocol> {
        switch (nfsOnly, smbOnly) {
        case (true, false): return [.nfs]
        case (false, true): return [.smb]
        default: return [.nfs, .smb]
        }
    }
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    print(String(decoding: data, as: UTF8.self))
}

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

// MARK: - scan

struct Scan: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Cherche les serveurs NFS et SMB (Bonjour + scan du sous-réseau) et liste leurs partages."
    )

    @OptionGroup var protocolOptions: ProtocolOptions

    @Option(name: .customLong("subnet"), help: "Sous-réseau à scanner (ex. 192.168.1.0/24). Répétable. Par défaut : celui de chaque interface active.")
    var subnets: [String] = []

    @Flag(name: .customLong("no-bonjour"), help: "Ne pas écouter les annonces Bonjour.")
    var noBonjour = false

    @Flag(name: .customLong("no-portscan"), help: "Ne pas scanner les ports du sous-réseau.")
    var noPortScan = false

    @Flag(name: .customLong("no-shares"), help: "Ne pas lister les exports / partages de chaque serveur.")
    var noShares = false

    @Flag(name: [.customShort("d"), .customLong("deep")], help: "Scan NFS approfondi : sous-réseau entier (jusqu'à /20), délais plus longs et requêtes RPC au portmapper (port 111, UDP et TCP).")
    var deep = false

    @Option(help: "Délai de connexion par adresse, en secondes.")
    var timeout: Double = 0.6

    @Option(name: .customLong("bonjour-time"), help: "Durée d'écoute Bonjour, en secondes.")
    var bonjourTime: Double = 3

    @Flag(name: [.customShort("v"), .customLong("verbose")], help: "Afficher des détails de diagnostic.")
    var verbose = false

    @Flag(help: "Sortie JSON.")
    var json = false

    func run() async throws {
        var options = ScanOptions()
        options.protocols = protocolOptions.protocols
        options.useBonjour = !noBonjour
        options.usePortScan = !noPortScan
        options.connectTimeout = timeout
        options.deepNFS = deep
        options.bonjourDuration = bonjourTime
        if !subnets.isEmpty {
            options.subnets = try subnets.map { raw in
                guard let subnet = IPv4Subnet(cidr: raw) else {
                    throw ValidationError("Sous-réseau invalide : \(raw)")
                }
                return subnet
            }
        }

        if !json {
            let scanned = NetworkScanner.subnetsToScan(options)
            let what = options.protocols.sorted().map(\.displayName).joined(separator: " + ")
            var sources: [String] = []
            if options.useBonjour { sources.append("Bonjour") }
            if options.usePortScan {
                sources.append(scanned.isEmpty ? "aucun sous-réseau" : scanned.map(\.description).joined(separator: ", "))
            }
            if deep { sources.append("RPC port 111") }
            let mode = deep ? " en mode approfondi" : ""
            print("Recherche des serveurs \(what)\(mode) (\(sources.joined(separator: ", ")))…")
        }

        let result = await NetworkScanner.run(options: options)
        let servers = result.servers
        if !json {
            result.warnings.forEach { printError("Attention : \($0)") }
            if verbose { printError(result.diagnostics) }
        }
        let protocols = options.protocols
        let listShares = !noShares
        let report = await withTaskGroup(of: ServerReport.self) { group in
            for server in servers {
                group.addTask { await ServerReport.build(for: server, protocols: protocols, listShares: listShares) }
            }
            var reports: [ServerReport] = []
            for await report in group { reports.append(report) }
            // Keep the scanner's order (NFS servers first).
            return servers.compactMap { server in reports.first { $0.server == server } }
        }

        if json {
            try printJSON(report)
            return
        }
        guard !report.isEmpty else {
            print("\nAucun serveur trouvé." + (deep ? "" : " Essaie « sharebuddy scan --deep » pour un scan NFS approfondi."))
            return
        }
        print("")
        for entry in report {
            entry.printHuman()
        }
    }
}

struct ServerReport: Encodable, Sendable {
    struct Listing: Encodable, Sendable {
        let kind: ShareProtocol
        let shares: [NetworkShare]
        let error: String?
    }

    let server: DiscoveredServer
    let listings: [Listing]

    static func build(for server: DiscoveredServer, protocols: Set<ShareProtocol>, listShares: Bool) async -> ServerReport {
        guard listShares else { return ServerReport(server: server, listings: []) }
        var listings: [Listing] = []
        for kind in server.sortedProtocols where protocols.contains(kind) {
            do {
                let shares = try await ShareLister.shares(of: server.address, kind: kind)
                listings.append(Listing(kind: kind, shares: shares, error: nil))
            } catch {
                listings.append(Listing(kind: kind, shares: [], error: error.localizedDescription))
            }
        }
        return ServerReport(server: server, listings: listings)
    }

    func printHuman() {
        let protocols = server.sortedProtocols.map(\.displayName).joined(separator: ", ")
        var title = "● \(server.displayName)"
        if server.bonjourName != nil { title += " (\(server.address))" }
        print("\(title) — \(protocols)")
        for listing in listings {
            if let error = listing.error {
                let hint = listing.kind == .smb ? " (essaie « sharebuddy shares \(server.address) --smb --user <nom> »)" : ""
                print("    \(listing.kind.displayName) : impossible de lister les partages\(hint)")
                print("        \(error.replacingOccurrences(of: "\n", with: " "))")
                continue
            }
            if listing.shares.isEmpty {
                print("    \(listing.kind.displayName) : aucun partage visible")
                continue
            }
            for share in listing.shares {
                printShare(share)
            }
        }
        print("")
    }
}

func printShare(_ share: NetworkShare, indent: String = "    ") {
    let url = share.url?.absoluteString ?? "\(share.server):\(share.path)"
    var line = "\(indent)\(share.kind.displayName)  \(url)"
    if !share.allowedClients.isEmpty {
        line += "   [\(share.allowedClients.joined(separator: ", "))]"
    }
    if let comment = share.comment {
        line += "   — \(comment)"
    }
    print(line)
}

// MARK: - shares

struct Shares: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Liste les exports NFS et les partages SMB d'un serveur."
    )

    @Argument(help: "Nom ou adresse IP du serveur.")
    var host: String

    @OptionGroup var protocolOptions: ProtocolOptions

    @Option(help: "Utilisateur SMB (sinon, accès invité).")
    var user: String?

    @Flag(name: .customLong("hidden"), help: "Inclure les partages SMB cachés (IPC$, C$…).")
    var includeHidden = false

    @Flag(help: "Sortie JSON.")
    var json = false

    func run() async throws {
        var all: [NetworkShare] = []
        var failures = 0
        for kind in protocolOptions.protocols.sorted() {
            do {
                switch kind {
                case .nfs:
                    all += try await ShareLister.nfsExports(host: host)
                case .smb:
                    all += try await ShareLister.smbShares(
                        host: host,
                        user: user,
                        interactive: user != nil && !json,
                        includeHidden: includeHidden
                    )
                }
            } catch {
                failures += 1
                printError("\(kind.displayName) : \(error.localizedDescription)")
            }
        }
        if json {
            try printJSON(all)
        } else if all.isEmpty {
            print("Aucun partage trouvé sur \(host).")
        } else {
            all.forEach { printShare($0, indent: "") }
        }
        if all.isEmpty && failures > 0 { throw ExitCode.failure }
    }
}

// MARK: - mount

struct Mount: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Monte un partage NFS ou SMB.",
        discussion: """
        Formes acceptées :
          nfs://nas/volume1/media     nas:/volume1/media
          smb://nas/Public            //nas/Public        smb://bob@nas/Public
        """
    )

    @Argument(help: "Partage à monter.")
    var target: String

    @Option(help: "Utilisateur (SMB).")
    var user: String?

    @Flag(name: .customLong("ask-password"), help: "Demander le mot de passe dans le terminal.")
    var askPassword = false

    @Flag(help: "Connexion SMB en invité.")
    var guest = false

    @Option(name: .customLong("at"), help: "Dossier de montage (créé si besoin). Par défaut : /Volumes.")
    var mountPoint: String?

    @Flag(name: .customLong("read-only"), help: "Monter en lecture seule.")
    var readOnly = false

    @Flag(name: .customLong("ui"), help: "Laisser macOS afficher ses propres fenêtres (mot de passe, erreurs).")
    var allowUI = false

    func run() async throws {
        let url = try ShareURL.parse(target, user: user)
        var request = MountRequest(url: url, user: user ?? url.user)
        request.guest = guest
        request.mountPoint = mountPoint
        request.readOnly = readOnly
        request.allowUI = allowUI
        if askPassword {
            guard let raw = getpass("Mot de passe : ") else { throw ExitCode.failure }
            request.password = String(cString: raw)
        }

        print("Montage de \(url.absoluteString)…")
        do {
            let mountPoints = try await ShareMounter.mount(request)
            if mountPoints.isEmpty {
                print("Monté.")
            } else {
                mountPoints.forEach { print("Monté sur \($0)") }
            }
        } catch {
            printError(error.localizedDescription)
            throw ExitCode.failure
        }
    }
}

// MARK: - mounts

struct Mounts: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Liste les partages NFS et SMB actuellement montés."
    )

    @Flag(help: "Sortie JSON.")
    var json = false

    func run() async throws {
        let mounted = MountedShares.list()
        if json {
            try printJSON(mounted)
            return
        }
        guard !mounted.isEmpty else {
            print("Aucun partage réseau monté.")
            return
        }
        for share in mounted {
            print("\(share.kind.displayName)  \(share.source)  →  \(share.mountPoint)")
        }
    }
}

// MARK: - unmount

struct Unmount: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Démonte un partage réseau."
    )

    @Argument(help: "Point de montage (ex. /Volumes/media).")
    var path: String

    @Flag(help: "Forcer le démontage même si des fichiers sont ouverts.")
    var force = false

    func run() async throws {
        do {
            try await ShareMounter.unmount(path: path, force: force)
            print("Démonté : \(path)")
        } catch {
            printError(error.localizedDescription)
            throw ExitCode.failure
        }
    }
}
