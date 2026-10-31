import AppKit

/// True while the game is running. Its launcher stays alive while the engine runs, so this
/// also covers a race where the launcher is quitting.
public func isNFSIVRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: gameBundleID).isEmpty
}
