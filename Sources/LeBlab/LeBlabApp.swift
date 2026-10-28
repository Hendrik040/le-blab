import AppKit
import LeBlabCore
import SwiftUI

@main
struct LeBlabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var coordinator = AppCoordinator.shared
    @ObservedObject private var controller = AppCoordinator.shared.controller

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent()
                .environmentObject(coordinator)
                .environmentObject(coordinator.settings)
                .environmentObject(coordinator.controller)
                .environmentObject(coordinator.permissions)
        } label: {
            Group {
                if coordinator.needsAttention && !controller.state.isActive {
                    Image(systemName: "exclamationmark.triangle")
                } else {
                    Image(nsImage: DuckArt.menuBarImage(open: controller.state.isRecordingState))
                }
            }
            .accessibilityLabel("Le Blab")
        }
        .menuBarExtraStyle(.menu)
    }

}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppCoordinator.shared.launch() }
    }

    /// Opening Le Blab again while it runs (Spotlight, Finder, Dock) shows Settings — the way in
    /// when the menu-bar duck is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppCoordinator.shared.windows.showSettings(tab: .general) }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppCoordinator.shared.shutdown() }
    }
}
