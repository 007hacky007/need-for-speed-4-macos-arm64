import BuilderCore
import SwiftUI

/// "Which copy works?": the accepted release with its file count, size and SHA-256 values, all
/// as the pipeline reports them, next to what the rejected copy measured.
struct SupportedSheet: View {
    @ObservedObject var model: BuilderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Which copy works?").font(.title2).fontWeight(.semibold)
            if let release = model.supported {
                VStack(alignment: .leading, spacing: 2) {
                    Text(release.release).fontWeight(.semibold)
                    Text(release.languages).foregroundColor(.secondary)
                }
                requirement(release.assets, yours: model.gameRejection?.detected)
                requirement(release.icon, yours: nil)
                Text("Accepted: \(release.inputs)").fixedSize(horizontal: false, vertical: true)
                Text("\(release.note) \(SupportedRelease.otherRegions)")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.supportedFailed {
                Text("Could not load the supported copy. Install the build tools, then try again.")
                    .foregroundColor(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            HStack {
                Spacer()
                if let release = model.supported {
                    Button("Copy") { copyToPasteboard(release.plainText(detected: model.gameRejection?.detected)) }
                }
                Button("Done") { model.showingSupported = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: model.loadSupported)
    }

    private func requirement(_ item: Requirement, yours: Inventory?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.what).fontWeight(.semibold)
            Text(([item.files.map { "\($0.formatted()) files" }, size(item.bytes)].compactMap { $0 }).joined(separator: ", "))
            Text(item.sha256)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundColor(.secondary)
            if let copy = yours {
                Text("Your copy: \(copy.files.formatted()) files, \(size(copy.bytes))")
                    .foregroundColor(Color(NSColor.systemRed))
                Text(copy.sha256)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.leading, 12)
    }

    private func size(_ bytes: Int64) -> String {
        "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) (\(bytes.formatted()) bytes)"
    }
}
