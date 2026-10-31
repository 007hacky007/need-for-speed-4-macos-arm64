import XCTest
@testable import BuilderCore

final class RecordingRunner: CommandRunning {
    var calls: [String] = []
    let results: [String: (status: Int32, output: String)]
    init(results: [String: (status: Int32, output: String)]) { self.results = results }
    func run(_ executable: String, _ arguments: [String]) -> (status: Int32, output: String) {
        calls.append(([executable] + arguments).joined(separator: " "))
        return results[executable] ?? (127, "")
    }
}

final class EnvironmentTests: XCTestCase {
    private var tmp: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("nfsiv-env-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    private func write(_ text: String, to url: URL) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

    // MARK: - Command line tools

    func testCLTDetectionNeedsMakeLipoAndSDKAndNeverInvokesShims() {
        let dir = "/Library/Developer/CommandLineTools"
        let all: Set<String> = ["\(dir)/usr/bin/clang", "\(dir)/usr/bin/make", "\(dir)/usr/bin/lipo",
                                "\(dir)/SDKs/MacOSX.sdk", "/usr/bin/codesign"]
        let runner = RecordingRunner(results: ["/usr/bin/xcode-select": (0, dir + "\n")])
        XCTAssertTrue(CommandLineTools(runner: runner, fileExists: { all.contains($0) }).state().isReady)
        for missing in all {
            let state = CommandLineTools(runner: runner, fileExists: { all.subtracting([missing]).contains($0) }).state()
            XCTAssertEqual(state, .blocked("Needed to compile the game on your Mac, about 2 GB from Apple"), missing)
        }
        XCTAssertFalse(runner.calls.contains { call in
            call.contains("xcrun") || ["/usr/bin/clang", "/usr/bin/make", "/usr/bin/lipo"].contains { call.hasPrefix($0) }
        })
        XCTAssertTrue(runner.calls.allSatisfy { $0 == "/usr/bin/xcode-select -p" })
        let unset = CommandLineTools(runner: RecordingRunner(results: ["/usr/bin/xcode-select": (2, "")]), fileExists: { _ in true })
        XCTAssertEqual(unset.state(), .blocked("Needed to compile the game on your Mac, about 2 GB from Apple"))
    }

    func testXcodeLayoutIsAccepted() {
        let dir = "/Applications/Xcode.app/Contents/Developer"
        let toolchain = dir + "/Toolchains/XcodeDefault.xctoolchain/usr/bin"
        let files: Set<String> = ["\(toolchain)/clang", "\(toolchain)/lipo", "\(dir)/usr/bin/make",
                                  "\(dir)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk", "/usr/bin/codesign"]
        let runner = RecordingRunner(results: ["/usr/bin/xcode-select": (0, dir + "\n")])
        XCTAssertTrue(CommandLineTools(runner: runner, fileExists: { files.contains($0) }).state().isReady)
        let noSDK = files.subtracting(["\(dir)/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"])
        XCTAssertFalse(CommandLineTools(runner: runner, fileExists: { noSDK.contains($0) }).state().isReady)
    }

    func testThisMacIsDetectedWithoutShims() {
        // The real file checks on the Mac running the tests (which has the tools to build them).
        XCTAssertTrue(CommandLineTools().state().isReady)
    }

    func testStartInstallRunsXcodeSelect() {
        let runner = RecordingRunner(results: [:])
        CommandLineTools(runner: runner, fileExists: { _ in false }).startInstall()
        XCTAssertEqual(runner.calls, ["/usr/bin/xcode-select --install"])
    }

    // MARK: - Paths

    func testBuilderPaths() {
        let paths = BuilderPaths(support: URL(fileURLWithPath: "/s"), cache: URL(fileURLWithPath: "/c"))
        XCTAssertEqual(paths.python.path, "/s/python")
        XCTAssertEqual(paths.pythonExecutable.path, "/s/python/bin/python3")
        XCTAssertEqual(paths.workspace(version: "1.0").path, "/s/1.0")
        XCTAssertEqual(paths.cache.path, "/c")
        let defaults = BuilderPaths(environment: [:])
        XCTAssertTrue(defaults.support.path.hasSuffix("/Library/Application Support/NFSIV Builder"))
        XCTAssertTrue(defaults.cache.path.hasSuffix("/Library/Caches/NFSIV"))
    }

    func testCacheOverrideFromEnvironment() {
        XCTAssertEqual(BuilderPaths(environment: ["NFSIV_BUILDER_CACHE": "/tmp/x"]).cache.path, "/tmp/x")
        XCTAssertEqual(BuilderPaths(environment: ["NFSIV_BUILDER_SUPPORT": "/tmp/s"]).support.path, "/tmp/s")
        XCTAssertTrue(BuilderPaths(environment: ["NFSIV_BUILDER_CACHE": ""]).cache.path.hasSuffix("/Library/Caches/NFSIV"))
    }

    // MARK: - Workspace

    func testStaleOrHalfCopiedWorkspaceIsReplaced() throws {
        let src = tmp.appendingPathComponent("src"), dst = tmp.appendingPathComponent("dst")
        try write("new", to: src.appendingPathComponent("tools/a.py"))
        try write("old", to: dst.appendingPathComponent("tools/a.py"))
        try write("0.9", to: dst.appendingPathComponent(".builder-version"))
        try prepareWorkspace(sources: src, destination: dst, version: "1.0")
        XCTAssertEqual(read(dst.appendingPathComponent("tools/a.py")), "new")
        XCTAssertEqual(read(dst.appendingPathComponent(".builder-version")), "1.0")

        // No marker (crash mid-copy) is also replaced.
        try fm.removeItem(at: dst.appendingPathComponent(".builder-version"))
        try write("junk", to: dst.appendingPathComponent("tools/a.py"))
        try prepareWorkspace(sources: src, destination: dst, version: "1.0")
        XCTAssertEqual(read(dst.appendingPathComponent("tools/a.py")), "new")

        // Same version with marker: nothing is copied.
        try write("kept", to: dst.appendingPathComponent("tools/a.py"))
        try prepareWorkspace(sources: src, destination: dst, version: "1.0")
        XCTAssertEqual(read(dst.appendingPathComponent("tools/a.py")), "kept")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: tmp.path).sorted(), ["dst", "src"])
    }

    func testWorkspaceWithOnlyMarkerIsCopiedAgain() throws {
        let src = tmp.appendingPathComponent("src"), dst = tmp.appendingPathComponent("dst")
        try write("new", to: src.appendingPathComponent("tools/a.py"))
        try write("x", to: src.appendingPathComponent("build.sh"))
        try write("1.0", to: dst.appendingPathComponent(".builder-version"))
        try write("x", to: dst.appendingPathComponent("build.sh"))
        try prepareWorkspace(sources: src, destination: dst, version: "1.0")
        XCTAssertEqual(read(dst.appendingPathComponent("tools/a.py")), "new")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: tmp.path).sorted(), ["dst", "src"])
    }

    func testStartupSweepAndOldVersionCleanup() throws {
        let paths = BuilderPaths(support: tmp, cache: tmp.appendingPathComponent("cache"))
        for name in [".trash-1/tools/a.py", ".1.0.tmp-2/build.sh", ".python.tmp-3/python/bin/python3",
                     "python/bin/python3", "1.0/.builder-version"] {
            try write("x", to: tmp.appendingPathComponent(name))
        }
        sweepLeftovers(paths)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: tmp.path).sorted(), ["1.0", "python"])
        XCTAssertEqual(read(paths.pythonExecutable), "x")

        try write("1.0", to: tmp.appendingPathComponent("1.0/.builder-version"))
        try write("0.9", to: tmp.appendingPathComponent("0.9/.builder-version"))
        try write("x", to: tmp.appendingPathComponent("0.9/tools/a.py"))
        try write("x", to: tmp.appendingPathComponent("notes/a.txt"))
        removeOldWorkspaces(paths, keeping: "1.0")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: tmp.path).sorted(), ["1.0", "notes", "python"])
    }

    func testMoveToTrashRenamesToHiddenSibling() throws {
        let dir = tmp.appendingPathComponent("1.0")
        try write("x", to: dir.appendingPathComponent("tools/a.py"))
        let trash = try moveToTrash(dir)
        XCTAssertFalse(fm.fileExists(atPath: dir.path))
        XCTAssertTrue(trash.lastPathComponent.hasPrefix(".trash-"))
        XCTAssertEqual(trash.deletingLastPathComponent().path, tmp.path)
        XCTAssertEqual(read(trash.appendingPathComponent("tools/a.py")), "x")
    }

    func testWorkspaceCopiesOnlyBundledEntries() throws {
        let src = tmp.appendingPathComponent("repo"), dst = tmp.appendingPathComponent("ws")
        for entry in ["build.sh", "requirements.txt", "tools/a.py", "runtime/r.c", "launcher/l.c",
                      "gen/big.bin", "out/o.bin", ".venv/bin/python", "tools/__pycache__/x.pyc",
                      "runtime/__pycache__/y.pyc", "README.md", "local/build-game/x", "builder/Package.swift"] {
            try write("x", to: src.appendingPathComponent(entry))
        }
        XCTAssertEqual(bundledSourceEntries, ["build.sh", "requirements.txt", "tools", "runtime", "launcher", "third_party"])
        let value = Array("0081;00000000;Test;".utf8)
        let quarantined = src.appendingPathComponent("tools/a.py")
        XCTAssertEqual(setxattr(quarantined.path, "com.apple.quarantine", value, value.count, 0, 0), 0)
        try prepareWorkspace(sources: src, destination: dst, version: "2")
        errno = 0
        XCTAssertEqual(getxattr(dst.appendingPathComponent("tools/a.py").path, "com.apple.quarantine", nil, 0, 0, 0), -1)
        XCTAssertEqual(errno, ENOATTR)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: dst.path).sorted(),
                       [".builder-version", "build.sh", "launcher", "requirements.txt", "runtime", "tools"])
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("tools/__pycache__").path))
        XCTAssertFalse(fm.fileExists(atPath: dst.appendingPathComponent("runtime/__pycache__").path))
    }

    // MARK: - Private Python

    func testPythonPinLooksSane() {
        XCTAssertTrue(PythonRuntime.url.absoluteString.hasPrefix("https://github.com/astral-sh/python-build-standalone/releases/download/"))
        XCTAssertTrue(PythonRuntime.url.absoluteString.hasSuffix("aarch64-apple-darwin-install_only.tar.gz"))
        XCTAssertTrue(PythonRuntime.url.absoluteString.contains("cpython-3.12."))
        XCTAssertEqual(PythonRuntime.sha256.count, 64)
    }

    private func installResult(_ paths: BuilderPaths, sha: String? = nil,
                               download: (URL, @escaping (Result<URL, Error>) -> Void) -> Void) -> Result<Void, Error> {
        var result: Result<Void, Error>?
        let done = expectation(description: "install")
        PythonRuntime.install(paths, sha256: sha ?? PythonRuntime.sha256, download: download) {
            result = $0
            done.fulfill()
        }
        wait(for: [done], timeout: 30)
        return result!
    }

    func testPythonInstallRejectsBadChecksumAndLeavesNothing() throws {
        let support = tmp.appendingPathComponent("support")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let paths = BuilderPaths(support: support, cache: tmp.appendingPathComponent("cache"))
        let bad = tmp.appendingPathComponent("bad.tgz")
        try write("not python", to: bad)
        let result = installResult(paths) { _, done in done(.success(bad)) }
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertTrue(error.localizedDescription.lowercased().contains("checksum"))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: support.path), [])
        XCTAssertFalse(PythonRuntime.isInstalled(paths))
    }

    func testPythonInstallReportsDownloadFailure() throws {
        let support = tmp.appendingPathComponent("support")
        try fm.createDirectory(at: support, withIntermediateDirectories: true)
        let paths = BuilderPaths(support: support, cache: tmp.appendingPathComponent("cache"))
        let result = installResult(paths) { _, done in done(.failure(URLError(.notConnectedToInternet))) }
        guard case .failure(let error) = result else { return XCTFail("expected failure") }
        XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: support.path), [])
    }

    private func pythonArchive(_ marker: String) throws -> URL {
        let stage = tmp.appendingPathComponent("stage-\(marker)")
        let exe = stage.appendingPathComponent("python/bin/python3")
        try write("#!/bin/sh\n# \(marker)\n", to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        let archive = tmp.appendingPathComponent("py-\(marker).tar.gz")
        let tar = SystemCommandRunner().run("/usr/bin/tar", ["-czf", archive.path, "-C", stage.path, "python"])
        XCTAssertEqual(tar.status, 0, tar.output)
        return archive
    }

    func testPythonInstallExtractsVerifiedArchiveAndReplacesOldOne() throws {
        let support = tmp.appendingPathComponent("support")
        let paths = BuilderPaths(support: support, cache: tmp.appendingPathComponent("cache"))
        for marker in ["first", "second"] {
            let archive = try pythonArchive(marker)
            let sha = try sha256Hex(of: archive)
            let result = installResult(paths, sha: sha) { _, done in done(.success(archive)) }
            guard case .success = result else { return XCTFail("\(result)") }
            XCTAssertTrue(fm.isExecutableFile(atPath: paths.pythonExecutable.path))
            XCTAssertTrue(read(paths.pythonExecutable)?.contains(marker) == true)
            XCTAssertEqual(read(paths.python.appendingPathComponent(".nfsiv-python-sha256")), sha)
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: support.path), ["python"])
        }
    }

    private func fakePython(_ paths: BuilderPaths, marker: String?) throws {
        try write("#!/bin/sh\n", to: paths.pythonExecutable)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.pythonExecutable.path)
        if let marker = marker { try write(marker, to: paths.python.appendingPathComponent(".nfsiv-python-sha256")) }
    }

    func testIsInstalledRequiresPinnedMarker() throws {
        let paths = BuilderPaths(support: tmp, cache: tmp.appendingPathComponent("cache"))
        try fakePython(paths, marker: nil)
        XCTAssertFalse(PythonRuntime.isInstalled(paths))
        try fakePython(paths, marker: "oldpin")
        XCTAssertFalse(PythonRuntime.isInstalled(paths))
        try fakePython(paths, marker: PythonRuntime.sha256)
        XCTAssertTrue(PythonRuntime.isInstalled(paths))
    }

    func testBuildToolsStateMessages() {
        XCTAssertEqual(buildToolsState(pythonInstalled: false, tools: nil), .blocked("about 90 MB download"))
        XCTAssertEqual(buildToolsState(pythonInstalled: false, tools: .tools(python: "/c/bin/python")),
                       .blocked("about 90 MB download"))
        XCTAssertEqual(buildToolsState(pythonInstalled: true, tools: .tools(python: "/c/bin/python")), .ready("Installed"))
        let packages = CheckState.blocked("Packages need to be set up again (small download)")
        XCTAssertEqual(buildToolsState(pythonInstalled: true, tools: .tools(python: nil)), packages)
        XCTAssertEqual(buildToolsState(pythonInstalled: true, tools: nil), packages)
    }

    func testInstallCompletionArrivesOnMainThread() throws {
        let paths = BuilderPaths(support: tmp.appendingPathComponent("support"), cache: tmp.appendingPathComponent("cache"))
        let bad = tmp.appendingPathComponent("bad.tgz")
        try write("x", to: bad)
        var onMain: Bool?
        let done = expectation(description: "install")
        PythonRuntime.install(paths, download: { _, finish in
            DispatchQueue.global().async { finish(.success(bad)) }
        }, completion: { _ in
            onMain = Thread.isMainThread
            done.fulfill()
        })
        wait(for: [done], timeout: 30)
        XCTAssertEqual(onMain, true)
    }

    func testRemoveQuarantineRecursive() throws {
        let dir = tmp.appendingPathComponent("q")
        let file = dir.appendingPathComponent("sub/f.txt")
        try write("x", to: file)
        let value = Array("0081;00000000;Test;".utf8)
        for url in [dir, file] {
            XCTAssertEqual(setxattr(url.path, "com.apple.quarantine", value, value.count, 0, 0), 0)
        }
        try removeQuarantine(at: dir)
        for url in [dir, file] {
            errno = 0
            XCTAssertEqual(getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0), -1)
            XCTAssertEqual(errno, ENOATTR)
        }
        try removeQuarantine(at: dir)
    }
}
