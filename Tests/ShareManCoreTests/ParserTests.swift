import XCTest
@testable import ShareManCore

final class ShowmountParserTests: XCTestCase {
    func testParsesExportsAndClients() {
        let output = """
        Exports list on 192.168.1.10:
        /volume1/media                     192.168.1.0/24
        /volume1/backup                    Everyone
        /srv/nfs/home                      10.0.0.2 10.0.0.3
        """
        let exports = ShowmountParser.parse(output)
        XCTAssertEqual(exports.map(\.path), ["/volume1/media", "/volume1/backup", "/srv/nfs/home"])
        XCTAssertEqual(exports[0].clients, ["192.168.1.0/24"])
        XCTAssertEqual(exports[1].clients, ["Everyone"])
        XCTAssertEqual(exports[2].clients, ["10.0.0.2", "10.0.0.3"])
    }

    func testEmptyListGivesNoExports() {
        XCTAssertTrue(ShowmountParser.parse("Exports list on nas:\n").isEmpty)
    }
}

final class SmbutilParserTests: XCTestCase {
    let output = """
    Share                                           Type    Comments
    -------------------------------
    Public                                          Disk
    Time Machine                                    Disk    Sauvegardes du Mac
    photo                                           Disk    System default shared folder
    IPC$                                            Pipe    IPC Service (Samba 4.15.13)
    ADMIN$                                          Disk

    5 shares listed
    """

    func testParsesNamesTypesAndComments() {
        let shares = SmbutilParser.parse(output)
        XCTAssertEqual(shares.map(\.name), ["Public", "Time Machine", "photo", "IPC$", "ADMIN$"])
        XCTAssertEqual(shares[0].comment, nil)
        XCTAssertEqual(shares[1].comment, "Sauvegardes du Mac")
        XCTAssertEqual(shares[3].type, "Pipe")
    }

    func testHiddenAndDiskFlags() {
        let shares = SmbutilParser.parse(output)
        let visibleDisks = shares.filter { $0.isDisk && !$0.isHidden }.map(\.name)
        XCTAssertEqual(visibleDisks, ["Public", "Time Machine", "photo"])
    }
}

final class ShareURLTests: XCTestCase {
    func testBuildsNFSURLWithEncodedPath() {
        let url = ShareURL.make(kind: .nfs, host: "nas.local", path: "/volume1/Mes films")
        XCTAssertEqual(url?.absoluteString, "nfs://nas.local/volume1/Mes%20films")
    }

    func testBuildsSMBURLWithUser() {
        let url = ShareURL.make(kind: .smb, host: "192.168.1.10", path: "Time Machine", user: "bob")
        XCTAssertEqual(url?.absoluteString, "smb://bob@192.168.1.10/Time%20Machine")
    }

    func testParsesClassicNFSNotation() throws {
        XCTAssertEqual(try ShareURL.parse("nas:/volume1/media").absoluteString, "nfs://nas/volume1/media")
        XCTAssertEqual(try ShareURL.parse("192.168.1.10:/srv/nfs").absoluteString, "nfs://192.168.1.10/srv/nfs")
    }

    func testParsesClassicSMBNotation() throws {
        XCTAssertEqual(try ShareURL.parse("//nas/Public").absoluteString, "smb://nas/Public")
        XCTAssertEqual(try ShareURL.parse("//bob@nas/Public").absoluteString, "smb://bob@nas/Public")
    }

    func testParsesURLsAndNormalisesCIFS() throws {
        XCTAssertEqual(try ShareURL.parse("nfs://nas/volume1/media").absoluteString, "nfs://nas/volume1/media")
        XCTAssertEqual(try ShareURL.parse("cifs://nas/Public").absoluteString, "smb://nas/Public")
        XCTAssertEqual(try ShareURL.parse("smb://nas/Time%20Machine").absoluteString, "smb://nas/Time%20Machine")
    }

    func testExplicitUserOverridesEmbeddedUser() throws {
        XCTAssertEqual(try ShareURL.parse("smb://alice@nas/Public", user: "bob").absoluteString, "smb://bob@nas/Public")
    }

