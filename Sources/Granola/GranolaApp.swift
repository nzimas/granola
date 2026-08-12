import SwiftUI
import AppKit

@main
struct GranolaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = GranolaModel.shared

    var body: some Scene {
        WindowGroup("Granola") {
            ContentView()
                .environmentObject(model)
                .onAppear {
                    // In self-test mode the delegate has already taken over.
                    if !SelfTest.isRequested { model.start() }
                    // Debug aid: set a non-default grain envelope at launch so
                    // the panel can be checked for showing the real value
                    // rather than the first entry.
                    if let index = CommandLine.arguments.firstIndex(of: "--grain-shape"),
                       CommandLine.arguments.count > index + 1,
                       let raw = Int(CommandLine.arguments[index + 1]),
                       let shape = GranolaEngine.GrainShape(rawValue: raw) {
                        model.setGrainShape(0, shape)
                    }
                    // Debug aid: recall a slot at launch so the panel's
                    // current-slot highlight can be looked at.
                    if let index = CommandLine.arguments.firstIndex(of: "--load-project"),
                       CommandLine.arguments.count > index + 1,
                       let slot = Int(CommandLine.arguments[index + 1]) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            model.loadProject(from: slot)
                        }
                    }
                    // Debug aid: bring the window up already playing, so the
                    // grain animation and the filter can be looked at without
                    // clicking through a file dialogue every time.
                    if let index = CommandLine.arguments.firstIndex(of: "--load"),
                       CommandLine.arguments.count > index + 1 {
                        let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            for track in model.tracks.indices where track < 3 {
                                model.loadSample(url, into: track)
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                model.setParameter(1, .density, value: 90)
                                model.setParameter(1, .grainSize, value: 0.05)
                                model.setParameter(2, .density, value: 4)
                                model.setParameter(2, .grainSize, value: 0.9)
                                model.setParameter(2, .jitter, value: 25)
                                model.playAll()
                            }
                        }
                    }
                }
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1260, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Transport") {
                Button("Play All") { model.playAll() }.keyboardShortcut(.space, modifiers: [])
                Button("Stop All") { model.stopAll() }.keyboardShortcut(".", modifiers: .command)
                Divider()
                Button(model.isRecording ? "Stop Recording" : "Record Output") {
                    model.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button("Rewind All") { model.rewindAll() }
                Button("Scatter Positions") { model.scatter() }
                Button("Randomise Selected") { model.randomiseSelected() }
                Button("Panic") { model.panic() }.keyboardShortcut(.escape, modifiers: [])
            }
        }
    }
}

/// scsynth is a child process, so it has to be torn down explicitly — an
/// orphaned server would hold the audio device after the app quits.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The self-test runs from here rather than from a view's `onAppear`:
    /// launched from a terminal the app may never present a window, and the
    /// test still has to run and report.
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            if SelfTest.isRequested { SelfTest.run(model: .shared) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            GranolaModel.shared.shutdown()
        }
    }
}
