import XCTest
@testable import BuilderCore

final class DestinationTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("nfsiv-dest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent("dest").path)
        try? FileManager.default.removeItem(at: root)
    }

    private func makeApp(at url: URL, marker: String, bundleID: String = gameBundleID) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleID], format: .xml, options: 0)
        try plist.write(to: url.appendingPathComponent("Contents/Info.plist"))
        try marker.write(to: url.appendingPathComponent("Contents/marker"), atomically: true, encoding: .utf8)
    }

    private func marker(_ app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8)
    }

    private var dest: URL { root.appendingPathComponent("dest") }
    private var built: URL { root.appendingPathComponent("built/NFSIV.app") }

    func testInstallReplacesExistingApp() throws {
        try makeApp(at: dest.appendingPathComponent("NFSIV.app"), marker: "old")
        try makeApp(at: built, marker: "new")
        XCTAssertTrue(destinationCheck(dest).isReady)
        let result = try installApp(built, into: dest, isRunning: { false })
        XCTAssertEqual(result.lastPathComponent, "NFSIV.app")
        XCTAssertEqual(try marker(result), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent(".NFSIV.app.installing").path))
    }

    func testFreshInstallAndStaleStagingCleaned() throws {
        try makeApp(at: dest.appendingPathComponent(".NFSIV.app.installing"), marker: "stale")
        try makeApp(at: built, marker: "new")
        let result = try installApp(built, into: dest, isRunning: { false })
        XCTAssertEqual(try marker(result), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent(".NFSIV.app.installing").path))
    }

    func testRunningGameIsNotReplaced() throws {
        try makeApp(at: dest.appendingPathComponent("NFSIV.app"), marker: "old")
        try makeApp(at: built, marker: "new")
        XCTAssertThrowsError(try installApp(built, into: dest, isRunning: { true })) { error in
            XCTAssertEqual(error.localizedDescription, "Quit NFSIV first, then try again.")
        }
        XCTAssertEqual(try marker(dest.appendingPathComponent("NFSIV.app")), "old")
    }

    func testFailedCopyKeepsOldApp() throws {
        try makeApp(at: dest.appendingPathComponent("NFSIV.app"), marker: "old")
        let missing = root.appendingPathComponent("nope/NFSIV.app")
        XCTAssertThrowsError(try installApp(missing, into: dest, isRunning: { false }))
        XCTAssertEqual(try marker(dest.appendingPathComponent("NFSIV.app")), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent(".NFSIV.app.installing").path))
    }

    func testStagingFailureGivesPlainErrorAndKeepsOldApp() throws {
        try makeApp(at: dest.appendingPathComponent("NFSIV.app"), marker: "old")
        try makeApp(at: built, marker: "new")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dest.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path) }
        XCTAssertThrowsError(try installApp(built, into: dest, isRunning: { false })) { error in
            XCTAssertEqual(error.localizedDescription, "Could not install NFSIV into dest. Choose another folder and try again.")
        }
        XCTAssertEqual(try marker(dest.appendingPathComponent("NFSIV.app")), "old")
    }

    func testUnrelatedAppIsNeverReplaced() throws {
        let message = "This folder has an NFSIV.app that was not built from your game copy. Choose another folder."
        for id in ["com.example.other", ""] {
            try? FileManager.default.removeItem(at: dest)
            try makeApp(at: dest.appendingPathComponent("NFSIV.app"), marker: "theirs", bundleID: id)
            try makeApp(at: built, marker: "new")
            XCTAssertEqual(destinationCheck(dest), .blocked(message))
            XCTAssertThrowsError(try installApp(built, into: dest, isRunning: { false })) { error in
                XCTAssertEqual(error.localizedDescription, message)
            }
            XCTAssertEqual(try marker(dest.appendingPathComponent("NFSIV.app")), "theirs")
        }
        // An app folder without a readable Info.plist is not ours either.
        try FileManager.default.removeItem(at: dest.appendingPathComponent("NFSIV.app/Contents/Info.plist"))
        XCTAssertEqual(destinationCheck(dest), .blocked(message))
    }

    func testUnwritableDestinationIsRed() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        XCTAssertEqual(destinationCheck(root), .blocked("Choose a folder you can write to"))
    }

    func testMissingDestinationIsRedAndWritableIsReady() {
        XCTAssertEqual(destinationCheck(root.appendingPathComponent("missing")), .blocked("Choose a folder you can write to"))
        XCTAssertTrue(destinationCheck(root).isReady)
    }

    func testGameBundleIDMatchesPackager() throws {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" && !FileManager.default.fileExists(atPath: url.appendingPathComponent("tools/package.py").path) {
            url.deleteLastPathComponent()
        }
        let packager = try String(contentsOf: url.appendingPathComponent("tools/package.py"), encoding: .utf8)
        XCTAssertTrue(packager.contains("'CFBundleIdentifier': '\(gameBundleID)'"))
    }
}
