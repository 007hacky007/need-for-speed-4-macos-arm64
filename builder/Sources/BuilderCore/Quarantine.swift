import Foundation

/// Removes com.apple.quarantine from `url` and everything below it.
public func removeQuarantine(at url: URL) throws {
    var urls = [url]
    if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
        for case let child as URL in walker { urls.append(child) }
    }
    for item in urls {
        if removexattr(item.path, "com.apple.quarantine", XATTR_NOFOLLOW) != 0, errno != ENOATTR {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
