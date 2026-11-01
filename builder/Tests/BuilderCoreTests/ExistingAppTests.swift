import XCTest
@testable import BuilderCore

/// The update path: an existing NFSIV.app is found, its stamp read, and it is only replaced
/// once the new build is complete.
final class ExistingAppTests: XCTestCase {
    var root: URL!
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("nfsiv-existing-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() { try? fm.removeItem(at: root) }

    @discardableResult
    private func makeApp(in folder: URL, stamp: String? = nil, bundleID: String = gameBundleID, marker: String = "old") throws -> URL {
        let app = folder.appendingPathComponent("NFSIV.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources/Game/data"), withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": bundleID]
        if let stamp = stamp { info["NFSBuilderVersion"] = stamp }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try marker.write(to: app.appendingPathComponent("Contents/marker"), atomically: true, encoding: .utf8)
        return app
    }

    private func snapshot(_ folder: URL) throws -> [String: Date] {
        var result: [String: Date] = [:]
        for case let url as URL in fm.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])! {
            result[url.path] = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return result
    }

    func testFindsTheAppInTheSavedDestinationThenApplications() throws {
        let saved = root.appendingPathComponent("Games"), applications = root.appendingPathComponent("Applications")
        try fm.createDirectory(at: saved, withIntermediateDirectories: true)
        try fm.createDirectory(at: applications, withIntermediateDirectories: true)
        XCTAssertNil(existingGameApp(destination: saved, fallback: applications))
        try makeApp(in: applications)
        XCTAssertEqual(existingGameApp(destination: saved, fallback: applications)?.path,
                       applications.appendingPathComponent("NFSIV.app").path)
        try makeApp(in: saved)
        XCTAssertEqual(existingGameApp(destination: saved, fallback: applications)?.path,
                       saved.appendingPathComponent("NFSIV.app").path)
    }

    func testAnUnrelatedAppIsNotOffered() throws {
        let other = root.appendingPathComponent("Other")
        try makeApp(in: other, bundleID: "com.example.other")
        XCTAssertNil(existingGameApp(destination: other, fallback: root.appendingPathComponent("none")))
    }

    func testButtonNamesTheOldAndNewVersion() throws {
        let stamped = try makeApp(in: root.appendingPathComponent("A"), stamp: "0.1.0")
        let terminal = try makeApp(in: root.appendingPathComponent("B"))
        XCTAssertEqual(builderStamp(of: stamped), "0.1.0")
        XCTAssertNil(builderStamp(of: terminal))
        XCTAssertTrue(isAppBundle(stamped))
        XCTAssertEqual(buildButtonTitle(source: stamped, builderVersion: "0.2.0"), "Update NFSIV.app (0.1.0 -> 0.2.0)")
        XCTAssertEqual(buildButtonTitle(source: terminal, builderVersion: "0.2.0"), "Update NFSIV.app")
        XCTAssertEqual(buildButtonTitle(source: root.appendingPathComponent("game.iso"), builderVersion: "0.2.0"), "Build NFSIV.app")
        XCTAssertEqual(buildButtonTitle(source: nil, builderVersion: "0.2.0"), "Build NFSIV.app")
    }

    func testAnUpdateKeepsTheOldAppUntilTheNewOneIsComplete() throws {
        let destination = root.appendingPathComponent("Applications")
        let old = try makeApp(in: destination, stamp: "0.1.0")
        let before = try snapshot(old)
        // A failed install (the new build is missing) leaves the old app exactly as it was.
        XCTAssertThrowsError(try installApp(root.appendingPathComponent("missing/NFSIV.app"), into: destination, isRunning: { false }))
        XCTAssertEqual(try snapshot(old), before)
        // While the old app is running it is not replaced.
        let built = try makeApp(in: root.appendingPathComponent("built"), stamp: "0.2.0", marker: "new")
        XCTAssertThrowsError(try installApp(built, into: destination, isRunning: { true }))
        XCTAssertEqual(try snapshot(old), before)
        // Only a complete build replaces it.
        let installed = try installApp(built, into: destination, isRunning: { false })
        XCTAssertEqual(builderStamp(of: installed), "0.2.0")
        XCTAssertEqual(try String(contentsOf: installed.appendingPathComponent("Contents/marker"), encoding: .utf8), "new")
    }
}
