import AppKit
import SwiftUI

struct ResultView: View {
    enum Outcome {
        case success(URL)
        case failure(step: String, message: String, log: [String])
        case quitToInstall
    }

    @ObservedObject var model: BuilderModel
    let outcome: Outcome

    var body: some View {
        switch outcome {
        case let .success(app): success(app)
        case let .failure(step, message, log): failure(step: step, message: message, log: log)
        case .quitToInstall: quitToInstall
        }
    }

    private var quitToInstall: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(Color(NSColor.systemOrange))
            Text("NFSIV is running").font(.title).fontWeight(.semibold)
            Text("Quit NFSIV, then click Install again.")
                .foregroundColor(.secondary)
            Button("Install again", action: model.installAgain)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 430)
    }

    private func success(_ app: URL) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(Color(NSColor.systemGreen))
            Text("Ready").font(.title).fontWeight(.semibold)
            Text("NFSIV.app is in \(app.deletingLastPathComponent().path). Your saves were not changed.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([app]) }
                Button("Play") { NSWorkspace.shared.open(app) }
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            Spacer()
            if model.buildFilesRemoved {
                Text("Build files removed").font(.caption).foregroundColor(.secondary)
            } else {
                Button("Remove build files", action: model.removeBuildFiles)
                    .controlSize(.small)
                    .help("Frees the space used while building. Python and the downloads are kept.")
            }
        }
        .frame(maxWidth: .infinity, minHeight: 430)
    }

    private func failure(step: String, message: String, log: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.system(size: 28))
                    .foregroundColor(Color(NSColor.systemRed))
                Text("\(step) failed").font(.title2).fontWeight(.semibold)
            }
            Text(message).fixedSize(horizontal: false, vertical: true)
            Text("Details").font(.headline).padding(.top, 4)
            LogView(lines: log)
            HStack {
                Button("Copy log") { copyToPasteboard(log.joined(separator: "\n")) }
                Spacer()
                Button("Try again", action: model.tryAgain)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
