import Foundation

/// The file count, total size and aggregate SHA-256 the pipeline measured for a game copy.
public struct Inventory: Codable, Equatable {
    public let files: Int
    public let bytes: Int64
    public let sha256: String

    public init(files: Int, bytes: Int64, sha256: String) {
        self.files = files
        self.bytes = bytes
        self.sha256 = sha256
    }
}

/// One user-supplied check of the accepted release, exactly as tools/game_source.py states it.
public struct Requirement: Codable, Equatable {
    public let what: String
    public let files: Int?
    public let bytes: Int64
    public let sha256: String
}

/// The accepted release, as `builder_cli.py supported` reports it from tools/game_source.py.
/// The Builder holds no checksum values of its own.
public struct SupportedRelease: Codable, Equatable {
    public let release: String
    public let languages: String
    public let assets: Requirement
    public let icon: Requirement
    public let inputs: String
    public let note: String

    public static let otherRegions = "Other regions, for example the North American High Stakes CD, are not supported yet."

    /// The sheet as plain text for Copy (for a bug report), with exact byte counts.
    public func plainText(detected: Inventory?) -> String {
        func line(_ item: Requirement) -> String {
            let files = item.files.map { "\($0) files, " } ?? ""
            return "- \(item.what): \(files)\(item.bytes) bytes, SHA-256 \(item.sha256)"
        }
        var lines = ["Which copy works?", release, languages, line(assets), line(icon)]
        if let copy = detected {
            lines.append("Your copy: \(copy.files) files, \(copy.bytes) bytes, SHA-256 \(copy.sha256)")
        }
        lines += ["Accepted inputs: \(inputs)", note, Self.otherRegions]
        return lines.joined(separator: "\n")
    }
}

/// Why the pipeline refused a game copy, in one plain sentence.
public struct GameRejection: Equatable {
    public let reason: String
    public let message: String
    public let detected: Inventory?

    public init(reason: String, message: String, detected: Inventory?) {
        self.reason = reason
        self.message = message
        self.detected = detected
    }

    /// Rejections where showing the accepted release helps: a wrong or incomplete copy.
    public var offersSupportedCopies: Bool { ["assets", "not-game", "icon-missing", "icon"].contains(reason) }
}

public enum DownloadsState: Equatable {
    case ready, missing, damaged(String)
}

public enum PipelineEvent: Equatable {
    case step(id: String, title: String)
    case done(URL)
    case error(String)
    case rejected(GameRejection)
    case game(version: String)
    case tools(python: String?)
    case downloads(DownloadsState)
    case supported(SupportedRelease)
    case log(String)
}

public let eventPrefix = "NFSIV-EVENT "

/// One output line as an event. Lines without the prefix, malformed JSON and unknown shapes are log text.
public func parsePipelineLine(_ line: String) -> PipelineEvent {
    guard line.hasPrefix(eventPrefix),
          let data = String(line.dropFirst(eventPrefix.count)).data(using: .utf8),
          let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return .log(line) }

    if let id = obj["step"] as? String, let title = obj["title"] as? String {
        return .step(id: id, title: title)
    }
    if let path = obj["done"] as? String { return .done(URL(fileURLWithPath: path)) }
    if let message = obj["error"] as? String {
        guard let reason = obj["reason"] as? String else { return .error(message) }
        let detected = obj["detected"].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
            .flatMap { try? JSONDecoder().decode(Inventory.self, from: $0) }
        return .rejected(GameRejection(reason: reason, message: message, detected: detected))
    }
    if obj["game"] as? String == "ok", let version = obj["version"] as? String {
        return .game(version: obj["summary"] as? String ?? version)
    }
    switch obj["tools"] as? String {
    case "ready"?: if let python = obj["python"] as? String { return .tools(python: python) }
    case "missing"?: return .tools(python: nil)
    default: break
    }
    switch obj["downloads"] as? String {
    case "ready"?: return .downloads(.ready)
    case "missing"?: return .downloads(.missing)
    case "damaged"?: if let file = obj["file"] as? String { return .downloads(.damaged(file)) }
    default: break
    }
    if let value = obj["supported"], let json = try? JSONSerialization.data(withJSONObject: value),
       let release = try? JSONDecoder().decode(SupportedRelease.self, from: json) {
        return .supported(release)
    }
    return .log(line)
}
