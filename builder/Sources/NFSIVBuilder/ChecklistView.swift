import AppKit
import BuilderCore
import SwiftUI
import UniformTypeIdentifiers

struct ChecklistView: View {
    @ObservedObject var model: BuilderModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(CheckID.allCases, id: \.self) { id in
                CheckRow(title: id.title, state: model.states[id] ?? .checking("Checking..."), buttons: buttons(for: id))
                if id != CheckID.allCases.last { Divider() }
            }
            Divider()
            Toggle(isOn: Binding(get: { model.community }, set: model.setCommunity)) {
                (Text("Include community cars and tracks").fontWeight(.semibold)
                    + Text(" - 70 cars, 30 replacement tracks and pursuit traffic from the High Stakes Expansion Pack "
                        + "(extra 170 MB download, about 1 GB more disk). Your saves are kept either way."))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .toggleStyle(.checkbox)
            .padding(.vertical, 10)
            Button(action: model.build) {
                Text("Build NFSIV.app")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.buildEnabled)
            .padding(.top, 8)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 3)
                .padding(-10)
                .opacity(dropTargeted ? 1 : 0)
        )
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: drop)
        .sheet(isPresented: $model.showingSupported) { SupportedSheet(model: model) }
    }

    private func buttons(for id: CheckID) -> [RowButton] {
        let state = model.states[id]
        switch (id, state) {
        case (.commandLineTools, .blocked?):
            return [RowButton(label: "Install...", action: model.installCommandLineTools)]
        case (.buildTools, .blocked?):
            let install = RowButton(label: "Install", action: model.installBuildTools)
            guard let details = model.setupDetails else { return [install] }
            return [RowButton(label: "Copy details", action: { copyToPasteboard(details) }), install]
        case (.downloads, .automatic?) where model.pythonReady:
            return [RowButton(label: "Download", action: model.fetchDownloads)]
        case (.downloads, .blocked?) where model.pythonReady:
            return [RowButton(label: "Download again", action: model.fetchDownloads)]
        case (.gameCopy, .blocked?) where model.gameDetails != nil:
            let details = model.gameDetails.map { text in [RowButton(label: "Copy details", action: { copyToPasteboard(text) })] }
            let sheet = model.gameRejection?.offersSupportedCopies == true
                ? [RowButton(label: "Which copy works?", action: { model.showingSupported = true })] : []
            return (details ?? []) + sheet + [RowButton(label: "Choose...", action: chooseGame)]
        case (.gameCopy, _):
            return [RowButton(label: "Choose...", action: chooseGame)]
        case (.destination, _):
            return [RowButton(label: "Change...", action: chooseDestination)]
        default:
            return []
        }
    }

    private func chooseGame() {
        let panel = NSOpenPanel()
        panel.message = "Choose your game folder, or its .iso, .bin, .img, .cue or .ccd disc image"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = BuilderModel.gameExtensions.compactMap { UTType(filenameExtension: $0) } + [.folder]
        if let current = model.gamePath { panel.directoryURL = current.deletingLastPathComponent() }
        if panel.runModal() == .OK, let url = panel.url { model.setGame(url) }
    }

    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.message = "Choose where to put NFSIV.app"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = model.destination
        if panel.runModal() == .OK, let url = panel.url { model.setDestination(url) }
    }

    /// Any dropped item goes to the model, which explains why one cannot be used (a .sub file, say).
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard model.phase == .checklist, let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url = (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (item as? URL)
            guard let url = url, url.isFileURL else { return }
            DispatchQueue.main.async { model.setGame(url) }
        }
        return true
    }
}

struct RowButton {
    let label: String
    let action: () -> Void
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

struct CheckRow: View {
    let title: String
    let state: CheckState
    let buttons: [RowButton]

    /// Up to two buttons sit beside the message; more go on their own line below it, so the
    /// message keeps the width it needs.
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(state.color)
                .frame(width: 12, height: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.semibold)
                Text(BuilderModel.plain(state.message))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if buttons.count > 2 {
                    HStack { buttonViews }.padding(.top, 6)
                }
            }
            Spacer(minLength: 8)
            if buttons.count <= 2 { buttonViews }
        }
        .padding(.vertical, 9)
    }

    private var buttonViews: some View {
        ForEach(buttons, id: \.label) { button in
            Button(button.label, action: button.action)
        }
    }
}

extension CheckID {
    var title: String {
        switch self {
        case .mac: return "Mac"
        case .commandLineTools: return "Xcode command line tools"
        case .buildTools: return "Build tools (Python)"
        case .downloads: return "Downloads"
        case .gameCopy: return "Game copy"
        case .destination: return "Destination"
        case .diskSpace: return "Free disk space"
        }
    }
}

extension CheckState {
    var message: String {
        switch self {
        case let .checking(text), let .ready(text), let .automatic(text), let .blocked(text): return text
        }
    }

    var color: Color {
        switch self {
        case .checking: return Color(NSColor.systemGray)
        case .ready: return Color(NSColor.systemGreen)
        case .automatic: return Color(NSColor.systemOrange)
        case .blocked: return Color(NSColor.systemRed)
        }
    }
}
