import XCTest
import BuilderCore

/// Drives the same BuilderCore calls as the Builder window against a real game copy.
///
/// Skipped unless NFSIV_E2E_GAME points at a game folder or a .iso/.bin/.img/.cue/.ccd image.
/// Everything happens in a new temporary folder: the input is cloned there (APFS clone, so the
/// original is only read), and the support folder, cache and destination live there too.
/// It downloads the private Python and the packages, so it needs the network.
///
/// - NFSIV_E2E_SEED_CACHE: a folder holding already downloaded pinned archives. Only those
///   archive names are COPIED into the temporary cache; the pipeline never sees the seed folder.
/// - NFSIV_E2E_COMMUNITY=1: build with the community option.
/// - NFSIV_E2E_SOURCES: an assembled app's Contents/Resources/BuildSources instead of the repo.
/// - NFSIV_E2E_KEEP=1: keep the temporary folder (prints its path) for a look at the window.
final class EndToEndTests: XCTestCase {
    private let fm = FileManager.default
    private let version = "0.0.0-e2e"
    private static let pinnedArchives = ["nfs4_modern_patch.7z", "MoltenVK-macos-1.2.11.tar", "glslang-14.3.0.tar.gz",
                                         "7z2605-mac.tar.xz", "hsfull.rar"]

    func testFullBuildFromWindowCalls() throws {
        let env = ProcessInfo.processInfo.environment
        guard let gamePath = env["NFSIV_E2E_GAME"] else {
            throw XCTSkip("set NFSIV_E2E_GAME to run the end-to-end build")
        }
        let community = env["NFSIV_E2E_COMMUNITY"] == "1"
        let original = URL(fileURLWithPath: gamePath)
        let tmp = fm.temporaryDirectory.appendingPathComponent("nfsiv-e2e-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer {
            if env["NFSIV_E2E_KEEP"] == "1" { print("E2E kept \(tmp.path)") } else { try? fm.removeItem(at: tmp) }
        }
        let started = Date()
        func mark(_ what: String) { print("E2E \(String(format: "%7.1f", Date().timeIntervalSince(started))) s: \(what)") }

        // 1. Clone the input under a hostile name; remember what the original looks like.
        let before = try snapshot(companions(of: original))
        let game = try cloneInput(original, into: tmp.appendingPathComponent("input with spaces"))
        let inputFolder = game.hasDirectoryPath ? game : game.deletingLastPathComponent()
        let inputBefore = try snapshot(listing(inputFolder))
        mark("input cloned to \(game.path)")

        // 2. Temporary cache, seeded by copying only pinned archive names.
        let paths = BuilderPaths(support: tmp.appendingPathComponent("support"), cache: tmp.appendingPathComponent("cache"))
        try fm.createDirectory(at: paths.cache, withIntermediateDirectories: true)
        if let seed = env["NFSIV_E2E_SEED_CACHE"] {
            for name in Self.pinnedArchives where fm.fileExists(atPath: seed + "/" + name) {
                let copy = SystemCommandRunner().run("/bin/cp", ["-c", seed + "/" + name, paths.cache.appendingPathComponent(name).path])
                XCTAssertEqual(copy.status, 0, copy.output)
            }
            mark("seeded cache: \(try fm.contentsOfDirectory(atPath: paths.cache.path).sorted())")
        }
        XCTAssertFalse(PipelineRunner.pipelineEnvironment().keys.contains { $0.hasPrefix("NFSIV") })

        let sources = try env["NFSIV_E2E_SOURCES"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) } ?? repositoryRoot()
        try prepareWorkspace(sources: sources, destination: paths.workspace(version: version), version: version)
        mark("workspace prepared from \(sources.path)")

        // 3. Private Python, packages, tools status, supported release and game checks.
        var pythonArchiveBytes: Int64 = 0
        let installed = expectation(description: "python")
        var installResult: Result<Void, Error>?
        PythonRuntime.install(paths, download: { url, done in
            URLSession.shared.downloadTask(with: url) { file, response, error in
                if let file = file, (response as? HTTPURLResponse)?.statusCode == 200 {
                    pythonArchiveBytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? 0
                    done(.success(file))
                } else {
                    done(.failure(error ?? URLError(.badServerResponse)))
                }
            }.resume()
        }, completion: { result in
            installResult = result
            installed.fulfill()
        })
        wait(for: [installed], timeout: 900)
        try XCTUnwrap(installResult).get()
        XCTAssertTrue(PythonRuntime.isInstalled(paths))
        mark("python installed (\(pythonArchiveBytes) bytes downloaded)")

