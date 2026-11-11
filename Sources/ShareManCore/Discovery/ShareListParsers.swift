import Foundation

/// Parses the output of `showmount -e <host>`:
///
///     Exports list on 192.168.1.10:
///     /volume1/media                     192.168.1.0/24
///     /volume1/backup                    Everyone
public enum ShowmountParser {
    public struct Export: Hashable, Sendable {
        public let path: String
        public let clients: [String]
    }

    public static func parse(_ output: String) -> [Export] {
        var exports: [Export] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("/") else { continue } // Skips the "Exports list on ..." header.
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let path = fields.first else { continue }
            exports.append(Export(path: path, clients: Array(fields.dropFirst())))
        }
        return exports
    }
}

/// Parses the output of `smbutil view //host`:
///
///     Share                                           Type    Comments
///     -------------------------------
///     Public                                          Disk
///     Time Machine                                    Disk    Backups
///     IPC$                                            Pipe    IPC Service (Samba 4.15)
///
///     3 shares listed
public enum SmbutilParser {
    public struct Share: Hashable, Sendable {
        public let name: String
        public let type: String
        public let comment: String?

        /// Administrative/hidden shares such as `IPC$`, `ADMIN$` or `C$`.
        public var isHidden: Bool { name.hasSuffix("$") }
        public var isDisk: Bool { type.caseInsensitiveCompare("Disk") == .orderedSame }
    }

    private static let rowPattern = try! NSRegularExpression(
        pattern: #"^(.+?)\s+(Disk|Pipe|Printer|Device|Comm)(?:\s+(.*))?$"#,
        options: [.caseInsensitive]
    )

    public static func parse(_ output: String) -> [Share] {
        var shares: [Share] = []
        var inTable = false
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if !inTable {
                if line.hasPrefix("---") { inTable = true }
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasSuffix("shares listed") || trimmed.hasSuffix("share listed") {
                continue
            }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = rowPattern.firstMatch(in: line, range: range),
                  let nameRange = Range(match.range(at: 1), in: line),
                  let typeRange = Range(match.range(at: 2), in: line)
            else { continue }
            var comment: String?
            if let commentRange = Range(match.range(at: 3), in: line) {
                let text = line[commentRange].trimmingCharacters(in: .whitespaces)
                comment = text.isEmpty ? nil : text
            }
            shares.append(Share(
                name: line[nameRange].trimmingCharacters(in: .whitespaces),
                type: String(line[typeRange]),
                comment: comment
            ))
        }
        return shares
    }
}
