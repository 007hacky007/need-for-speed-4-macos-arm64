import Foundation

/// An NFSIV.app this project built, in the saved destination or else in /Applications, for an
/// update: the game inside it can be reused instead of the original game copy. Only read.
public func existingGameApp(destination: URL, fallback: URL = defaultDestination) -> URL? {
    for folder in [destination, fallback] where existingBundleID(in: folder) == gameBundleID {
        return folder.appendingPathComponent("NFSIV.app")
    }
    return nil
}

/// Whether the chosen game source is an app bundle (an update) rather than a game copy.
public func isAppBundle(_ url: URL) -> Bool {
    var isDir: ObjCBool = false
    return url.pathExtension.lowercased() == "app" && FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        && isDir.boolValue
}

/// The NFSIV Builder version that built `app` (its NFSBuilderVersion), nil for a Terminal build.
public func builderStamp(of app: URL) -> String? {
    guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
          let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let stamp = info["NFSBuilderVersion"] as? String, !stamp.isEmpty
    else { return nil }
    return stamp
}

/// The build button: "Update NFSIV.app (0.1.0 -> 0.2.0)" when the game source is an existing app.
public func buildButtonTitle(source: URL?, builderVersion: String) -> String {
    guard let app = source, isAppBundle(app) else { return "Build NFSIV.app" }
    guard let old = builderStamp(of: app) else { return "Update NFSIV.app" }
    return "Update NFSIV.app (\(old) -> \(builderVersion))"
}

/// The game row's note when the app found on start cannot be reused.
public let existingAppUnusable = "The game inside NFSIV.app is missing or changed, so it cannot be reused. Choose your game copy."
