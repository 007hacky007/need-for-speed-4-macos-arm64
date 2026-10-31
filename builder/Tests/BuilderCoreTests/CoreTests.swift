import XCTest
@testable import BuilderCore

final class CoreTests: XCTestCase {
    func testBuildBlockedWhileAnyRowRedOrChecking() {
        var s = Dictionary(uniqueKeysWithValues: CheckID.allCases.map { ($0, CheckState.ready("ok")) })
        XCTAssertTrue(canBuild(s))
        s[.downloads] = .automatic("will be downloaded during the build"); XCTAssertTrue(canBuild(s))
        s[.gameCopy] = .checking("checking"); XCTAssertFalse(canBuild(s))
        s[.gameCopy] = .blocked("choose"); XCTAssertFalse(canBuild(s))
        s.removeValue(forKey: .diskSpace); s[.gameCopy] = .ready("ok"); XCTAssertFalse(canBuild(s))
        XCTAssertEqual(CheckID.allCases, [.mac, .commandLineTools, .buildTools, .downloads, .gameCopy, .destination, .diskSpace])
    }

    func testMacCheck() {
        XCTAssertTrue(macCheck(isAppleSilicon: true, version: .init(majorVersion: 12, minorVersion: 0, patchVersion: 0)).isReady)
        XCTAssertEqual(macCheck(isAppleSilicon: false, version: .init(majorVersion: 15, minorVersion: 0, patchVersion: 0)),
                       .blocked("NFSIV Builder needs a Mac with Apple Silicon"))
        XCTAssertEqual(macCheck(isAppleSilicon: true, version: .init(majorVersion: 11, minorVersion: 7, patchVersion: 0)),
                       .blocked("NFSIV Builder needs macOS 12 or newer. On macOS 11, build from Terminal."))
    }

