import AppKit
import BuilderCore

/// Owns the checklist state, runs the pipeline commands and drives the build.
final class BuilderModel: ObservableObject {
    enum Phase: Equatable {
        case checklist
        case building(stepID: String, fraction: Double, log: [String])
        case finished(URL)
        case failed(step: String, message: String, log: [String])
        /// The build finished but NFSIV is running; installing waits until the user quits it.
        case quitToInstall(built: URL)
    }

    @Published private(set) var states: [CheckID: CheckState]
    @Published private(set) var phase: Phase = .checklist
    @Published private(set) var gamePath: URL?
    @Published private(set) var destination: URL
    /// Include community cars and tracks (remembered, off by default).
    @Published private(set) var community: Bool
    /// The option the running or last build used, for its step list.
    @Published private(set) var buildCommunity = false
    /// True once Cancel was pressed or the app started installing, so Cancel can no longer act.
    @Published private(set) var cancelDisabled = false
    @Published private(set) var buildFilesRemoved = false
    /// A plain message shown as an alert over the checklist.
    @Published var notice: String?
    /// Output of the last failed build tools install, for Copy details.
    @Published private(set) var setupDetails: String?
    /// Why the pipeline refused the chosen game copy, while the game row is red for that reason.
    @Published private(set) var gameRejection: GameRejection?
    /// The rejection message plus what the check logged (detected inventory), for Copy details.
    @Published private(set) var gameDetails: String?
    /// Whether the "Which copy works?" sheet is open. Quitting closes it first.
    @Published var showingSupported = false
    /// The accepted release for the "Which copy works?" sheet, loaded once from the pipeline.
    @Published private(set) var supported: SupportedRelease?
    @Published private(set) var supportedFailed = false

    let paths = BuilderPaths()
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
    private let sources = BuilderModel.findSources()
    private let defaults = UserDefaults.standard

    private var live: [ObjectIdentifier: PipelineRunner] = [:]
    private var idleHandlers: [() -> Void] = []
    private var shuttingDown = false
    private var workspaceReady = false
    private var installingTools = false
    private var downloadTask: URLSessionDownloadTask?
    private var downloadProgress: NSKeyValueObservation?
    private var cltTimer: Timer?
    private var toolsRunner: PipelineRunner?
    private var gameRunner: PipelineRunner?
    private var checkedGame: URL?
    /// A chosen item that is not a game candidate, with the reason, until another is chosen.
    private var gameChoiceMessage: String?
    private var downloadsRunner: PipelineRunner?
    /// The community setting the Downloads row was last checked for.
    private var downloadsCheckedFor: Bool?
    private var supportedRunner: PipelineRunner?

    private var buildRunner: PipelineRunner?
    private var buildLog: [String] = []
    private var buildStep = ""
    private var buildError: String?
    private var builtApp: URL?
    private var userCancelled = false
    private var flushScheduled = false

    init() {
        var initial = Dictionary(uniqueKeysWithValues: CheckID.allCases.map { ($0, CheckState.checking("Checking...")) })
        let saved = UserDefaults.standard
        let community = saved.bool(forKey: "community")
        self.community = community
        initial[.downloads] = Self.downloadsPending(community: community)
        states = initial
        gamePath = saved.string(forKey: "gamePath").map { URL(fileURLWithPath: $0) }
        destination = saved.string(forKey: "destination").map { URL(fileURLWithPath: $0) } ?? defaultDestination
    }

    private static func downloadsPending(community: Bool) -> CheckState {
        .automatic("Will be downloaded during the build (about \(community ? 245 : 75) MB)")
    }

    // MARK: - Checklist

    var toolsReady: Bool { states[.buildTools]?.isReady == true }
    /// The game copy and download checks need only the private Python, not the packages.
    var pythonReady: Bool { workspaceReady && PythonRuntime.isInstalled(paths) }
    var buildEnabled: Bool { canBuild(states) }

