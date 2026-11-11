import XCTest
@testable import ShareBuddyCore

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
        XCTAssertTrue(open.isEmpty)
    }
}