    func testRejectsInvalidTargets() {
        XCTAssertThrowsError(try ShareURL.parse(""))
        XCTAssertThrowsError(try ShareURL.parse("nas"))
        XCTAssertThrowsError(try ShareURL.parse("ftp://nas/files"))
        XCTAssertThrowsError(try ShareURL.parse("smb://nas"))
        XCTAssertThrowsError(try ShareURL.parse("smb://nas/"))
    }
}

final class IPv4SubnetTests: XCTestCase {
    func testParsesAndFormats() {
        let subnet = IPv4Subnet(cidr: "192.168.1.37/24")
        XCTAssertNotNil(subnet)
        XCTAssertEqual(subnet?.description, "192.168.1.0/24")
        XCTAssertEqual(IPv4Subnet.format(subnet!.broadcast), "192.168.1.255")
        XCTAssertNil(IPv4Subnet(cidr: "192.168.1.300/24"))
        XCTAssertNil(IPv4Subnet(cidr: "192.168.1.0/33"))
        XCTAssertNil(IPv4Subnet(cidr: "nas.local"))
    }

    func testHostAddressesOfA24() {
        let hosts = IPv4Subnet(cidr: "10.0.0.5/24")!.hostAddresses()
        XCTAssertEqual(hosts.count, 254)
        XCTAssertEqual(IPv4Subnet.format(hosts.first!), "10.0.0.1")
        XCTAssertEqual(IPv4Subnet.format(hosts.last!), "10.0.0.254")
    }

    func testLargeSubnetIsNarrowedAroundOwnAddress() {
        let hosts = IPv4Subnet(cidr: "172.16.42.7/16")!.hostAddresses(maxPrefix: 24)
        XCTAssertEqual(hosts.count, 254)
        XCTAssertEqual(IPv4Subnet.format(hosts.first!), "172.16.42.1")
    }

    func testSingleAddress() {
        let hosts = IPv4Subnet(cidr: "192.168.1.10")!.hostAddresses()
        XCTAssertEqual(hosts.map(IPv4Subnet.format), ["192.168.1.10"])
    }
}

final class ScannerMergeTests: XCTestCase {
    func testMergesSameAddressAndPutsNFSFirst() {
        let merged = NetworkScanner.merge([
            DiscoveredServer(address: "192.168.1.20", protocols: [.smb], sources: [.portScan]),
            DiscoveredServer(address: "192.168.1.10", bonjourName: "DiskStation", protocols: [.smb], sources: [.bonjour]),
            DiscoveredServer(address: "192.168.1.10", protocols: [.nfs], sources: [.portScan]),
            DiscoveredServer(address: "192.168.1.9", protocols: [.smb], sources: [.portScan]),
        ])
        XCTAssertEqual(merged.map(\.address), ["192.168.1.10", "192.168.1.9", "192.168.1.20"])
        XCTAssertEqual(merged[0].protocols, [.nfs, .smb])
        XCTAssertEqual(merged[0].sources, [.bonjour, .portScan])
        XCTAssertEqual(merged[0].displayName, "DiskStation")
    }
}

final class MountedShareTests: XCTestCase {
    func testExtractsServer() {
        XCTAssertEqual(MountedShare(kind: .nfs, source: "nas:/volume1/media", mountPoint: "/Volumes/media").server, "nas")
        XCTAssertEqual(MountedShare(kind: .smb, source: "//bob@nas._smb._tcp.local/Public", mountPoint: "/Volumes/Public").server, "nas._smb._tcp.local")
        XCTAssertEqual(MountedShares.kind(forFileSystemType: "smbfs"), .smb)
        XCTAssertNil(MountedShares.kind(forFileSystemType: "apfs"))
    }
}

final class PortScannerTests: XCTestCase {
    func testClosedLocalPortIsNotReported() {
        // Port 1 on loopback is closed on any normal machine: the connection is refused at once.
        let open = PortScanner.scanSync(hosts: [IPv4Subnet.parseAddress("127.0.0.1")!], ports: [1], timeout: 0.5)
        XCTAssertTrue(open.open.isEmpty)
    }
}

