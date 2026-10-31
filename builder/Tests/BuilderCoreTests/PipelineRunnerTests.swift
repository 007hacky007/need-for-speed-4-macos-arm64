import XCTest
@testable import BuilderCore

final class PipelineRunnerTests: XCTestCase {
    private var tmp: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        tmp = fm.temporaryDirectory.appendingPathComponent("nfsiv runner \"q\" ö-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: tmp)
    }

    // MARK: - Helpers

    private func runner(_ executable: String, _ arguments: [String],
                        environment: [String: String] = ["PATH": "/usr/bin:/bin"]) -> PipelineRunner {
        PipelineRunner(executable: URL(fileURLWithPath: executable), arguments: arguments,
                       workingDirectory: tmp, environment: environment)
    }

    /// `/bin/sh -c script sh args...`: the script sees `args` as $1, $2, ...
    private func shell(_ script: String, _ args: [String] = []) -> PipelineRunner {
        runner("/bin/sh", ["-c", script, "sh"] + args)
    }

    private final class Recording {
        var events: [PipelineEvent] = []
        var status: Int32?
        var eventsAtExit: Int?
        var offMain = false
        var eventsAfterExit = false
    }

    /// Starts the runner and waits for onExit; `onEvent` runs for every event before it is recorded.
    @discardableResult
    private func run(_ runner: PipelineRunner, timeout: TimeInterval = 20,
                     onEvent: ((PipelineEvent) -> Void)? = nil) throws -> Recording {
        let recording = Recording()
        let exited = expectation(description: "onExit")
        try runner.start(onEvent: { event in
            if !Thread.isMainThread { recording.offMain = true }
            if recording.status != nil { recording.eventsAfterExit = true }
            recording.events.append(event)
            onEvent?(event)
        }, onExit: { status in
            if !Thread.isMainThread { recording.offMain = true }
            recording.status = status
            recording.eventsAtExit = recording.events.count
            exited.fulfill()
        })
        wait(for: [exited], timeout: timeout)
        XCTAssertFalse(recording.offMain, "callbacks must run on the main queue")
        XCTAssertFalse(recording.eventsAfterExit, "onExit must come after all events")
        return recording
    }

