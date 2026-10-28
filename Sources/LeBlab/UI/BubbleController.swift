import AppKit
import Combine
import LeBlabCore
import SwiftUI

/// Always-present idle bubble at the bottom of the screen (like Wispr Flow's pill).
///
/// It reacts the instant the shortcut goes down — the pixel bars follow your voice before the full
/// overlay appears — so dictation feels immediate. Hover shows the shortcut; click toggles
/// hands-free dictation. Non-activating: it never takes focus from the app you're typing in.
@MainActor
final class BubbleModel: ObservableObject {
    @Published var listening = false
    @Published var levels: [Float] = Array(repeating: 0, count: 5)
    @Published var hovering = false
    @Published var shortcut = "⌃⇧"
}

@MainActor
final class BubbleController {
    private let panel: OverlayPanel
    private let model = BubbleModel()
    private weak var coordinator: AppCoordinator?
    private var cancellables = Set<AnyCancellable>()
    private var overlayShowing = false

    static let size = NSSize(width: 190, height: 44)

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        panel = OverlayPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.animationBehavior = .none

        // Right-click menu: the menu-bar duck can be hidden behind the notch on a crowded menu bar,
        // so the bubble offers the same essentials.
        let menu = BubbleMenu(
            settings: { [weak coordinator] in coordinator?.windows.showSettings(tab: .general) },
            privacy: { [weak coordinator] in coordinator?.windows.showSettings(tab: .privacy) },
            diagnostics: { [weak coordinator] in coordinator?.windows.showSettings(tab: .diagnostics) },
            toggleFormatting: { [weak coordinator] in
                guard let settings = coordinator?.settings else { return }
                settings.formattingMode = settings.formattingMode == .smart ? .raw : .smart
            },
            isSmart: { [weak coordinator] in coordinator?.settings.formattingMode == .smart },
            copyLast: { [weak coordinator] in coordinator?.copyLastTranscript() },
            hideBubble: { [weak coordinator] in coordinator?.settings.showIdleBubble = false },
            quit: { NSApp.terminate(nil) })
        let view = BubbleView(model: model, menu: menu) { [weak coordinator] in coordinator?.controller.toggleFromMenu() }
        let host = FirstMouseHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = host

        let controller = coordinator.controller
        controller.$isRecording.removeDuplicates().sink { [weak self] recording in
            withAnimation(.spring(response: 0.22, dampingFraction: 0.8)) { self?.model.listening = recording }
            if !recording { self?.model.levels = Array(repeating: 0, count: 5) }
        }.store(in: &cancellables)
        controller.$level.sink { [weak self] level in
            guard let self, self.model.listening else { return }
            var levels = self.model.levels
            levels.removeFirst()
            levels.append(level)
            self.model.levels = levels
        }.store(in: &cancellables)
        coordinator.settings.$hotkey.sink { [weak self] combo in self?.model.shortcut = combo.displayString }
            .store(in: &cancellables)
        coordinator.settings.$showIdleBubble.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }.store(in: &cancellables)
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// The full overlay is showing (it takes over the same spot) or not.
    func setOverlayShowing(_ showing: Bool) {
        overlayShowing = showing
        refresh()
    }

    func refresh() {
        guard let coordinator, coordinator.settings.showIdleBubble, !overlayShowing else {
            panel.orderOut(nil)
            return
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + 14))
        panel.orderFrontRegardless()
    }
}

/// Actions for the bubble's right-click menu (nil = preview/snapshot, no menu).
struct BubbleMenu {
    let settings: () -> Void
    let privacy: () -> Void
    let diagnostics: () -> Void
    let toggleFormatting: () -> Void
    let isSmart: () -> Bool
    let copyLast: () -> Void
    let hideBubble: () -> Void
    let quit: () -> Void
}

struct BubbleView: View {
    @ObservedObject var model: BubbleModel
    var menu: BubbleMenu? = nil
    let onClick: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(model.levels.indices, id: \.self) { i in
                    let lit = model.listening ? max(1, Int((CGFloat(model.levels[i]) * 4).rounded())) : 1
                    VStack(spacing: 1.5) {
                        ForEach((0..<4).reversed(), id: \.self) { row in
                            Rectangle()
                                .fill(row < lit ? PixelBars.color(row: row, rows: 4) : Color.white.opacity(0.10))
                                .frame(width: 3, height: 3)
                        }
                    }
                }
            }
            if model.hovering && !model.listening {
                Text("Hold \(model.shortcut) or click")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LeBlabStyle.secondary)
                    .fixedSize()
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, model.listening ? 12 : 9)
        .padding(.vertical, model.listening ? 7 : 5)
        .background(
            Capsule(style: .continuous)
                .fill(LeBlabStyle.pill.opacity(model.listening || model.hovering ? 0.95 : 0.78))
        )
        .overlay(Capsule(style: .continuous).strokeBorder(Color.white.opacity(model.listening ? 0.22 : 0.10), lineWidth: 0.5))
        .scaleEffect(model.listening ? 1.12 : 1)
        .contentShape(Capsule())
        .onHover { hovering in withAnimation(.easeOut(duration: 0.12)) { model.hovering = hovering } }
        .onTapGesture(perform: onClick)
        .contextMenu {
            if let menu {
                Button("Settings…", action: menu.settings)
                Button("Change Shortcut…", action: menu.settings)
                Button(menu.isSmart() ? "Switch to Raw Transcription" : "Switch to Smart Formatting", action: menu.toggleFormatting)
                Button("Copy Last Transcript", action: menu.copyLast)
                Divider()
                Button("Privacy…", action: menu.privacy)
                Button("Diagnostics…", action: menu.diagnostics)
                Button("Hide Bubble", action: menu.hideBubble)
                Divider()
                Button("Quit Le Blab", action: menu.quit)
            }
        }
        .help("Le Blab — hold \(model.shortcut) to dictate, click for hands-free, right-click for settings")
        .frame(width: BubbleController.size.width, height: BubbleController.size.height, alignment: .bottom)
        .padding(.bottom, 2)
    }
}