    func testParsePipelineLines() {
        XCTAssertEqual(parsePipelineLine(#"NFSIV-EVENT {"step":"compile","title":"Compiling native ARM64 code"}"#),
                       .step(id: "compile", title: "Compiling native ARM64 code"))
        XCTAssertEqual(parsePipelineLine(#"NFSIV-EVENT {"done":"/tmp/w/out/NFSIV.app"}"#),
                       .done(URL(fileURLWithPath: "/tmp/w/out/NFSIV.app")))
        XCTAssertEqual(parsePipelineLine(#"NFSIV-EVENT {"error":"bad"}"#), .error("bad"))
        XCTAssertEqual(parsePipelineLine(#"NFSIV-EVENT {"error":"no","reason":"assets","detected":{"files":2,"bytes":10,"sha256":"ab"}}"#),
                       .rejected(GameRejection(reason: "assets", message: "no", detected: Inventory(files: 2, bytes: 10, sha256: "ab"))))
        XCTAssertEqual(parsePipelineLine(#"NFSIV-EVENT {"error":"no","reason":"icon"}"#),
                       .rejected(GameRejection(reason: "icon", message: "no", detected: nil)))
        XCTAssertEqual(parsePipelineLine(#"NFSIV-EVENT {"game":"ok","version":"Need for Speed: Road Challenge, European retail CD"}"#),
                       .game(version: "Need for Speed: Road Challenge, European retail CD"))
        XCTAssertEqual(parsePipelineLine(#"NFSIV-EVENT {"game":"ok","version":"x","summary":"European Road Challenge CD, 1,328 files verified"}"#),
                       .game(version: "European Road Challenge CD, 1,328 files verified"))
        XCTAssertEqual(parsePipelineLine(#"NFSIV-EVENT {"tools":"missing"}"#), .tools(python: nil))
        XCTAssertEqual(parsePipelineLine(#"NFSIV-EVENT {"tools":"ready","python":"/c/python-3.12/bin/python"}"#),
                       .tools(python: "/c/python-3.12/bin/python"))
        XCTAssertEqual(parsePipelineLine(#"NFSIV-EVENT {"downloads":"ready"}"#), .downloads(.ready))
        XCTAssertEqual(parsePipelineLine(#"NFSIV-EVENT {"downloads":"missing"}"#), .downloads(.missing))
        XCTAssertEqual(parsePipelineLine(#"NFSIV-EVENT {"downloads":"damaged","file":"MoltenVK-macos-1.2.11.tar"}"#),
                       .downloads(.damaged("MoltenVK-macos-1.2.11.tar")))
        for odd in [#"NFSIV-EVENT {"downloads":"weird"}"#, #"NFSIV-EVENT {"tools":"maybe"}"#, #"NFSIV-EVENT {"step":"x"}"#,
                    #"NFSIV-EVENT [1]"#, "NFSIV-EVENT {broken", #"NFSV-EVENT {"error":"x"}"#, "plain"] {
            XCTAssertEqual(parsePipelineLine(odd), .log(odd))
        }
    }

    /// The real output of `python3 tools/builder_cli.py supported`.
    static let supportedLine = #"NFSIV-EVENT {"supported": {"release": "Need for Speed: Road Challenge, European retail CD", "languages": "English, Spanish and Swedish disc files (0409/040A/041D); the port runs in English", "assets": {"what": "All files under DATA and SAVEDATA, combined", "files": 1328, "bytes": 547813845, "sha256": "73cb89e6dd4ea9ca32d02af2c822b22421cf9815e0c5557a3f6046671ed300d2"}, "icon": {"what": "NFSHS.ICO at the disc root", "bytes": 766, "sha256": "cd07cfab47d414f218838ed1b5b4f18478e0d0e2eda09bbd3fed47e86c5f2d2a"}, "inputs": "A folder with DATA, SAVEDATA and NFSHS.ICO from the disc root; an ISO; a single-track MODE1 BIN/CUE or IMG image; or a CCD with its IMG beside it.", "note": "The checksum is a fingerprint of the extracted files, not of the disc image. Different ISO, BIN or IMG files can hold the same accepted game."}}"#

    func testSupportedEventDecodes() throws {
        guard case let .supported(release) = parsePipelineLine(Self.supportedLine) else { return XCTFail() }
        XCTAssertEqual(release.release, "Need for Speed: Road Challenge, European retail CD")
        XCTAssertEqual(release.assets.files, 1328)
        XCTAssertEqual(release.assets.bytes, 547_813_845)
        XCTAssertNil(release.icon.files)
        XCTAssertEqual(release.icon.bytes, 766)
        let text = release.plainText(detected: Inventory(files: 1327, bytes: 546_100_000, sha256: "abc"))
        XCTAssertTrue(text.contains("All files under DATA and SAVEDATA, combined: 1328 files, 547813845 bytes, SHA-256 73cb89e6"))
        XCTAssertTrue(text.contains("NFSHS.ICO at the disc root: 766 bytes, SHA-256 cd07cfab"))
        XCTAssertTrue(text.contains("Your copy: 1327 files, 546100000 bytes, SHA-256 abc"))
        XCTAssertTrue(text.contains(SupportedRelease.otherRegions))
        XCTAssertFalse(release.plainText(detected: nil).contains("Your copy"))
        let broken = #"NFSIV-EVENT {"supported": {"release": "x"}}"#
        XCTAssertEqual(parsePipelineLine(broken), .log(broken))
    }

    func testRejectionReasonsThatOfferTheSheet() {
        for reason in ["assets", "not-game", "icon-missing", "icon"] {
            XCTAssertTrue(GameRejection(reason: reason, message: "", detected: nil).offersSupportedCopies, reason)
        }
        for reason in ["missing", "link", "unsupported-type", "ccd-image", "cue-image", "image-layout", "unreadable"] {
            XCTAssertFalse(GameRejection(reason: reason, message: "", detected: nil).offersSupportedCopies, reason)
        }
    }

    func testGameCheckDetailsKeepMessageAndDetectedInventory() {
        let log = ["", "Extracting NFS.ccd to check it", "  ",
                   "Failed: This copy does not match.", "Detected: 2 files, 3 bytes, SHA-256 ab; expected 1,328 files, 547,813,845 bytes."]
        XCTAssertEqual(gameCheckDetails(message: "This copy does not match.", log: log), """
            This copy does not match.
            Extracting NFS.ccd to check it
            Failed: This copy does not match.
            Detected: 2 files, 3 bytes, SHA-256 ab; expected 1,328 files, 547,813,845 bytes.
            """)
        XCTAssertEqual(gameCheckDetails(message: "Bad.", log: []), "Bad.")
    }

    func testProgressAndDisk() {
        XCTAssertEqual(buildSteps(community: false).map(\.id),
                       ["extract", "verify", "setup", "dependencies", "prepare", "translate", "compile", "package"])
        XCTAssertEqual(buildSteps(community: true).map(\.id),
                       ["extract", "verify", "setup", "dependencies", "prepare", "community", "translate", "compile", "package"])
        XCTAssertEqual(progressFraction(atStart: "extract", community: false), 0)
        // The community step comes before compiling, so compiling starts later in the bar.
        XCTAssertGreaterThan(progressFraction(atStart: "compile", community: true), progressFraction(atStart: "compile", community: false))
        XCTAssertEqual(progressFraction(atStart: "compile", community: false), 0.21, accuracy: 0.0001)
        XCTAssertEqual(progressFraction(atStart: "package", community: true), 1 - 4.0 / 105, accuracy: 0.0001)
        XCTAssertGreaterThan(progressFraction(atStart: "package", community: false), 0.8)
        XCTAssertEqual(progressFraction(atStart: "unknown", community: false), 1)
        if case .blocked = diskSpaceCheck(available: requiredFreeBytes(community: true) - 1, community: true) {} else { XCTFail() }
        if case .ready = diskSpaceCheck(available: requiredFreeBytes(community: false), community: false) {} else { XCTFail() }
        XCTAssertGreaterThan(requiredFreeBytes(community: true), requiredFreeBytes(community: false))
        XCTAssertEqual(diskSpaceCheck(available: 1_500_000_000, community: false),
                       .blocked("Only 1.5 GB free, \(String(format: "%.1f", Double(requiredFreeBytes(community: false)) / 1e9)) GB needed"))
    }
}
