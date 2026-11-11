import AppKit
import SwiftUI

@main
struct ShareManApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("ShareMan") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 760, minHeight: 460)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Scanner le réseau") {
                    Task { await model.scan() }
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(model.isScanning)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when the binary runs outside an .app bundle (e.g. `swift run`).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
