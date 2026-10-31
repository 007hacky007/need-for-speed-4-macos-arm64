import Foundation

public enum PipelineRunnerError: LocalizedError, Equatable {
    case alreadyStarted
    case spawnFailed(path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            return "This step was already started"
        case let .spawnFailed(path, code):
            return "Could not start \(path): \(String(cString: strerror(code)))"
        }
    }
}

/// Runs one pipeline command in its own process group and reports its output as events.
///
/// The child gets stdin from /dev/null, stdout and stderr pipes and no other descriptors.
/// Every output line goes through `parsePipelineLine`. All callbacks arrive on the main
/// queue, and `onExit` comes after the last event. The exit status is passed through as is
/// (128 + signal when the child was killed by a signal); a nonzero status is a failure even
/// when no error event was printed.
public final class PipelineRunner {
    public static let searchPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    public let executable: URL
    public let arguments: [String]
    public let workingDirectory: URL
    public let environment: [String: String]

    /// Seconds between SIGTERM and SIGKILL when cancelling.
    var killGracePeriod: TimeInterval = 5

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var started = false
    private var reaped = false
    private var cancelled = false

    public init(executable: URL, arguments: [String], workingDirectory: URL, environment: [String: String]) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
    }

    /// The environment every pipeline command gets: a fixed PATH, unbuffered Python, HOME and
    /// TMPDIR. Nothing else is inherited, so no NFSIV_* variable reaches the pipeline (the
    /// cache is always passed with --cache).
    public static func pipelineEnvironment(_ inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = [
            "PATH": searchPath,
            "PYTHONUNBUFFERED": "1",
            "HOME": inherited["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory(),
        ]
        if let temporary = inherited["TMPDIR"], !temporary.isEmpty { result["TMPDIR"] = temporary }
        return result
    }

    // MARK: - Pipeline commands

    /// Sets up the private package environment in the cache. Never runs xcrun.
    public static func setup(paths: BuilderPaths, version: String) -> PipelineRunner {
        python(paths, version, ["tools/build_app.py", "--setup-only", "--progress", "--cache", paths.cache.path])
    }

    public static func toolsStatus(paths: BuilderPaths, version: String) -> PipelineRunner {
        python(paths, version, ["tools/builder_cli.py", "tools", "status", "--cache", paths.cache.path])
    }

    public static func checkGame(paths: BuilderPaths, version: String, game: URL) -> PipelineRunner {
        python(paths, version, ["tools/builder_cli.py", "check-game", "--cache", paths.cache.path, "--", game.path])
    }

    public static func downloadsStatus(paths: BuilderPaths, version: String, community: Bool) -> PipelineRunner {
        python(paths, version, ["tools/builder_cli.py", "downloads", "status"]
            + (community ? ["--community"] : []) + ["--cache", paths.cache.path])
    }

    public static func fetchDownloads(paths: BuilderPaths, version: String, community: Bool) -> PipelineRunner {
        python(paths, version, ["tools/builder_cli.py", "downloads", "fetch"]
            + (community ? ["--community"] : []) + ["--cache", paths.cache.path])
    }

    public static func supported(paths: BuilderPaths, version: String) -> PipelineRunner {
        python(paths, version, ["tools/builder_cli.py", "supported"])
    }

    /// The build. Its prepared game and community files are removed when it ends; the output
    /// is out/NFSIV.app inside the workspace, never a folder the user chose.
    public static func build(paths: BuilderPaths, version: String, game: URL, community: Bool) -> PipelineRunner {
        python(paths, version, ["tools/build_app.py", "--progress", "--cache", paths.cache.path, "--discard-intermediates"]
            + (community ? ["--community"] : []) + ["--", game.path])
    }

    /// Every command runs the private Python directly; build_app.py creates and uses the venv itself.
    private static func python(_ paths: BuilderPaths, _ version: String, _ arguments: [String]) -> PipelineRunner {
        PipelineRunner(executable: paths.pythonExecutable, arguments: ["-B"] + arguments,
                       workingDirectory: paths.workspace(version: version), environment: pipelineEnvironment())
    }

    // MARK: - Running

    public func start(onEvent: @escaping (PipelineEvent) -> Void, onExit: @escaping (Int32) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { throw PipelineRunnerError.alreadyStarted }

        var out: [Int32] = [-1, -1]
        var err: [Int32] = [-1, -1]
        guard pipe(&out) == 0 else { throw PipelineRunnerError.spawnFailed(path: executable.path, code: errno) }
        guard pipe(&err) == 0 else {
            let code = errno
            out.forEach { close($0) }
            throw PipelineRunnerError.spawnFailed(path: executable.path, code: code)
        }
        // Keep our ends out of any other child spawned concurrently from this process.
        for fd in out + err { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }

        let child: pid_t
        do {
            child = try spawn(stdout: out[1], stderr: err[1])
        } catch {
            (out + err).forEach { close($0) }
            throw error
        }
        close(out[1])
        close(err[1])
        pid = child
        started = true

        let readersDone = DispatchSemaphore(value: 0)
        let stdoutFD = out[0], stderrFD = err[0]
        Thread.detachNewThread {
            PipelineRunner.readLines(stdoutFD, stderrFD) { line in
                let event = parsePipelineLine(line)
                DispatchQueue.main.async { onEvent(event) }
            }
            readersDone.signal()
        }
        Thread.detachNewThread {
            self.awaitExit(child, readersDone: readersDone, onExit: onExit)
        }
    }

    /// Stops the whole process group: SIGTERM now, SIGKILL after the grace period if the
    /// child has not been reaped by then. Does nothing before start or after exit.
    public func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard started, !reaped, !cancelled else { return }
        cancelled = true
        let group = pid
        killpg(group, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + killGracePeriod) {
            self.lock.lock()
            defer { self.lock.unlock() }
            if !self.reaped { killpg(group, SIGKILL) }
        }
    }

    private func spawn(stdout: Int32, stderr: Int32) throws -> pid_t {
        func check(_ code: Int32) throws {
            if code != 0 { throw PipelineRunnerError.spawnFailed(path: executable.path, code: code) }
        }

        var actions: posix_spawn_file_actions_t?
        try check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try check(posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, stdout, 1))
        try check(posix_spawn_file_actions_adddup2(&actions, stderr, 2))
        try check(workingDirectory.withUnsafeFileSystemRepresentation {
            posix_spawn_file_actions_addchdir_np(&actions, $0!)
        })

        var attributes: posix_spawnattr_t?
        try check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        // Own process group (pgroup 0 = the child's pid), default signal handlers, nothing
        // blocked, and every descriptor not named in `actions` closed in the child.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT
        try check(posix_spawnattr_setflags(&attributes, Int16(flags)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var all = sigset_t()
        sigfillset(&all)
        try check(posix_spawnattr_setsigdefault(&attributes, &all))
        var none = sigset_t()
        sigemptyset(&none)
        try check(posix_spawnattr_setsigmask(&attributes, &none))

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var child: pid_t = 0
        try check(executable.withUnsafeFileSystemRepresentation {
            posix_spawn(&child, $0!, &actions, &attributes, argv, envp)
        })
        return child
    }

    private func awaitExit(_ child: pid_t, readersDone: DispatchSemaphore, onExit: @escaping (Int32) -> Void) {
        // Wait for the exit without reaping: while the zombie exists its pid, and so the
        // process group id, cannot be reused, which keeps every killpg below safe.
        var info = siginfo_t()
        var result: Int32
        repeat {
            result = waitid(P_PID, id_t(child), &info, WEXITED | WNOWAIT)
        } while result == -1 && errno == EINTR
        let observed = result == 0

        lock.lock()
        if observed {
            // The pipeline is over; nothing it started may keep running (or keep our pipes open).
            killpg(child, SIGKILL)
        } else {
            // Someone else reaped the child (SIGCHLD ignored): the group id is no longer ours.
            reaped = true
        }
        lock.unlock()

        readersDone.wait()

        lock.lock()
        reaped = true
        lock.unlock()

        var code: Int32 = -1
        if observed {
            var status: Int32 = 0
            var reapedPID: pid_t
            repeat {
                reapedPID = waitpid(child, &status, 0)
            } while reapedPID == -1 && errno == EINTR
            if reapedPID == child { code = PipelineRunner.exitCode(status) }
        }
        DispatchQueue.main.async { onExit(code) }
    }

    static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// Reads both pipes until EOF on each, splitting on newlines; a trailing partial line is
    /// delivered at EOF. Each poll round drains stdout before stderr. Closes both descriptors.
    private static func readLines(_ stdout: Int32, _ stderr: Int32, emit: (String) -> Void) {
        let descriptors = [stdout, stderr]
        var open = [true, true]
        var pending = [[UInt8](), [UInt8]()]
        var chunk = [UInt8](repeating: 0, count: 65_536)
        var polled = descriptors.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }

        func finish(_ index: Int) {
            open[index] = false
            close(descriptors[index])
            if !pending[index].isEmpty { emit(decode(pending[index][...])) }
            pending[index] = []
        }

        while open.contains(true) {
            for index in polled.indices {
                polled[index].fd = open[index] ? descriptors[index] : -1
                polled[index].revents = 0
            }
            if poll(&polled, nfds_t(polled.count), -1) == -1 {
                if errno == EINTR { continue }
                for index in descriptors.indices where open[index] { finish(index) }
                break
            }
            for index in descriptors.indices where open[index] && polled[index].revents != 0 {
                let count = chunk.withUnsafeMutableBytes { read(descriptors[index], $0.baseAddress, $0.count) }
                if count == -1 && errno == EINTR { continue }
                if count <= 0 {
                    finish(index)
                    continue
                }
                pending[index].append(contentsOf: chunk[0..<count])
                var start = 0
                while let newline = pending[index][start...].firstIndex(of: 0x0A) {
                    emit(decode(pending[index][start..<newline]))
                    start = newline + 1
                }
                pending[index].removeFirst(start)
            }
        }
    }

    private static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes.last == 0x0D ? bytes.dropLast() : bytes, as: UTF8.self)
    }
}
