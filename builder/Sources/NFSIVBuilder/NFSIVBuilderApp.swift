import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = BuilderModel()
    private var terminateSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when started with `swift run`, where there is no app bundle to say so.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        // The pipeline runs in its own process group, so a plain SIGTERM to the Builder would
        // orphan it; route the signal through the normal quit path instead. terminate(_:) is
        // started from the run loop, not from inside a main-queue block: while it waits for the
        // pipeline to exit, the runner's main-queue callbacks must still be able to run.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [self] in RunLoop.main.perform { self.quit() } }
        source.resume()
        terminateSignal = source
        // Quit Apple Events (logout, restart, `osascript ... quit`) take the same path as Cmd-Q.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleQuit(_:reply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEQuitApplication))
        model.start()
    }

    /// NSApp.terminate returns without quitting while a sheet is attached, so close any sheet first.
    func quit() {
        model.showingSupported = false
        for window in NSApp.windows {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
        }
        RunLoop.main.perform { NSApp.terminate(nil) }
    }

    @objc private func handleQuit(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        quit()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.refresh()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Closing the window or quitting during a build first stops the pipeline and waits for it to exit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.hasRunningWork else { return .terminateNow }
        var replied = false
        let reply = {
            guard !replied else { return }
            replied = true
            sender.reply(toApplicationShouldTerminate: true)
        }
        model.stopAll(then: reply)
        // PipelineRunner escalates to SIGKILL after 5 s; never hang the quit beyond that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: reply)
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopAll(then: {})
    }
}

@main
struct NFSIVBuilderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("NFSIV Builder") {
            RootView(model: delegate.model)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appTermination) {
                Button("Quit NFSIV Builder") { delegate.quit() }.keyboardShortcut("q")
            }
        }
    }
}

struct RootView: View {
    @ObservedObject var model: BuilderModel

    var body: some View {
        Group {
            switch model.phase {
            case .checklist:
                ChecklistView(model: model)
            case let .building(stepID, fraction, log):
                BuildView(model: model, stepID: stepID, fraction: fraction, log: log)
            case let .finished(app):
                ResultView(model: model, outcome: .success(app))
            case let .failed(step, message, log):
                ResultView(model: model, outcome: .failure(step: step, message: message, log: log))
            case .quitToInstall:
                ResultView(model: model, outcome: .quitToInstall)
            }
        }
        .alert(isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Alert(title: Text(model.notice ?? ""))
        }
        .padding(20)
        .frame(width: 560)
        .frame(minHeight: 540, alignment: .top)
        .background(GrowWindowToFit(content: "\(model.states)\(model.gameDetails ?? "")\(model.community)"))
    }
}

/// Grows the window when its content no longer fits, for example when a checklist message
/// wraps after a check finishes; SwiftUI does not enlarge a window that is already open.
/// `content` only changes when the layout may have, which makes SwiftUI call the update.
struct GrowWindowToFit: NSViewRepresentable {
    let content: String

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window, let root = window.contentView else { return }
            let missing = root.fittingSize.height - root.frame.height
            guard missing > 0.5 else { return }
            var frame = window.frame
            frame.origin.y -= missing
            frame.size.height += missing
            window.setFrame(frame, display: true, animate: true)
        }
    }
}
