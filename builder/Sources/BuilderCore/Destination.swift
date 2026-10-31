import Foundation

public let defaultDestination = URL(fileURLWithPath: "/Applications")
/// The bundle id tools/package.py gives NFSIV.app.
public let gameBundleID = "org.classicgames.nfsiv"

public struct InstallError: LocalizedError {
    public let message: String
    /// Underlying error text, for the log.
    public var details: String? = nil
    public var errorDescription: String? { message }
}

private let unrelatedApp = "This folder has an NFSIV.app that was not built from your game copy. Choose another folder."

/// The bundle id of `directory/NFSIV.app`, nil when there is none; "" when it has no readable id.
func existingBundleID(in directory: URL) -> String? {
    let app = directory.appendingPathComponent("NFSIV.app")
    guard FileManager.default.fileExists(atPath: app.path) else { return nil }
    let plist = app.appendingPathComponent("Contents/Info.plist")
    guard let data = try? Data(contentsOf: plist),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    else { return "" }
    return info["CFBundleIdentifier"] as? String ?? ""
}

public func destinationCheck(_ directory: URL) -> CheckState {
    var isDir: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDir)
    guard exists, isDir.boolValue, FileManager.default.isWritableFile(atPath: directory.path) else {
        return .blocked("Choose a folder you can write to")
    }
    if let id = existingBundleID(in: directory), id != gameBundleID { return .blocked(unrelatedApp) }
    return .ready(directory.path)
}

/// Copies `built` next to the final location, then swaps it in so the old app survives any
/// failure. An NFSIV.app that this project did not build is never replaced.
public func installApp(_ built: URL, into directory: URL, isRunning: () -> Bool) throws -> URL {
    if isRunning() { throw InstallError(message: "Quit NFSIV first, then try again.") }
    if let id = existingBundleID(in: directory), id != gameBundleID {
        throw InstallError(message: unrelatedApp)
    }
    let fm = FileManager.default
    let target = directory.appendingPathComponent("NFSIV.app")
    let staging = directory.appendingPathComponent(".NFSIV.app.installing")
    do {
        if fm.fileExists(atPath: staging.path) { try fm.removeItem(at: staging) }
        try fm.copyItem(at: built, to: staging)
        try removeQuarantine(at: staging)
        var final = target
        if fm.fileExists(atPath: target.path) {
            final = try fm.replaceItemAt(target, withItemAt: staging) ?? target
        } else {
            try fm.moveItem(at: staging, to: target)
        }
        guard fm.fileExists(atPath: final.appendingPathComponent("Contents/Info.plist").path) else {
            throw InstallError(message: "The installed app is incomplete.")
        }
        return final
    } catch {
        try? fm.removeItem(at: staging)
        throw InstallError(
            message: "Could not install NFSIV into \(directory.lastPathComponent). Choose another folder and try again.",
            details: String(describing: error))
    }
}
