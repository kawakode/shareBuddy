import AppKit
import ShareManCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var manualHost = ""

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            if let server = model.selectedServer {
                ServerDetailView(server: server)
                    .id(server.address)
            } else {
                PlaceholderView()
            }
        }
        .toolbar { toolbarContent }
        .alert(item: $model.alert) { item in
            Alert(title: Text(item.title), message: Text(item.message))
        }
        .onAppear { model.refreshMounts() }
        // Favorites may have been edited in Finder while ShareMan was in the background.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshFavorites() }
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.selectedServerID) {
                Section("Serveurs") {
                    if model.servers.isEmpty {
                        Text(model.hasScanned ? "Aucun serveur trouvé" : "Pas encore de scan")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.servers, id: \.address) { server in
                        ServerRow(server: server)
                            .tag(server.address)
                    }
                }
                if !model.mounted.isEmpty {
                    Section("Partages montés") {
                        ForEach(model.mounted, id: \.mountPoint) { share in
                            MountedRow(share: share)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack(spacing: 6) {
                TextField("Ajouter un serveur (IP ou nom)", text: $manualHost)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addManualHost)
                Button(action: addManualHost) {
                    Image(systemName: "plus")
                }
                .disabled(manualHost.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Ajouter ce serveur à la liste")
            }
            .padding(8)

            StatusBar()
        }
    }

    private func addManualHost() {
        model.addServer(manualHost)
        manualHost = ""
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Protocoles", selection: $model.filter) {
                ForEach(AppModel.ProtocolFilter.allCases) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .help("Protocoles à rechercher")

            Toggle(isOn: $model.deepScan) {
                Label("Scan approfondi", systemImage: "scope")
            }
            .toggleStyle(.button)
            .disabled(model.filter == .smb)
            .help("Scan NFS approfondi : sous-réseau entier, délais plus longs, interrogation RPC du port 111. Plus lent.")

            TextField("Sous-réseau (auto)", text: $model.subnetText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .help("Facultatif. Exemple : 10.0.0.0/24. Plusieurs valeurs séparées par des virgules.")
                .onSubmit { Task { await model.scan() } }

            Button {
                Task { await model.scan() }
            } label: {
                if model.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Scanner", systemImage: "arrow.clockwise")
                }
            }
            .disabled(model.isScanning)
            .help("Chercher les serveurs (⌘R)")
        }
    }
}

// MARK: - Rows

struct ProtocolBadge: View {
    let kind: ShareProtocol

    var body: some View {
        Text(kind.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(kind == .nfs ? Color.blue.opacity(0.18) : Color.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(kind == .nfs ? Color.blue : Color.orange)
    }
}

struct ServerRow: View {
    let server: DiscoveredServer

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "server.rack")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .lineLimit(1)
                if server.bonjourName != nil {
                    Text(server.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            ForEach(server.sortedProtocols, id: \.self) { ProtocolBadge(kind: $0) }
        }
        .padding(.vertical, 2)
    }
}

struct MountedRow: View {
    @EnvironmentObject private var model: AppModel
    let share: MountedShare

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "externaldrive.connected.to.line.below")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 1) {
                Text((share.mountPoint as NSString).lastPathComponent)
                    .lineLimit(1)
                Text(share.source)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if model.busy.contains(share.mountPoint) {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    model.reveal(share.mountPoint)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Ouvrir dans le Finder")
                FavoriteButton(path: share.mountPoint)
                    .buttonStyle(.borderless)
                Button {
                    Task { await model.unmount(share) }
                } label: {
                    Image(systemName: "eject")
                }
                .buttonStyle(.borderless)
                .help("Démonter")
            }
        }
    }
}

/// Star that adds a mounted share to the Finder sidebar Favorites, or removes it.
struct FavoriteButton: View {
    @EnvironmentObject private var model: AppModel
    let path: String

    var body: some View {
        let isFavorite = model.isFavorite(path)
        Button {
            Task { await model.toggleFavorite(path) }
        } label: {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .foregroundStyle(isFavorite ? Color.yellow : Color.secondary)
        }
        .help(isFavorite ? "Retirer des favoris du Finder" : "Ajouter aux favoris du Finder")
    }
}

