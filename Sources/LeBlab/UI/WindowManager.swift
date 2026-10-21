import AppKit
import LeBlabCore
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, transcription, formatting, account, privacy, history, diagnostics
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .transcription: return "waveform"
        case .formatting: return "text.badge.checkmark"
        case .account: return "key"
        case .privacy: return "hand.raised"
        case .history: return "clock.arrow.circlepath"
        case .diagnostics: return "stethoscope"
        }
    }
}

final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .general
}

/// Owns the app's regular windows. Le Blab is a menu-bar app (LSUIElement), so windows must
/// explicitly activate the app to come to the front.
@MainActor
final class WindowManager {
    private weak var coordinator: AppCoordinator?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let navigation = SettingsNavigation()

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func showSettings(tab: SettingsTab) {
        guard let coordinator else { return }
        navigation.tab = tab
        if settingsWindow == nil {
            let root = SettingsView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.settings)
                .environmentObject(coordinator.controller)
                .environmentObject(coordinator.permissions)
                .environmentObject(coordinator.diagnostics)
                .environmentObject(coordinator.history)
                .environmentObject(navigation)
            settingsWindow = makeWindow(title: "Le Blab Settings", size: NSSize(width: 720, height: 560), root: root)
        }
        present(settingsWindow)
    }

    func showOnboarding() {
        guard let coordinator else { return }
        if onboardingWindow == nil {
            let root = OnboardingView()
                .environmentObject(coordinator)
                .environmentObject(coordinator.settings)
                .environmentObject(coordinator.permissions)
            onboardingWindow = makeWindow(title: "Welcome to Le Blab", size: NSSize(width: 560, height: 640), root: root)
        }
        present(onboardingWindow)
    }

    func closeOnboarding() {
        onboardingWindow?.close()
    }

    private func makeWindow<V: View>(title: String, size: NSSize, root: V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: root)
        window.setContentSize(size)
        window.center()
        return window
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        coordinator?.permissions.refresh()
    }
}
