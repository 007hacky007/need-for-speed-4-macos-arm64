import Foundation

/// The pipeline sources the Builder runs from; tools/make_builder.py bundles the same entries.
public let bundledSourceEntries = ["build.sh", "requirements.txt", "tools", "runtime", "launcher", "third_party"]

public struct BuilderPaths {
    /// ~/Library/Application Support/NFSIV Builder: the private Python and one workspace per version.
    public let support: URL
    /// The download cache shared with ./build.sh, passed to every pipeline command with --cache.
    public let cache: URL

    /// `NFSIV_BUILDER_CACHE` and `NFSIV_BUILDER_SUPPORT` (tests and development only) override
    /// the shared cache and the support folder.
    public init(support: URL? = nil, cache: URL? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        func override(_ name: String) -> URL? {
            environment[name].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.support = support ?? override("NFSIV_BUILDER_SUPPORT")
            ?? home.appendingPathComponent("Library/Application Support/NFSIV Builder")
        self.cache = cache ?? override("NFSIV_BUILDER_CACHE") ?? home.appendingPathComponent("Library/Caches/NFSIV")
    }

    public var python: URL { support.appendingPathComponent("python") }
    public var pythonExecutable: URL { python.appendingPathComponent("bin/python3") }

    public func workspace(version: String) -> URL {
        support.appendingPathComponent(version)
    }
}

private let versionMarker = ".builder-version"

/// Copies the pipeline sources into `destination`. A destination whose marker matches
/// `version` and that holds every bundled entry of `sources` is left alone; anything else is
/// replaced atomically.
public func prepareWorkspace(sources: URL, destination: URL, version: String) throws {
    let fm = FileManager.default
    let marker = destination.appendingPathComponent(versionMarker)
    if let current = try? String(contentsOf: marker, encoding: .utf8), current == version,
       bundledSourceEntries.allSatisfy({ !fm.fileExists(atPath: sources.appendingPathComponent($0).path)
           || fm.fileExists(atPath: destination.appendingPathComponent($0).path) }) {
        return
    }

    let parent = destination.deletingLastPathComponent()
    try fm.createDirectory(at: parent, withIntermediateDirectories: true)
    let temp = parent.appendingPathComponent(".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
    do {
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)
        for entry in bundledSourceEntries {
            let from = sources.appendingPathComponent(entry)
            guard fm.fileExists(atPath: from.path) else { continue }
            try fm.copyItem(at: from, to: temp.appendingPathComponent(entry))
        }
        try removePycache(in: temp)
        try removeQuarantine(at: temp)
        try version.write(to: temp.appendingPathComponent(versionMarker), atomically: true, encoding: .utf8)
        let old = fm.fileExists(atPath: destination.path) ? try moveToTrash(destination) : nil
        try fm.moveItem(at: temp, to: destination)
        if let old = old { try? fm.removeItem(at: old) }
    } catch {
        try? fm.removeItem(at: temp)
        throw error
    }
}

/// Renames `url` to a hidden `.trash-<uuid>` sibling in one atomic step and returns that
/// location. A quit while the caller deletes it then never leaves a half-removed directory
/// under the real name; `sweepLeftovers` deletes the rest on the next start.
public func moveToTrash(_ url: URL) throws -> URL {
    let trash = url.deletingLastPathComponent().appendingPathComponent(".trash-\(UUID().uuidString)")
    try FileManager.default.moveItem(at: url, to: trash)
    return trash
}

/// Deletes what interrupted work left in the support folder: `.trash-*` directories and
/// `.<name>.tmp-*` copies. Called on start, before anything else uses the folder.
public func sweepLeftovers(_ paths: BuilderPaths) {
    let fm = FileManager.default
    for name in (try? fm.contentsOfDirectory(atPath: paths.support.path)) ?? []
    where name.hasPrefix(".trash-") || (name.hasPrefix(".") && name.contains(".tmp-")) {
        try? fm.removeItem(at: paths.support.appendingPathComponent(name))
    }
}

private func removePycache(in root: URL) throws {
    let fm = FileManager.default
    guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
    var found: [URL] = []
    for case let url as URL in walker where url.lastPathComponent == "__pycache__" {
        found.append(url)
        walker.skipDescendants()
    }
    for url in found { try fm.removeItem(at: url) }
}

/// Deletes workspaces of other Builder versions: visible siblings in the support folder whose
/// `.builder-version` marker names a different version. The private Python and directories
/// without a marker are never touched.
public func removeOldWorkspaces(_ paths: BuilderPaths, keeping version: String) {
    let fm = FileManager.default
    for name in (try? fm.contentsOfDirectory(atPath: paths.support.path)) ?? []
    where !name.hasPrefix(".") && name != paths.python.lastPathComponent && name != version {
        let dir = paths.support.appendingPathComponent(name)
        guard let marker = try? String(contentsOf: dir.appendingPathComponent(versionMarker), encoding: .utf8),
              marker != version, let trash = try? moveToTrash(dir) else { continue }
        try? fm.removeItem(at: trash)
    }
}

/// The Build tools row. The package environment lives in the shared cache, so its state comes
/// from `builder_cli.py tools status` (`tools`), which needs the private Python to run at all.
public func buildToolsState(pythonInstalled: Bool, tools: PipelineEvent?) -> CheckState {
    guard pythonInstalled else { return .blocked("about 70 MB download") }
    if case .tools(python: _?)? = tools { return .ready("Installed") }
    return .blocked("Packages need to be set up again (small download)")
}

/// The Build tools row after `build_app.py --setup-only --progress` exited with `status` and
/// printed `events`. Ready only when it exited cleanly and reported the package environment.
public func setupResult(status: Int32, events: [PipelineEvent], pythonInstalled: Bool) -> CheckState {
    guard status == 0 else {
        let message = events.compactMap { event -> String? in
            if case let .error(text) = event { return text }
            return nil
        }.last
        return .blocked(message ?? "Could not set up the build tools. Check your internet connection and try again.")
    }
    let tools = events.last { if case .tools = $0 { return true } else { return false } }
    let state = buildToolsState(pythonInstalled: pythonInstalled, tools: tools)
    return state.isReady ? state : .blocked("The build tools are incomplete. Try again.")
}
