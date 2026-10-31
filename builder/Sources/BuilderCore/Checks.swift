import Foundation

/// The checklist rows, in window order.
public enum CheckID: CaseIterable {
    case mac, commandLineTools, buildTools, downloads, gameCopy, destination, diskSpace
}

/// Grey (checking), green (ready), amber (automatic), red (blocked).
public enum CheckState: Equatable {
    case checking(String)
    case ready(String)
    case automatic(String)
    case blocked(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

public func canBuild(_ states: [CheckID: CheckState]) -> Bool {
    CheckID.allCases.allSatisfy { id in
        switch states[id] {
        case .ready?, .automatic?: return true
        default: return false
        }
    }
}

public func macCheck(isAppleSilicon: Bool, version: OperatingSystemVersion) -> CheckState {
    guard isAppleSilicon else {
        return .blocked("NFSIV Builder needs a Mac with Apple Silicon")
    }
    guard version.majorVersion >= 12 else {
        return .blocked("NFSIV Builder needs macOS 12 or newer. On macOS 11, build from Terminal.")
    }
    return .ready("Apple Silicon, macOS \(version.majorVersion).\(version.minorVersion)")
}

/// Free space the build needs on the workspace and cache volume: the peak of a first build
/// (support folder, cache and installed app, sampled every second: 2.7 GB, or 3.9 GB with
/// community content) plus about 25 percent.
public func requiredFreeBytes(community: Bool) -> Int64 {
    community ? 5_000_000_000 : 3_500_000_000
}

/// The text behind Copy details on a rejected game copy: the plain message, then the non-empty
/// lines the check printed, which include the detected and expected inventory.
public func gameCheckDetails(message: String, log: [String]) -> String {
    ([message] + log.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).joined(separator: "\n")
}

/// Space the installed NFSIV.app takes in the destination (measured 646 MB, or 1,255 MB with
/// community content). On the build's own volume the copy is an APFS clone and costs nothing.
public func appBytes(community: Bool) -> Int64 {
    community ? 1_400_000_000 : 700_000_000
}

/// `available` is the free space of the workspace and cache volume; `destinationAvailable` is
/// the destination's free space when it is on another volume, nil when it is the same one.
public func diskSpaceCheck(available: Int64, community: Bool, destinationAvailable: Int64? = nil) -> CheckState {
    let gb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1_000_000_000) }
    let needed = requiredFreeBytes(community: community)
    guard available >= needed else {
        return .blocked("Only \(gb(available)) free, \(gb(needed)) needed")
    }
    if let destination = destinationAvailable, destination < appBytes(community: community) {
        return .blocked("Only \(gb(destination)) free in the destination, \(gb(appBytes(community: community))) needed")
    }
    return .ready("\(gb(available)) free")
}