        let setup = try run(.setup(paths: paths, version: version), timeout: 900)
        XCTAssertEqual(setup.status, 0, setup.lines.suffix(30).joined(separator: "\n"))
        let tools = try run(.toolsStatus(paths: paths, version: version), timeout: 60)
        let toolsEvent = tools.events.first { if case .tools = $0 { return true } else { return false } }
        XCTAssertEqual(buildToolsState(pythonInstalled: true, tools: toolsEvent), .ready("Installed"))
        mark("setup done, pip cache \(Self.kilobytes(paths.cache.appendingPathComponent("pip")) / 1024) MB")

        let supported = try run(.supported(paths: paths, version: version), timeout: 60)
        let release = supported.events.compactMap { event -> SupportedRelease? in
            if case let .supported(value) = event { return value }
            return nil
        }.first
        XCTAssertEqual(release?.assets.files, 1328)

        let check = try run(.checkGame(paths: paths, version: version, game: game), timeout: 900)
        XCTAssertEqual(check.status, 0, check.lines.suffix(30).joined(separator: "\n"))
        XCTAssertEqual(check.events.filter { if case .game = $0 { return true } else { return false } }.count, 1)
        mark("game checked")

        let wrong = tmp.appendingPathComponent("wrong copy")
        for (name, text) in [("DATA/x", "x"), ("SAVEDATA/.keep", ""), ("NFSHS.ICO", "icon")] {
            try fm.createDirectory(at: wrong.appendingPathComponent(name).deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: wrong.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try fm.removeItem(at: wrong.appendingPathComponent("SAVEDATA/.keep"))
        let refused = try run(.checkGame(paths: paths, version: version, game: wrong), timeout: 120)
        XCTAssertEqual(refused.status, 1)
        let rejection = refused.events.compactMap { event -> GameRejection? in
            if case let .rejected(value) = event { return value }
            return nil
        }.first
        XCTAssertEqual(rejection?.reason, "assets")
        XCTAssertEqual(rejection?.detected?.files, 1)
        XCTAssertEqual(rejection?.offersSupportedCopies, true)

        let downloads = try run(.downloadsStatus(paths: paths, version: version, community: community), timeout: 120)
        mark("downloads status: \(downloads.events.filter { if case .downloads = $0 { return true } else { return false } })")

        // 4. A build cancelled once compiling has started: nothing from it may survive.
        let workspace = paths.workspace(version: version).path
        var group: pid_t = 0
        var compilerSeen = false
        let cancelled = try run(.build(paths: paths, version: version, game: game, community: false), timeout: 3600) { event, runner in
            guard case .step(id: "compile", _) = event else { return }
            group = Self.processGroup(matching: { $0.contains(workspace) && $0.contains("build_app.py") }) ?? 0
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline && !compilerSeen {
                compilerSeen = Self.processes(inGroup: group).contains { $0.contains("clang") }
                if !compilerSeen { usleep(200_000) }
            }
            mark("compile started (group \(group), clang running: \(compilerSeen)), cancelling")
            runner.cancel()
        }
        mark("cancelled build exited with \(cancelled.status)")
        XCTAssertNotEqual(group, 0, "found the build's process group")
        XCTAssertTrue(compilerSeen, "clang was running when the build was cancelled")
        XCTAssertNotEqual(cancelled.status, 0)
        let deadline = Date().addingTimeInterval(6)
        var leftovers: [String] = []
        repeat {
            leftovers = Self.ps().filter { $0.pgid == group }.map(\.command)
                .filter { ["build_app.py", "prepare.py", "compile.py", "clang", "cmake", "7zz", "make"].contains(where: $0.contains) }
            if leftovers.isEmpty { break }
            usleep(100_000)
        } while Date() < deadline
        XCTAssertEqual(leftovers, [], "processes from the cancelled build survived")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: paths.cache.path).filter { $0.hasPrefix(".build-") }, [])
        XCTAssertEqual(try buildGameTrees(workspace), [], "the cancelled build's prepared game was discarded")
        mark("nothing left from the cancelled build")