struct StatusBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(model.status)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

struct PlaceholderView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "network")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(model.servers.isEmpty ? "Aucun serveur" : "Choisis un serveur")
                .font(.title3)
            Text("Lance un scan pour trouver les partages NFS et SMB du réseau.\nSi un serveur NFS n'apparaît pas, active le scan approfondi ou ajoute-le à la main.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Scanner") { Task { await model.scan() } }
                .keyboardShortcut(.defaultAction)
                .disabled(model.isScanning)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Server detail

struct ServerDetailView: View {
    @EnvironmentObject private var model: AppModel
    let server: DiscoveredServer

    private var kinds: [ShareProtocol] {
        server.sortedProtocols.filter { model.filter.protocols.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if kinds.isEmpty {
                    Text("Ce serveur ne propose pas les protocoles sélectionnés.")
                        .foregroundStyle(.secondary)
                }
                ForEach(kinds, id: \.self) { kind in
                    listingSection(kind)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: model.filter) { await model.loadSharesIfNeeded(for: server) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(server.displayName)
                .font(.title2.weight(.semibold))
            HStack(spacing: 6) {
                Text(server.address)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                ForEach(server.sortedProtocols, id: \.self) { ProtocolBadge(kind: $0) }
                Text("· " + server.sources.sorted().map(sourceLabel).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sourceLabel(_ source: DiscoverySource) -> String {
        switch source {
        case .bonjour: return "Bonjour"
        case .portScan: return "scan de ports"
        case .rpc: return "RPC"
        case .manual: return "ajouté à la main"
        }
    }

    @ViewBuilder
    private func listingSection(_ kind: ShareProtocol) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                switch model.listings[server.address]?[kind] {
                case .none, .loading?:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(kind == .nfs ? "Lecture des exports…" : "Lecture des partages…")
                            .foregroundStyle(.secondary)
                    }
                    .padding(8)
                case .failed(let message)?:
                    VStack(alignment: .leading, spacing: 8) {
                        Text(kind == .nfs ? "Impossible de lister les exports." : "Impossible de lister les partages (accès invité refusé ?).")
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        HStack {
                            Button("Réessayer") { Task { await model.loadShares(for: server, kind: kind) } }
                            if kind == .smb {
                                Button("Se connecter avec le Finder…") { model.openInFinder(server: server, kind: kind) }
                            }
                        }
                    }
                    .padding(8)
                case .loaded(let shares)?:
                    if shares.isEmpty {
                        Text("Aucun partage visible.")
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                    ForEach(Array(shares.enumerated()), id: \.element) { index, share in
                        if index > 0 { Divider() }
                        ShareRow(share: share)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                ProtocolBadge(kind: kind)
                Text(kind == .nfs ? "Exports NFS" : "Partages SMB")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await model.loadShares(for: server, kind: kind) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Recharger")
            }
        }
    }
}

struct ShareRow: View {
    @EnvironmentObject private var model: AppModel
    let share: NetworkShare

    var body: some View {
        let mounted = model.mountedShare(for: share)
        let isBusy = share.url.map { model.busy.contains($0.absoluteString) } ?? false
            || mounted.map { model.busy.contains($0.mountPoint) } ?? false

        HStack(spacing: 10) {
            Image(systemName: mounted == nil ? "folder" : "folder.fill")
                .foregroundStyle(mounted == nil ? Color.secondary : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(share.path)
                    .textSelection(.enabled)
                if let mounted {
                    Text("Monté sur \(mounted.mountPoint)")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else if !share.allowedClients.isEmpty {
                    Text("Autorisé : " + share.allowedClients.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let comment = share.comment {
                    Text(comment)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if isBusy {
                ProgressView().controlSize(.small)
            } else if let mounted {
                FavoriteButton(path: mounted.mountPoint)
                    .buttonStyle(.borderless)
                Button("Ouvrir") { model.reveal(mounted.mountPoint) }
                Button("Démonter") { Task { await model.unmount(mounted) } }
            } else {
                Button("Monter") { Task { await model.mount(share) } }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
    }
}
