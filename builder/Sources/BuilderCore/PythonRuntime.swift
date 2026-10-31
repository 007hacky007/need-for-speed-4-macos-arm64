import Foundation
import CryptoKit

struct PythonInstallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func sha256Hex(of url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

public enum PythonRuntime {
    // python-build-standalone release 20261026, CPython 3.12.16; hash from that release's SHA256SUMS.
    public static let url = URL(string: "https://github.com/astral-sh/python-build-standalone/releases/download/20261026/cpython-3.12.16%2B20261026-aarch64-apple-darwin-install_only.tar.gz")!
    public static let sha256 = "fbf4afef53c2a6b72bb741bc06d5671a9dfaf87bd84e5aa73ac9b3d0d589f14e"

    static let markerName = ".nfsiv-python-sha256"

    /// True when the pinned build is installed: the executable exists and the marker matches the pin.
    public static func isInstalled(_ paths: BuilderPaths) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: paths.pythonExecutable.path),
              let marker = try? String(contentsOf: paths.python.appendingPathComponent(markerName), encoding: .utf8)
        else { return false }
        return marker.trimmingCharacters(in: .whitespacesAndNewlines) == sha256
    }

    /// The archive handed to `done` by `download` must stay valid until `done` returns; the
    /// installer verifies and unpacks it synchronously inside `done` and then deletes it (it
    /// takes ownership). `completion` is always delivered on the main queue.
    public static func install(_ paths: BuilderPaths,
                               sha256 expected: String = PythonRuntime.sha256,
                               download: (URL, @escaping (Result<URL, Error>) -> Void) -> Void,
                               completion: @escaping (Result<Void, Error>) -> Void) {
        download(url) { result in
            let outcome: Result<Void, Error>
            switch result {
            case .failure(let error):
                outcome = .failure(error)
            case .success(let file):
                outcome = Result { try finishInstall(paths, archive: file, expected: expected) }
            }
            if Thread.isMainThread {
                completion(outcome)
            } else {
                DispatchQueue.main.async { completion(outcome) }
            }
        }
    }

    private static func finishInstall(_ paths: BuilderPaths, archive: URL, expected: String) throws {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: archive) }

        guard try sha256Hex(of: archive) == expected.lowercased() else {
            throw PythonInstallError(message: "The downloaded Python failed its checksum, so it was discarded")
        }

        try fm.createDirectory(at: paths.support, withIntermediateDirectories: true)
        let temp = paths.support.appendingPathComponent(".python.tmp-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        try fm.createDirectory(at: temp, withIntermediateDirectories: true)

        let tar = SystemCommandRunner().run("/usr/bin/tar", ["-xzf", archive.path, "-C", temp.path])
        guard tar.status == 0 else {
            throw PythonInstallError(message: "Could not unpack Python: \(tar.output)")
        }
        let extracted = temp.appendingPathComponent("python")
        guard fm.isExecutableFile(atPath: extracted.appendingPathComponent("bin/python3").path) else {
            throw PythonInstallError(message: "The Python download did not contain python/bin/python3")
        }
        try removeQuarantine(at: extracted)
        try expected.lowercased().write(to: extracted.appendingPathComponent(markerName), atomically: true, encoding: .utf8)
        // The old Python is renamed aside first, so a quit mid-delete never leaves half of it.
        let previous = fm.fileExists(atPath: paths.python.path) ? try moveToTrash(paths.python) : nil
        try fm.moveItem(at: extracted, to: paths.python)
        if let previous = previous { try? fm.removeItem(at: previous) }
    }
}
