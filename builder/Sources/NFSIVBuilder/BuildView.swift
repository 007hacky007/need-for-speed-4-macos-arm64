import AppKit
import BuilderCore
import SwiftUI

/// Plain names for the pipeline steps, in `buildSteps` order.
let buildStepNames = [
    "extract": "Extract the disc image",
    "verify": "Check the game files",
    "setup": "Set up the build tools",
    "dependencies": "Fetch the build dependencies",
    "prepare": "Prepare the game with VEG Modern Patch",
    "community": "Add community cars and tracks",
    "translate": "Translate the game to C",
    "compile": "Compile",
    "package": "Package and sign",
]

struct BuildView: View {
    @ObservedObject var model: BuilderModel
    let stepID: String
    let fraction: Double
    let log: [String]
    @State private var showDetails = false

    private var buildSteps: [(id: String, weight: Double)] { BuilderCore.buildSteps(community: model.buildCommunity) }
    private var currentIndex: Int? { buildSteps.firstIndex { $0.id == stepID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Building NFSIV.app")
                .font(.title2)
                .fontWeight(.semibold)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(buildSteps.enumerated()), id: \.offset) { index, step in
                    StepRow(name: buildStepNames[step.id] ?? step.id, status: status(of: index))
                }
            }
            ProgressView(value: fraction)
            DisclosureGroup("Show details", isExpanded: $showDetails) {
                LogView(lines: log)
            }
            HStack {
                Spacer()
                Button("Cancel", action: model.cancelBuild)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.cancelDisabled)
            }
        }
    }

    private func status(of index: Int) -> StepRow.Status {
        guard let current = currentIndex else { return .pending }
        if index < current { return .done }
        return index == current ? .current : .pending
    }
}

struct StepRow: View {
    enum Status { case done, current, pending }
    let name: String
    let status: Status

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 18)
            Text(name)
                .fontWeight(status == .current ? .semibold : .regular)
                .foregroundColor(status == .pending ? .secondary : .primary)
        }
    }

    private var icon: String {
        switch status {
        case .done: return "checkmark.circle.fill"
        case .current: return "arrow.right.circle.fill"
        case .pending: return "circle"
        }
    }

    private var color: Color {
        switch status {
        case .done: return Color(NSColor.systemGreen)
        case .current: return .accentColor
        case .pending: return .secondary
        }
    }
}

/// The pipeline output, scrolled to the end. Only the tail is drawn; Copy log copies everything.
struct LogView: View {
    let lines: [String]
    private static let shownLines = 500

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(lines.suffix(Self.shownLines).joined(separator: "\n"))
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .frame(height: 170)
            .background(Color(NSColor.textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color(NSColor.separatorColor)))
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: lines.count) { _ in proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}