        // 5. The full build, timed per step, with the peak disk use sampled every 5 s.
        let sampler = DiskSampler(folders: [paths.support, paths.cache, tmp.appendingPathComponent("Applications")])
        sampler.start()
        var stepTimes: [(String, Date)] = []
        let full = try run(.build(paths: paths, version: version, game: game, community: community), timeout: 7200) { event, _ in
            if case let .step(id, _) = event { stepTimes.append((id, Date())) }
        }
        let finished = Date()
        XCTAssertEqual(full.status, 0, full.lines.suffix(40).joined(separator: "\n"))
        XCTAssertFalse(full.events.contains { if case .error = $0 { return true } else { return false } })
        let built = try XCTUnwrap(full.events.compactMap { event -> URL? in
            if case let .done(url) = event { return url }
            return nil
        }.first)
        XCTAssertEqual(stepTimes.map(\.0), buildSteps(community: community).map(\.id))
        for (index, (id, start)) in stepTimes.enumerated() {
            let end = index + 1 < stepTimes.count ? stepTimes[index + 1].1 : finished
            print("E2E step \(id): \(String(format: "%.1f", end.timeIntervalSince(start))) s")
        }

        let destination = tmp.appendingPathComponent("Applications")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let app = try installApp(built, into: destination, isRunning: { false })
        let peak = sampler.stop()
        print("E2E peak disk use of support + cache + destination: \(peak / 1024) MB (community: \(community))")
        print("E2E app size: \(Self.kilobytes(app) / 1024) MB")
        XCTAssertEqual(app.lastPathComponent, "NFSIV.app")
        errno = 0
        XCTAssertEqual(getxattr(app.path, "com.apple.quarantine", nil, 0, 0, 0), -1, "installed app is quarantined")
        let verify = SystemCommandRunner().run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        XCTAssertEqual(verify.status, 0, verify.output)
        mark("installed and codesign verified: \(app.path)")

        // The launcher only creates ~/Library/Application Support/NFSIV/Logs; start it only
        // when that folder already exists, so the test never creates anything there.
        let logs = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/NFSIV/Logs")
        if fm.fileExists(atPath: logs.path) {
            let opened = SystemCommandRunner().run("/usr/bin/open", ["-n", "-g", app.path])
            XCTAssertEqual(opened.status, 0, opened.output)
            let launcher = app.appendingPathComponent("Contents/MacOS/NFSIVLauncher").path
            var pid: pid_t?
            let until = Date().addingTimeInterval(20)
            while pid == nil && Date() < until {
                pid = Self.ps().first { $0.command.hasPrefix(launcher) }?.pid
                if pid == nil { usleep(200_000) }
            }
            XCTAssertNotNil(pid, "NFSIVLauncher started")
            if let pid = pid { kill(pid, SIGTERM) }
            mark("launcher started and stopped")
        } else {
            mark("launcher smoke check skipped: \(logs.path) does not exist")
        }