    func start() {
        refresh()
        prepare(sweep: true) { [self] _ in refreshBuildTools() }
    }

    /// Re-evaluates every row. Expensive checks (the game copy) only run again when their input changed.
    func refresh() {
        guard phase == .checklist, !shuttingDown else { return }
        states[.mac] = macCheck(isAppleSilicon: Self.isAppleSilicon, version: ProcessInfo.processInfo.operatingSystemVersion)
        states[.destination] = destinationCheck(destination)
        states[.diskSpace] = diskSpaceState()
        refreshCommandLineTools()
        refreshBuildTools()
    }

    private func refreshBuildTools() {
        if workspaceReady && !installingTools {
            if !PythonRuntime.isInstalled(paths) {
                states[.buildTools] = buildToolsState(pythonInstalled: false, tools: nil)
            } else if !toolsReady && toolsRunner == nil {
                checkTools()
            }
        }
        refreshDownloads()
        refreshGame()
    }

    private func checkTools() {
        let runner = PipelineRunner.toolsStatus(paths: paths, version: version)
        toolsRunner = runner
        var tools: PipelineEvent?
        run(runner, onEvent: { event in
            if case .tools = event { tools = event }
        }, onExit: { [self] _ in
            guard toolsRunner === runner else { return }
            toolsRunner = nil
            guard !installingTools else { return }
            states[.buildTools] = buildToolsState(pythonInstalled: PythonRuntime.isInstalled(paths), tools: tools)
        })
    }

    private func refreshCommandLineTools() {
        DispatchQueue.global(qos: .userInitiated).async {
            let state = CommandLineTools().state()
            DispatchQueue.main.async { [self] in
                states[.commandLineTools] = state
                if state.isReady { cltTimer?.invalidate(); cltTimer = nil }
            }
        }
    }

