import Foundation
#if os(macOS)
import CoreServices
#endif

public enum FinderFavoritesError: LocalizedError, Equatable {
    case notADirectory(String)
    /// macOS did not accept the change (the API is deprecated and may be ignored).
    case refused(String)
    case unsupportedPlatform

    public var errorDescription: String? {
        switch self {
        case let .notADirectory(path):
            return "« \(path) » n'est pas un dossier accessible."
        case let .refused(path):
            return "macOS n'a pas accepté de modifier les favoris du Finder pour « \(path) »."
        case .unsupportedPlatform:
            return "Les favoris du Finder n'existent que sur macOS."
        }
    }

    /// What the user can do by hand when the automatic change fails.
    public static let manualHint =
        "Dans le Finder, sélectionne le dossier puis choisis Fichier > Ajouter à la barre latérale (⌃⌘T), "
        + "ou fais-le glisser dans la section Favoris de la barre latérale."
}

/// Reads and edits the Favorites section of the Finder sidebar.
///
/// Apple offers no supported API for this. ShareMan uses the LSSharedFileList
/// functions that Finder itself relies on: they are deprecated but still
/// answer on current macOS. Every change is checked by reading the list back,
/// so a silent refusal is reported as `FinderFavoritesError.refused`.
public enum FinderFavorites {
    public enum AddOutcome: Equatable, Sendable {
        case added
        case alreadyPresent
    }

    /// Canonical form used to compare paths: no `~`, no trailing slash, symlinks resolved.
    public static func normalizedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var result = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath().path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// Paths of the favorites that point to something reachable right now.
    /// Items on unmounted volumes are skipped (they are never mounted to find out).
    public static func paths() -> [String] {
        #if os(macOS)
        guard let list = favoritesList(), let items = snapshot(of: list) else { return [] }
        return items.compactMap(resolvedPath)
        #else
        return []
        #endif
    }

    public static func contains(path: String) -> Bool {
        let target = normalizedPath(path)
        return paths().contains(target)
    }

    /// Adds a folder (typically a mount point in /Volumes) at the end of the Favorites.
    @discardableResult
    public static func add(path: String) throws -> AddOutcome {
        #if os(macOS)
        let target = normalizedPath(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FinderFavoritesError.notADirectory(path)
        }
        guard let list = favoritesList() else { throw FinderFavoritesError.refused(path) }

        let before = snapshot(of: list)
        if let before, before.contains(where: { resolvedPath($0) == target }) {
            return .alreadyPresent
        }

        let url = URL(fileURLWithPath: target, isDirectory: true) as CFURL
        let inserted = LSSharedFileListInsertItemURL(
            list,
            kLSSharedFileListItemLast.takeUnretainedValue(),
            nil, nil, url, nil, nil
        )
        guard inserted?.takeRetainedValue() != nil else { throw FinderFavoritesError.refused(path) }

        // When the list can be read, trust what it says rather than the return value.
        if before != nil, !waitUntil({ paths(in: list).contains(target) }) {
            throw FinderFavoritesError.refused(path)
        }
        return .added
        #else
        throw FinderFavoritesError.unsupportedPlatform
        #endif
    }

    /// Removes every favorite pointing to `path`. Returns false if there was none.
    @discardableResult
    public static func remove(path: String) throws -> Bool {
        #if os(macOS)
        let target = normalizedPath(path)
        guard let list = favoritesList(), let items = snapshot(of: list) else {
            throw FinderFavoritesError.refused(path)
        }
        let matches = items.filter { resolvedPath($0) == target }
        guard !matches.isEmpty else { return false }
        for item in matches {
            _ = LSSharedFileListItemRemove(list, item)
        }
        if !waitUntil({ !paths(in: list).contains(target) }) {
            throw FinderFavoritesError.refused(path)
        }
        return true
        #else
        throw FinderFavoritesError.unsupportedPlatform
        #endif
    }

    #if os(macOS)
    private static func favoritesList() -> LSSharedFileList? {
        LSSharedFileListCreate(nil, kLSSharedFileListFavoriteItems.takeUnretainedValue(), nil)?.takeRetainedValue()
    }

    private static func snapshot(of list: LSSharedFileList) -> [LSSharedFileListItem]? {
        var seed: UInt32 = 0
        guard let array = LSSharedFileListCopySnapshot(list, &seed)?.takeRetainedValue() else { return nil }
        return (0..<CFArrayGetCount(array)).compactMap { index in
            guard let pointer = CFArrayGetValueAtIndex(array, index) else { return nil }
            return Unmanaged<LSSharedFileListItem>.fromOpaque(pointer).takeUnretainedValue()
        }
    }

    private static func paths(in list: LSSharedFileList) -> [String] {
        (snapshot(of: list) ?? []).compactMap(resolvedPath)
    }

    private static func resolvedPath(_ item: LSSharedFileListItem) -> String? {
        let flags = LSSharedFileListResolutionFlags(kLSSharedFileListNoUserInteraction | kLSSharedFileListDoNotMountVolumes)
        guard let url = LSSharedFileListItemCopyResolvedURL(item, flags, nil)?.takeRetainedValue() else { return nil }
        return normalizedPath((url as URL).path)
    }

    /// The list is served by a daemon: give it a moment to reflect a change.
    private static func waitUntil(_ condition: () -> Bool) -> Bool {
        for attempt in 0..<10 {
            if condition() { return true }
            if attempt < 9 { Thread.sleep(forTimeInterval: 0.1) }
        }
        return false
    }
    #endif
}
