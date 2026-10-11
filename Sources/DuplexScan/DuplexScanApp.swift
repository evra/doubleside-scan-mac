import AppKit
import SwiftUI

@main
struct DuplexScanApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var drive: GoogleDrive
    @StateObject private var session: ScanSession
    @StateObject private var scanners = ScannerList()

    init() {
        ScanSettings.registerDefaults()
        StdoutTap.shared.start()
        let drive = GoogleDrive()
        _drive = StateObject(wrappedValue: drive)
        _session = StateObject(wrappedValue: ScanSession(drive: drive))
    }

    var body: some Scene {
        Window("Duplex Scan", id: "main") {
            ContentView()
                .environmentObject(session)
                .environmentObject(drive)
                .onAppear { scanners.start() }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Scan") { session.start() }
                    .keyboardShortcut("n")
                    .disabled(session.isBusy)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(drive)
                .environmentObject(scanners)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare SwiftPM executable rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        if Bundle.main.bundleIdentifier == nil {
            // Unbundled runs (swift run / VS Code) have no Info.plist icon; use the one from the source tree.
            let icon = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/AppIcon.png")
            NSApp.applicationIconImage = NSImage(contentsOf: icon)
        }
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
