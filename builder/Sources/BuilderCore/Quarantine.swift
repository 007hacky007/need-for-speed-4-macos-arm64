import Foundation

/// Removes com.apple.quarantine from `url` and everything below it, except below `keeping`
/// (left as it is, the folder included).
public func removeQuarantine(at url: URL, keeping: URL? = nil) throws {
    let kept = keeping?.standardizedFileURL.path
    var urls = [url]
    if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
        for case let child as URL in walker {
            if let kept = kept, child.standardizedFileURL.path == kept {
                walker.skipDescendants()
                continue
            }
            urls.append(child)
        }
    }
    for item in urls {
        if removexattr(item.path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0, errno != ENOATTR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}

/// For a built NFSIV.app: everything the build made loses quarantine; the game inside
/// (Contents/Resources/Game, prepared from the player's own copy) keeps it. The game only reads
/// those files, and a download's quarantine stays on what came from it.
public func removeQuarantine(fromBuiltApp app: URL) throws {
    try removeQuarantine(at: app, keeping: app.appendingPathComponent("Contents/Resources/Game"))
}
