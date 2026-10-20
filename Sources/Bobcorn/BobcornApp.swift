import AppKit
import SwiftUI

@main
struct BobcornApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("Bobcorn", id: "main") {
            ContentView()
                .environment(model)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Torrent File…") { model.openTorrentFilePanel() }
                    .keyboardShortcut("o")
                Button("Open Magnet Link…") { model.magnetPromptVisible = true }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Button("Search") {
                    if model.playback == nil {
                        model.selectedFeedTitle = nil
                        model.selectedAPITitle = nil
                        model.searchFocusRequest += 1
                    }
                }
                .keyboardShortcut("f")
            }
            CommandMenu("Browse") {
                ForEach(Array(CatalogSection.allCases.enumerated()), id: \.element) { i, section in
                    Button(section.title) {
                        model.selectedFeedTitle = nil
                        model.selectedAPITitle = nil
                        model.section = section
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
            }
        }

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        MainActor.assumeIsolated { DebugScript.runIfRequested() }
        #endif
    }

    /// magnet: links and .torrent files handed to the app by the system.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            for url in urls { AppModel.shared.open(url: url) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}