        // 6. The user's input was only read; this run's intermediates were discarded.
        XCTAssertEqual(try snapshot(companions(of: original)), before, "the original input changed")
        XCTAssertEqual(try snapshot(listing(inputFolder)), inputBefore, "the cloned input folder changed")
        XCTAssertEqual(try buildGameTrees(workspace), [])
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: paths.cache.path).filter { $0.hasPrefix("addons-") || $0.hasPrefix(".build-") }, [])
        mark("input unchanged and intermediates discarded; cache: \(try fm.contentsOfDirectory(atPath: paths.cache.path).sorted())")
    }

    // MARK: - Input handling

    /// The input and its same-named image companions (.ccd/.img/.cue/.bin/.sub), or the folder itself.
    private func companions(of input: URL) throws -> [URL] {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: input.path, isDirectory: &isDir) else { throw XCTSkip("NFSIV_E2E_GAME does not exist") }
        if isDir.boolValue { return try listing(input) }
        let stem = input.deletingPathExtension().lastPathComponent
        return try fm.contentsOfDirectory(at: input.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.deletingPathExtension().lastPathComponent == stem
                && ["ccd", "img", "cue", "bin", "sub", "iso"].contains($0.pathExtension.lowercased()) }
    }

    /// Clones the input with APFS clonefile. A CCD/IMG pair gets a name with a leading dash,
    /// quotes and parentheses; other inputs keep their names (a CUE names its BIN inside).
    private func cloneInput(_ input: URL, into folder: URL) throws -> URL {
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        var isDir: ObjCBool = false
        _ = fm.fileExists(atPath: input.path, isDirectory: &isDir)
        if isDir.boolValue {
            let target = folder.appendingPathComponent("NFS Road Challenge (EU) \"copy\"", isDirectory: true)
            let copy = SystemCommandRunner().run("/bin/cp", ["-cR", input.path, target.path])
            XCTAssertEqual(copy.status, 0, copy.output)
            return target
        }
        let rename = input.pathExtension.lowercased() == "ccd"
        let stem = rename ? "-NFS Road Challenge (EU) \"copy\"" : input.deletingPathExtension().lastPathComponent
        var result = input
        for file in try companions(of: input) where file.pathExtension.lowercased() != "sub" {
            let target = folder.appendingPathComponent(stem).appendingPathExtension(file.pathExtension)
            let copy = SystemCommandRunner().run("/bin/cp", ["-c", file.path, target.path])
            XCTAssertEqual(copy.status, 0, copy.output)
            if file == input { result = target }
        }
        return result
    }

    private func listing(_ folder: URL) throws -> [URL] {
        guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return walker.compactMap { $0 as? URL }
    }

    /// Name, size, modification time and (for small files) SHA-256 of each file, sorted.
    private func snapshot(_ files: [URL]) throws -> [String] {
        try files.map { url in
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
            var line = "\(url.path) \(values.fileSize ?? -1) \(values.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            if values.isDirectory != true, (values.fileSize ?? 0) < 1_000_000 {
                line += " " + SystemCommandRunner().run("/usr/bin/shasum", ["-a", "256", url.path]).output.prefix(64)
            }
            return line
        }.sorted()
    }

    private func buildGameTrees(_ workspace: String) throws -> [String] {
        let parent = workspace + "/local/build-game"
        guard fm.fileExists(atPath: parent) else { return [] }
        return try fm.contentsOfDirectory(atPath: parent).filter { $0.hasPrefix("game-") }
    }

    // MARK: - Running

    private struct Run {
        var events: [PipelineEvent] = []
        var lines: [String] = []
        var status: Int32 = -1
    }

    private func run(_ runner: PipelineRunner, timeout: TimeInterval,
                     onEvent: ((PipelineEvent, PipelineRunner) -> Void)? = nil) throws -> Run {
        var result = Run()
        let exited = expectation(description: "exit")
        try runner.start(onEvent: { event in
            result.events.append(event)
            switch event {
            case let .log(line): result.lines.append(line)
            case let .step(_, title): result.lines.append(title)
            case let .error(message): result.lines.append("Error: \(message)")
            case let .rejected(rejection): result.lines.append("Rejected: \(rejection.message)")
            default: break
            }
            onEvent?(event, runner)
        }, onExit: { status in
            result.status = status
            exited.fulfill()
        })
        wait(for: [exited], timeout: timeout)
        return result
    }

    private func repositoryRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.path != "/" {
            url.deleteLastPathComponent()
            if fm.fileExists(atPath: url.appendingPathComponent("build.sh").path) { return url }
        }
        throw XCTSkip("repository root not found")
    }

    // MARK: - Processes and disk

    static func ps() -> [(pid: pid_t, pgid: pid_t, command: String)] {
        let output = SystemCommandRunner().run("/bin/ps", ["-axww", "-o", "pid=,pgid=,command="]).output
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = pid_t(parts[0]), let pgid = pid_t(parts[1]) else { return nil }
            return (pid, pgid, String(parts[2]))
        }
    }

    private static func processGroup(matching predicate: (String) -> Bool) -> pid_t? {
        ps().first { predicate($0.command) }?.pgid
    }

    private static func processes(inGroup group: pid_t) -> [String] {
        ps().filter { $0.pgid == group }.map(\.command)
    }

    static func kilobytes(_ url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let output = SystemCommandRunner().run("/usr/bin/du", ["-sk", url.path]).output
        return Int64(output.split(separator: "\t").first.map(String.init) ?? "") ?? 0
    }
}

/// Samples the summed `du` size of some folders every 5 s on a background thread.
private final class DiskSampler {
    private let folders: [URL]
    private let lock = NSLock()
    private var peak: Int64 = 0
    private var running = true

    init(folders: [URL]) { self.folders = folders }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                let size = folders.reduce(Int64(0)) { $0 + EndToEndTests.kilobytes($1) }
                lock.lock()
                peak = max(peak, size)
                let more = running
                lock.unlock()
                if !more { return }
                Thread.sleep(forTimeInterval: 5)
            }
        }
    }

    /// Stops sampling and returns the peak in kilobytes, including one final sample.
    func stop() -> Int64 {
        let size = folders.reduce(Int64(0)) { $0 + EndToEndTests.kilobytes($1) }
        lock.lock()
        defer { lock.unlock() }
        running = false
        peak = max(peak, size)
        return peak
    }
}