    private func waitUntilGone(_ pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if kill(pid, 0) == -1 && errno == ESRCH { return true }
            usleep(10_000)
        } while Date() < deadline
        return false
    }

    private func openDescriptorCount() -> Int {
        let limit = min(Int32(getdtablesize()), 65_536)
        return (0..<limit).filter { fcntl($0, F_GETFD) != -1 }.count
    }

    /// Runs `script` (which must write "$$" then the background pid to $1 and then print "ready"),
    /// cancels once "ready" arrives, and returns the exit status, the pids and the cancel-to-exit time.
    private func cancelAfterReady(_ script: String, grace: TimeInterval? = nil,
                                  timeout: TimeInterval) throws -> (status: Int32?, pids: [pid_t], elapsed: TimeInterval) {
        let pidfile = tmp.appendingPathComponent("pids")
        let r = shell(script, [pidfile.path])
        if let grace = grace { r.killGracePeriod = grace }
        let ready = expectation(description: "ready")
        let exited = expectation(description: "onExit")
        var status: Int32?
        try r.start(onEvent: { if $0 == .log("ready") { ready.fulfill() } },
                    onExit: { status = $0; exited.fulfill() })
        wait(for: [ready], timeout: 10)
        let pids = (try String(contentsOf: pidfile, encoding: .utf8))
            .split(separator: "\n").compactMap { pid_t(String($0)) }
        XCTAssertEqual(pids.count, 2)
        let cancelled = Date()
        r.cancel()
        wait(for: [exited], timeout: timeout)
        return (status, pids, Date().timeIntervalSince(cancelled))
    }

    // MARK: - Spec tests

    func testArgumentsWithSpacesQuotesUnicodeAndLeadingDashArriveIntact() throws {
        let argument = #"-NFS Road Challenge (EU) "copy"/Pörsche.ccd"#
        // Passed as one argv entry, never through a shell that would split or expand it.
        let r = try run(runner("/usr/bin/printf", ["%s\n", argument]))
        XCTAssertEqual(r.events, [.log(argument)])
        XCTAssertEqual(r.status, 0)
        let echoed = try run(shell(#"for a in "$@"; do echo "$a"; done"#, ["--", argument, "$HOME", "*"]))
        XCTAssertEqual(echoed.events, [.log("--"), .log(argument), .log("$HOME"), .log("*")])
    }

    func testEventsAndExitStatus() throws {
        let r = try run(shell(#"echo 'NFSIV-EVENT {"step":"verify","title":"Checking"}'; echo hello >&2; exit 3"#))
        XCTAssertEqual(r.events, [.step(id: "verify", title: "Checking"), .log("hello")])
        XCTAssertEqual(r.status, 3)
    }

    func testCancelStopsWholeProcessGroup() throws {
        let result = try cancelAfterReady(#"echo $$ > "$1"; sleep 60 & echo $! >> "$1"; echo ready; wait"#,
                                          timeout: 6)
        XCTAssertEqual(result.status, 128 + SIGTERM)
        XCTAssertLessThan(result.elapsed, 6)
        for pid in result.pids {
            XCTAssertTrue(waitUntilGone(pid, timeout: 6 - min(result.elapsed, 5)), "pid \(pid) still alive")
        }
    }

    // MARK: - Process control

    func testCancelEscalatesToKillWhenTermIsIgnored() throws {
        let result = try cancelAfterReady(#"trap '' TERM; echo $$ > "$1"; sleep 60 & echo $! >> "$1"; echo ready; wait"#,
                                          grace: 0.3, timeout: 10)
        XCTAssertEqual(result.status, 128 + SIGKILL)
        XCTAssertGreaterThanOrEqual(result.elapsed, 0.3)
        for pid in result.pids {
            XCTAssertTrue(waitUntilGone(pid, timeout: 5), "pid \(pid) still alive")
        }
    }

    func testLeftoverBackgroundProcessIsStoppedWhenChildExits() throws {
        let pidfile = tmp.appendingPathComponent("pid")
        let r = try run(shell(#"sleep 60 & echo $! > "$1"; echo bye; exit 4"#, [pidfile.path]), timeout: 10)
        XCTAssertEqual(r.events, [.log("bye")])
        XCTAssertEqual(r.status, 4)
        let pid = try XCTUnwrap(pid_t(try String(contentsOf: pidfile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertTrue(waitUntilGone(pid, timeout: 5), "background sleep outlived the pipeline")
    }

    func testDefaultKillGracePeriodIsFiveSeconds() {
        XCTAssertEqual(shell("true").killGracePeriod, 5)
    }

    func testCancelBeforeStartAndAfterExitIsHarmless() throws {
        let r = shell("echo once")
        r.cancel()
        let recording = try run(r)
        XCTAssertEqual(recording.events, [.log("once")])
        XCTAssertEqual(recording.status, 0)
        r.cancel()
        r.cancel()
    }

    func testStartingTwiceThrows() throws {
        let r = shell("true")
        try run(r)
        XCTAssertThrowsError(try r.start(onEvent: { _ in }, onExit: { _ in }))
    }

    func testMissingExecutableThrows() {
        let r = runner(tmp.appendingPathComponent("no such python").path, [])
        XCTAssertThrowsError(try r.start(onEvent: { _ in }, onExit: { _ in }))
    }

    func testMissingWorkingDirectoryThrows() {
        let r = PipelineRunner(executable: URL(fileURLWithPath: "/bin/echo"), arguments: [],
                               workingDirectory: tmp.appendingPathComponent("gone"), environment: [:])
        XCTAssertThrowsError(try r.start(onEvent: { _ in }, onExit: { _ in }))
    }

    // MARK: - Output

    func testTrailingPartialLineIsFlushed() throws {
        let r = try run(shell(#"printf 'one\ntwo'; printf 'err' >&2"#))
        XCTAssertEqual(r.events.count, 3)
        XCTAssertTrue(r.events.contains(.log("err")))
        XCTAssertEqual(r.events.filter { $0 != .log("err") }, [.log("one"), .log("two")])
    }

    func testCarriageReturnLineEndingsAreStripped() throws {
        let r = try run(shell(#"printf 'one\r\ntwo\r\n'"#))
        XCTAssertEqual(r.events, [.log("one"), .log("two")])
    }

    func testFullStderrPipeDoesNotDeadlock() throws {
        // 50000 stderr lines (about 200 KB, far past a pipe buffer) before anything on stdout.
        let r = try run(shell("yes err | head -n 50000 >&2; yes out | head -n 50000; echo end"))
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.events.count, 100_001)
        XCTAssertEqual(r.eventsAtExit, 100_001)
        XCTAssertEqual(r.events.filter { $0 == .log("err") }.count, 50_000)
        XCTAssertEqual(r.events.filter { $0 == .log("out") }.count, 50_000)
        XCTAssertEqual(r.events.last, .log("end"))
    }

    func testNonzeroExitWithoutErrorEventIsPassedThrough() throws {
        let r = try run(shell("echo working; exit 1"))
        XCTAssertEqual(r.events, [.log("working")])
        XCTAssertEqual(r.status, 1)
    }

    // MARK: - Child setup

    func testChildRunsInWorkingDirectoryWithExactEnvironment() throws {
        let env = ["PATH": "/usr/bin:/bin", "NFSIV_TEST": #"a b "c" ö"#]
        let pwd = try run(runner("/bin/pwd", ["-P"], environment: env))
        var resolved = [CChar](repeating: 0, count: Int(PATH_MAX))
        XCTAssertNotNil(realpath(tmp.path, &resolved))
        XCTAssertEqual(pwd.events, [.log(String(cString: resolved))])

        let printed = try run(runner("/usr/bin/env", [], environment: env))
        let lines = printed.events.compactMap { event -> String? in
            if case .log(let line) = event { return line }
            return nil
        }
        XCTAssertEqual(lines.sorted(), env.map { "\($0.key)=\($0.value)" }.sorted())
    }

    func testChildOwnsItsProcessGroup() throws {
        let r = try run(shell(#"echo "$$ $(ps -o pgid= -p $$)""#))
        guard case .log(let line)? = r.events.first else { return XCTFail("no output") }
        let fields = line.split(separator: " ").map(String.init)
        XCTAssertEqual(fields.count, 2)
        XCTAssertEqual(fields.first, fields.last, "child must lead its own process group")
        XCTAssertNotEqual(fields.last.flatMap { pid_t($0) }, getpgrp())
    }

    func testChildGetsOnlyStandardDescriptors() throws {
        let stray = open("/dev/null", O_RDONLY)
        XCTAssertGreaterThan(stray, 2)
        defer { close(stray) }
        let script = #"""
        if [ -e /dev/fd/$1 ]; then echo "fd $1 open"; else echo "fd $1 closed"; fi
        if [ "$(stat -L -f %r /dev/fd/0)" = "$(stat -f %r /dev/null)" ]; then echo "stdin null"; else echo "stdin other"; fi
        cat
        echo done
        """#
        let r = try run(shell(script, [String(stray)]))
        XCTAssertEqual(r.events, [.log("fd \(stray) closed"), .log("stdin null"), .log("done")])
    }

    func testNoDescriptorsLeakInTheParent() throws {
        let before = openDescriptorCount()
        for _ in 0..<5 {
            try run(shell("echo out; echo err >&2"))
        }
        try run(shell("yes x | head -n 20000"))
        _ = try? runner("/nonexistent/python", []).start(onEvent: { _ in }, onExit: { _ in })
        _ = try? cancelAfterReady(#"echo $$ > "$1"; sleep 60 & echo $! >> "$1"; echo ready; wait"#, timeout: 6)
        XCTAssertEqual(openDescriptorCount(), before)
    }

    // MARK: - Environment and constructors

    func testEnvironmentDropsInheritedNFSIVVariables() {
        let inherited = ["HOME": "/Users/someone", "PATH": "/opt/homebrew/bin:/usr/bin", "PYTHONPATH": "/x", "LANG": "C",
                         "NFSIV_GLSLANG": "/x", "NFSIV_MOLTENVK": "/y", "NFSIV_BUILDER_CACHE": "/z", "NFSV_CACHE_DIR": "/w",
                         "TMPDIR": "/var/folders/t/"]
        XCTAssertEqual(PipelineRunner.pipelineEnvironment(inherited),
                       ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONUNBUFFERED": "1", "HOME": "/Users/someone",
                        "TMPDIR": "/var/folders/t/"])
        XCTAssertEqual(PipelineRunner.pipelineEnvironment([:]),
                       ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "PYTHONUNBUFFERED": "1", "HOME": NSHomeDirectory()])
    }

    func testConvenienceConstructors() {
        let cache = tmp.appendingPathComponent("Cache Disk/NFSIV")
        let paths = BuilderPaths(support: tmp, cache: cache)
        let workspace = paths.workspace(version: "1.2.0")
        let c = cache.path
        let game = URL(fileURLWithPath: #"/Users/x/Games/NFS Road Challenge (EU) "copy"/-NFS.ccd"#)
        let expected: [(PipelineRunner, [String])] = [
            (.setup(paths: paths, version: "1.2.0"), ["tools/build_app.py", "--setup-only", "--progress", "--cache", c]),
            (.toolsStatus(paths: paths, version: "1.2.0"), ["tools/builder_cli.py", "tools", "status", "--cache", c]),
            (.checkGame(paths: paths, version: "1.2.0", game: game),
             ["tools/builder_cli.py", "check-game", "--cache", c, "--", game.path]),
            (.downloadsStatus(paths: paths, version: "1.2.0", community: false),
             ["tools/builder_cli.py", "downloads", "status", "--cache", c]),
            (.downloadsStatus(paths: paths, version: "1.2.0", community: true),
             ["tools/builder_cli.py", "downloads", "status", "--community", "--cache", c]),
            (.fetchDownloads(paths: paths, version: "1.2.0", community: true),
             ["tools/builder_cli.py", "downloads", "fetch", "--community", "--cache", c]),
            (.supported(paths: paths, version: "1.2.0"), ["tools/builder_cli.py", "supported"]),
            (.build(paths: paths, version: "1.2.0", game: game, community: false),
             ["tools/build_app.py", "--progress", "--cache", c, "--discard-intermediates", "--", game.path]),
        ]
        for (runner, arguments) in expected {
            XCTAssertEqual(runner.executable, paths.pythonExecutable)
            XCTAssertEqual(runner.arguments, ["-B"] + arguments)
            XCTAssertEqual(runner.workingDirectory, workspace)
            XCTAssertEqual(runner.environment, PipelineRunner.pipelineEnvironment())
        }
    }

    func testBuildCommandShape() {
        let paths = BuilderPaths(support: tmp, cache: URL(fileURLWithPath: "/c"))
        let game = URL(fileURLWithPath: "/g/-NFS.ccd")
        XCTAssertEqual(PipelineRunner.build(paths: paths, version: "1", game: game, community: true).arguments,
                       ["-B", "tools/build_app.py", "--progress", "--cache", "/c", "--discard-intermediates",
                        "--community", "--", "/g/-NFS.ccd"])
    }
}