    func installCommandLineTools() {
        DispatchQueue.global(qos: .userInitiated).async { CommandLineTools().startInstall() }
        cltTimer?.invalidate()
        cltTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.refreshCommandLineTools()
        }
    }

    /// Free space on the workspace volume and, if different, the cache volume (the smaller
    /// counts), plus the destination's volume when the app has to be copied onto another one.
    private func diskSpaceState() -> CheckState {
        func volume(_ start: URL) -> (id: NSObject?, available: Int64)? {
            var url = start
            while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" {
                url = url.deletingLastPathComponent()
            }
            let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeIdentifierKey])
            guard let available = values?.volumeAvailableCapacityForImportantUsage else { return nil }
            return (values?.volumeIdentifier as? NSObject, available)
        }
        guard let support = volume(paths.support), let cache = volume(paths.cache),
              let target = volume(destination) else {
            return .blocked("Could not read the free space on this disk")
        }
        let elsewhere = target.id == nil || (target.id != support.id && target.id != cache.id)
        return diskSpaceCheck(available: min(support.available, cache.available), community: community,
                              destinationAvailable: elsewhere ? target.available : nil)
    }

    func setCommunity(_ value: Bool) {
        guard phase == .checklist, value != community else { return }
        community = value
        defaults.set(value, forKey: "community")
        states[.diskSpace] = diskSpaceState()
        refreshDownloads()
    }

    func setDestination(_ url: URL) {
        destination = url
        defaults.set(url.path, forKey: "destination")
        states[.destination] = destinationCheck(url)
        states[.diskSpace] = diskSpaceState()
    }

    static let gameExtensions = ["iso", "bin", "img", "cue", "ccd"]

    /// Why `url` cannot be chosen as a game copy, or nil when it can.
    static func gameChoiceProblem(_ url: URL) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return "The game copy was not found. Choose it again."
        }
        if isDir.boolValue || gameExtensions.contains(url.pathExtension.lowercased()) { return nil }
        if url.pathExtension.lowercased() == "sub" { return "Choose the .ccd or .img file, not .sub" }
        return "Choose a game folder, .iso, .bin, .img, .cue or .ccd"
    }

    func setGame(_ url: URL) {
        guard phase == .checklist else { return }
        if let problem = Self.gameChoiceProblem(url) {
            gameRunner?.cancel()
            gameRunner = nil
            gameChoiceMessage = problem
            gamePath = nil
            defaults.removeObject(forKey: "gamePath")
        } else {
            gameChoiceMessage = nil
            gamePath = url
            defaults.set(url.path, forKey: "gamePath")
        }
        checkedGame = nil
        refreshGame()
    }

    private func clearGameResult() {
        gameRejection = nil
        gameDetails = nil
    }

    private func refreshGame() {
        guard let game = gamePath else {
            clearGameResult()
            states[.gameCopy] = .blocked(gameChoiceMessage ?? "Choose a game folder, .iso, .bin, .img, .cue or .ccd")
            return
        }
        guard pythonReady else {
            gameRunner?.cancel()
            gameRunner = nil
            checkedGame = nil
            clearGameResult()
            states[.gameCopy] = .checking("Checked once Python is installed")
            return
        }
        guard checkedGame != game else { return }
        gameRunner?.cancel()
        checkedGame = game
        clearGameResult()
        states[.gameCopy] = .checking("Checking your game copy...")
        let runner = PipelineRunner.checkGame(paths: paths, version: version, game: game)
        gameRunner = runner
        var detected: String?
        var rejection: GameRejection?
        var message: String?
        var output: [String] = []
        run(runner, onEvent: { event in
            switch event {
            case let .game(version): detected = version
            case let .rejected(value): rejection = value
            case let .error(text): message = text
            case let .log(line): output.append(line)
            default: break
            }
        }, onExit: { [self] status in
            guard gameRunner === runner else { return }
            gameRunner = nil
            if status == 0, let detected = detected {
                states[.gameCopy] = .ready(detected)
            } else {
                let text = Self.plain(rejection?.message ?? message ?? "Could not check this game copy")
                gameRejection = rejection
                gameDetails = rejection != nil || message != nil ? gameCheckDetails(message: text, log: output) : nil
                states[.gameCopy] = .blocked(text)
            }
        })
    }

    /// Loads the accepted release from `builder_cli supported`, which needs only the private Python.
    func loadSupported() {
        guard supported == nil, supportedRunner == nil, pythonReady else {
            if !pythonReady { supportedFailed = true }
            return
        }
        supportedFailed = false
        let runner = PipelineRunner.supported(paths: paths, version: version)
        supportedRunner = runner
        var release: SupportedRelease?
        run(runner, onEvent: { event in
            if case let .supported(value) = event { release = value }
        }, onExit: { [self] _ in
            supportedRunner = nil
            supported = release
            supportedFailed = release == nil
        })
    }

    private func refreshDownloads() {
        guard pythonReady else {
            downloadsCheckedFor = nil
            states[.downloads] = Self.downloadsPending(community: community)
            return
        }
        guard downloadsRunner == nil else { return }
        if downloadsCheckedFor == community, states[.downloads]?.isReady == true { return }
        checkDownloads()
    }

    private func checkDownloads() {
        let checkedFor = community
        let runner = PipelineRunner.downloadsStatus(paths: paths, version: version, community: checkedFor)
        downloadsRunner = runner
        var state: DownloadsState?
        run(runner, onEvent: { event in
            if case let .downloads(value) = event { state = value }
        }, onExit: { [self] _ in
            guard downloadsRunner === runner else { return }
            downloadsRunner = nil
            downloadsCheckedFor = checkedFor
            switch state {
            case .ready?: states[.downloads] = .ready("Downloaded and verified")
            case .damaged?: states[.downloads] = .blocked("A saved download is damaged")
            default: states[.downloads] = Self.downloadsPending(community: checkedFor)
            }
            // The option changed while this check ran.
            if checkedFor != community { refreshDownloads() }
        })
    }

    var downloadsDamaged: Bool {
        if case .blocked? = states[.downloads] { return true }
        return false
    }

    func fetchDownloads() {
        guard pythonReady, phase == .checklist else { return }
        downloadsRunner?.cancel()
        states[.downloads] = .checking("Downloading...")
        let fetchedFor = community
        let runner = PipelineRunner.fetchDownloads(paths: paths, version: version, community: fetchedFor)
        downloadsRunner = runner
        var message: String?
        run(runner, onEvent: { event in
            if case let .error(text) = event { message = text }
        }, onExit: { [self] status in
            guard downloadsRunner === runner else { return }
            downloadsRunner = nil
            if status == 0 && fetchedFor == community {
                downloadsCheckedFor = fetchedFor
                states[.downloads] = .ready("Downloaded and verified")
            } else if status == 0 {
                refreshDownloads()
            } else {
                downloadsCheckedFor = fetchedFor
                states[.downloads] = .automatic((message ?? "The download failed.") + " It will be tried again during the build.")
            }
        })
    }

    // MARK: - Build tools

    /// `sweep` (only on start, when nothing else uses the support folder) first deletes what an
    /// interrupted removal or copy left behind and, once the workspace is ready, old versions.
    private func prepare(sweep: Bool = false, _ completion: @escaping (Bool) -> Void) {
        if workspaceReady { return completion(true) }
        guard let sources = sources else {
            states[.buildTools] = .blocked("This copy of NFSIV Builder is incomplete. Download it again.")
            return completion(false)
        }
        states[.buildTools] = .checking("Preparing build files...")
        let (paths, version) = (paths, version)
        DispatchQueue.global(qos: .userInitiated).async {
            if sweep { sweepLeftovers(paths) }
            let result = Result {
                try prepareWorkspace(sources: sources, destination: paths.workspace(version: version), version: version)
            }
            if sweep, case .success = result {
                // Synchronous: no game check or build may start while this runs.
                sweepWorkspaceLeftovers(paths.workspace(version: version))
                DispatchQueue.global(qos: .utility).async { removeOldWorkspaces(paths, keeping: version) }
            }
            DispatchQueue.main.async { [self] in
                if case let .failure(error) = result {
                    states[.buildTools] = .blocked("Could not copy the build files: \(error.localizedDescription)")
                } else {
                    workspaceReady = true
                }
                completion(workspaceReady)
            }
        }
    }

    func installBuildTools() {
        guard !installingTools, !shuttingDown else { return }
        installingTools = true
        setupDetails = nil
        states[.buildTools] = .checking("Installing...")
        prepare { [self] ready in
            guard ready else { installingTools = false; return }
            if PythonRuntime.isInstalled(paths) { runSetup() } else { downloadPython() }
        }
    }

    private func downloadPython() {
        states[.buildTools] = .checking("Downloading Python...")
        PythonRuntime.install(paths, download: { url, done in
            let task = URLSession.shared.downloadTask(with: url) { file, response, error in
                if let file = file, (response as? HTTPURLResponse)?.statusCode == 200 {
                    done(.success(file))
                } else {
                    done(.failure(error ?? URLError(.badServerResponse)))
                }
            }
            var shown = -1
            downloadProgress = task.progress.observe(\.fractionCompleted) { progress, _ in
                let percent = Int(progress.fractionCompleted * 100)
                guard percent != shown else { return }
                shown = percent
                DispatchQueue.main.async { [self] in
                    guard downloadTask === task else { return }
                    states[.buildTools] = .checking(percent >= 100 ? "Unpacking Python..." : "Downloading Python, \(percent)%")
                }
            }
            downloadTask = task
            task.resume()
        }, completion: { [self] result in
            downloadTask = nil
            downloadProgress = nil
            switch result {
            case .success:
                // The game copy and downloads can be checked now, while the packages install.
                refreshDownloads()
                refreshGame()
                runSetup()
            case let .failure(error):
                let text = error is URLError ? "Could not download Python. Check your internet connection and try again."
                    : Self.plain(error.localizedDescription)
                toolsFailed(text, details: String(describing: error))
            }
        })
    }

    private func runSetup() {
        states[.buildTools] = .checking("Setting up build tools...")
        var output: [String] = []
        var events: [PipelineEvent] = []
        run(.setup(paths: paths, version: version), onEvent: { event in
            events.append(event)
            switch event {
            case let .log(line): output.append(line)
            case let .step(_, title): output.append(title)
            case let .error(message): output.append("Error: \(message)")
            default: break
            }
        }, onExit: { [self] status in
            installingTools = false
            let details = (output + ["Setup exited with status \(status)."]).joined(separator: "\n")
            let state = setupResult(status: status, events: events, pythonInstalled: PythonRuntime.isInstalled(paths))
            guard state.isReady else { return toolsFailed(Self.plain(state.message), details: details) }
            states[.buildTools] = state
            refreshBuildTools()
        })
    }

    private func toolsFailed(_ message: String, details: String? = nil) {
        installingTools = false
        setupDetails = details
        states[.buildTools] = .blocked(message)
        refreshDownloads()
        refreshGame()
    }

    // MARK: - Build

    func build() {
        guard phase == .checklist, buildEnabled, let game = gamePath, !shuttingDown else { return }
        if isNFSIVRunning() {
            notice = "Quit NFSIV first, then try again."
            return
        }
        gameRunner?.cancel()
        downloadsRunner?.cancel()
        (buildLog, buildStep, buildError, builtApp) = ([], "", nil, nil)
        (userCancelled, cancelDisabled) = (false, false)
        buildCommunity = community
        phase = .building(stepID: "", fraction: 0, log: [])
        let runner = PipelineRunner.build(paths: paths, version: version, game: game, community: buildCommunity)
        buildRunner = runner
        run(runner, onEvent: { [self] event in
            switch event {
            case let .step(id, title):
                appendLog(title)
                if buildSteps(community: buildCommunity).contains(where: { $0.id == id }) {
                    buildStep = id
                    flushLog()
                }
            case let .log(line): appendLog(line)
            case let .error(message):
                buildError = message
                appendLog("Error: \(message)")
            case let .rejected(rejection):
                buildError = rejection.message
                appendLog("Error: \(rejection.message)")
            case let .done(url): builtApp = url
            default: break
            }
        }, onExit: { [self] status in
            buildRunner = nil
            if status != 0 { appendLog("The build exited with status \(status).") }
            if userCancelled || shuttingDown {
                phase = .checklist
                checkedGame = nil
                downloadsCheckedFor = nil
                return refresh()
            }
            if status == 0, buildError == nil, let built = builtApp {
                install(built)
            } else {
                fail(step: buildStepNames[buildStep] ?? "Getting ready",
                     message: buildError ?? "The build stopped unexpectedly. Click Copy log and include it in a bug report.")
            }
        })
    }

    func cancelBuild() {
        guard let runner = buildRunner else { return }
        userCancelled = true
        cancelDisabled = true
        appendLog("Cancelling...")
        runner.cancel()
    }

    /// Retries only the install of an already built app, after the user quit NFSIV.
    func installAgain() {
        guard case let .quitToInstall(built) = phase else { return }
        install(built)
    }

    private func install(_ built: URL) {
        cancelDisabled = true
        if case .quitToInstall = phase {
            guard !isNFSIVRunning() else {
                notice = "NFSIV is still running. Quit it, then click Install again."
                return
            }
            phase = .building(stepID: buildStep, fraction: 1, log: buildLog)
        } else if isNFSIVRunning() {
            appendLog("NFSIV is running, so the new build was not installed yet.")
            phase = .quitToInstall(built: built)
            return
        }
        appendLog("Installing NFSIV.app into \(destination.path)")
        flushLog()
        let directory = destination
        DispatchQueue.global(qos: .userInitiated).async {
            // Checked again here in case the game was started since; NSRunningApplication is thread safe.
            let result = Result { try installApp(built, into: directory, isRunning: isNFSIVRunning) }
            DispatchQueue.main.async { [self] in
                switch result {
                case let .success(app):
                    buildFilesRemoved = false
                    phase = .finished(app)
                case let .failure(error as InstallError) where error.details == nil && isNFSIVRunning():
                    appendLog(error.message)
                    phase = .quitToInstall(built: built)
                case let .failure(error):
                    if let details = (error as? InstallError)?.details { appendLog(details) }
                    fail(step: "Install", message: error.localizedDescription)
                }
            }
        }
    }

    private func fail(step: String, message: String) {
        phase = .failed(step: step, message: Self.plain(message), log: buildLog)
    }

    func tryAgain() {
        phase = .checklist
        checkedGame = nil
        downloadsCheckedFor = nil
        refresh()
    }

    /// The workspace is renamed aside first, so quitting during the slow delete cannot leave a
    /// marked but incomplete workspace behind; the next start sweeps whatever is left. The
    /// private Python and the shared download cache are kept.
    func removeBuildFiles() {
        let workspace = paths.workspace(version: version)
        workspaceReady = false
        if let trash = try? moveToTrash(workspace) {
            DispatchQueue.global(qos: .utility).async { try? FileManager.default.removeItem(at: trash) }
        }
        buildFilesRemoved = !FileManager.default.fileExists(atPath: workspace.path)
    }

    /// Lines arrive faster than SwiftUI should redraw, so they are published at most four times a second.
    private func appendLog(_ line: String) {
        buildLog.append(line)
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in flushLog() }
    }

    private func flushLog() {
        flushScheduled = false
        guard case .building = phase else { return }
        let fraction = buildStep.isEmpty ? 0 : progressFraction(atStart: buildStep, community: buildCommunity)
        phase = .building(stepID: buildStep, fraction: fraction, log: buildLog)
    }

    // MARK: - Processes and shutdown

    var hasRunningWork: Bool { !live.isEmpty || downloadTask != nil }

    private func run(_ runner: PipelineRunner, onEvent: @escaping (PipelineEvent) -> Void,
                     onExit: @escaping (Int32) -> Void) {
        guard !shuttingDown else { return }
        let key = ObjectIdentifier(runner)
        live[key] = runner
        do {
            try runner.start(onEvent: onEvent, onExit: { [self] status in
                live[key] = nil
                onExit(status)
                notifyIfIdle()
            })
        } catch {
            live[key] = nil
            DispatchQueue.main.async {
                onEvent(.log(error.localizedDescription))
                onExit(-1)
            }
        }
    }

    /// Cancels every running command and calls `completion` once all of them have exited.
    func stopAll(then completion: @escaping () -> Void) {
        shuttingDown = true
        cltTimer?.invalidate()
        downloadTask?.cancel()
        downloadTask = nil
        idleHandlers.append(completion)
        live.values.forEach { $0.cancel() }
        notifyIfIdle()
    }

    private func notifyIfIdle() {
        guard live.isEmpty, !idleHandlers.isEmpty else { return }
        let handlers = idleHandlers
        idleHandlers = []
        handlers.forEach { $0() }
    }

    // MARK: - Helpers

    private static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    /// The bundled sources. Only outside an app bundle (`swift run`) does it fall back to the
    /// repository the executable was built from.
    private static func findSources() -> URL? {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("BuildSources"),
           FileManager.default.fileExists(atPath: bundled.appendingPathComponent("build.sh").path) {
            return bundled
        }
        guard Bundle.main.bundleURL.pathExtension != "app",
              var url = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        while url.path != "/" {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("build.sh").path) { return url }
        }
        return nil
    }

    /// Pipeline messages may start in lower case; the window shows them as sentences.
    static func plain(_ message: String) -> String {
        message.prefix(1).uppercased() + message.dropFirst()
    }
}