final class RPCPortmapperTests: XCTestCase {
    func testGetPortCallEncoding() {
        let call = RPCPortmapper.getPortCall(xid: 0x0102_0304, program: 100_003, version: 3, transport: 6)
        XCTAssertEqual(call.count, 56)
        XCTAssertEqual(Array(call[0..<4]), [1, 2, 3, 4])
        // Portmapper program 100000 = 0x000186A0, procedure 3.
        XCTAssertEqual(Array(call[12..<16]), [0x00, 0x01, 0x86, 0xA0])
        XCTAssertEqual(Array(call[20..<24]), [0, 0, 0, 3])
        // Asked program 100003 = 0x000186A3, version 3, TCP.
        XCTAssertEqual(Array(call[40..<44]), [0x00, 0x01, 0x86, 0xA3])
        XCTAssertEqual(Array(call[44..<48]), [0, 0, 0, 3])
        XCTAssertEqual(Array(call[48..<52]), [0, 0, 0, 6])
    }

    private func words(_ values: [UInt32]) -> [UInt8] {
        values.flatMap { [UInt8($0 >> 24 & 0xFF), UInt8($0 >> 16 & 0xFF), UInt8($0 >> 8 & 0xFF), UInt8($0 & 0xFF)] }
    }

    func testParsesSuccessfulReply() {
        // xid, REPLY, MSG_ACCEPTED, verifier AUTH_NONE len 0, SUCCESS, port 2049
        let reply = words([42, 1, 0, 0, 0, 0, 2049])
        let parsed = RPCPortmapper.parseGetPortReply(reply)
        XCTAssertEqual(parsed?.xid, 42)
        XCTAssertEqual(parsed?.port, 2049)
    }

    func testParsesReplyWithVerifierBody() {
        // Verifier of 5 bytes is padded to 8.
        let reply = words([7, 1, 0, 1, 5, 0, 0, 0, 2049])
        XCTAssertEqual(RPCPortmapper.parseGetPortReply(reply)?.port, 2049)
    }

    func testRejectsDeniedOrTruncatedReplies() {
        XCTAssertNil(RPCPortmapper.parseGetPortReply(words([1, 1, 1, 0, 0])))      // MSG_DENIED
        XCTAssertNil(RPCPortmapper.parseGetPortReply(words([1, 0, 0, 0, 0, 0, 0]))) // a CALL, not a REPLY
        XCTAssertNil(RPCPortmapper.parseGetPortReply(words([1, 1, 0, 0, 0, 1, 0]))) // PROG_UNAVAIL
        XCTAssertNil(RPCPortmapper.parseGetPortReply([0, 0, 0]))
    }
}

final class ScanOptionsTests: XCTestCase {
    func testDeepScanWidensSubnetsAndTimeouts() {
        var options = ScanOptions()
        options.subnets = [IPv4Subnet(cidr: "192.168.138.20/23")!, IPv4Subnet(cidr: "10.1.2.3/16")!]
        XCTAssertEqual(NetworkScanner.subnetsToScan(options).map(\.description), ["192.168.138.0/23", "10.1.0.0/22"])
        options.deepNFS = true
        XCTAssertEqual(NetworkScanner.subnetsToScan(options).map(\.description), ["192.168.138.0/23", "10.1.0.0/20"])
        XCTAssertGreaterThanOrEqual(options.effectiveTimeout, 1.5)
    }

    func testBlockedLocallyDetection() {
        var result = PortScanner.Result()
        result.probeCount = 4
        result.immediateFailures = [EHOSTUNREACH: 4]
        XCTAssertTrue(result.looksBlockedLocally)
        result.probeCount = 254
        result.immediateFailures = [EHOSTUNREACH: 252]
        XCTAssertTrue(result.looksBlockedLocally)
        result.immediateFailures = [EHOSTUNREACH: 120]
        XCTAssertFalse(result.looksBlockedLocally)
        result.immediateFailures = [EHOSTUNREACH: 252]
        result.open = [1: [2049]]
        XCTAssertFalse(result.looksBlockedLocally)
    }
}

final class FinderFavoritesPathTests: XCTestCase {
    func testNormalizedPathDropsTrailingSlashAndDots() {
        XCTAssertEqual(FinderFavorites.normalizedPath("/Volumes/media/"), "/Volumes/media")
        XCTAssertEqual(FinderFavorites.normalizedPath("/Volumes/./media//"), "/Volumes/media")
        XCTAssertEqual(FinderFavorites.normalizedPath("/"), "/")
    }

    func testNormalizedPathExpandsTilde() {
        XCTAssertEqual(FinderFavorites.normalizedPath("~"), FinderFavorites.normalizedPath(NSHomeDirectory()))
    }
}
