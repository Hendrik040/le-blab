import AppKit
import Combine
import LeBlabCore
import SwiftUI

/// A panel that can never become key or main, so the app receiving dictated text keeps focus.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Lets buttons in the (non-key) overlay respond to the first click.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class OverlayModel: ObservableObject {
    @Published var state: DictationState = .idle
    @Published var levels: [Float] = Array(repeating: 0, count: 9)
    @Published var level: Float = 0
    @Published var startedAt: Date?
    @Published var stateChangedAt = Date()
    @Published var language: String?
    /// The duck pops up from behind the pill when dictation starts.
    @Published var duckUp = false
    var showPreview = true
}

@MainActor
final class OverlayController {
    private let panel: OverlayPanel
    let model = OverlayModel()
    private weak var coordinator: AppCoordinator?
    private var cancellables = Set<AnyCancellable>()
    private var visible = false

    static let width: CGFloat = 470
    /// Room above the pill for the duck.
    static let duckArea: CGFloat = 64

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        panel = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none

        let root = OverlayView(model: model,
                               onCopy: { [weak coordinator] in coordinator?.copyLastTranscript(); coordinator?.controller.dismiss() },
                               onRetry: { [weak coordinator] in coordinator?.controller.retry() },
                               onDismiss: { [weak coordinator] in coordinator?.controller.dismiss() })
        let host = FirstMouseHostingView(rootView: root)
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = host

        coordinator.controller.$level
            .receive(on: RunLoop.main)
            .sink { [weak self] level in self?.push(level: level) }
            .store(in: &cancellables)
        coordinator.controller.$detectedLanguage
            .sink { [weak self] in self?.model.language = $0 }
            .store(in: &cancellables)
    }

    func update(state: DictationState) {
        model.showPreview = coordinator?.settings.showLivePreview ?? true
        if case .recording = state, !model.state.isRecordingState {
            model.startedAt = Date()
        }
        if Self.kind(of: state) != Self.kind(of: model.state) { model.stateChangedAt = Date() }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) { model.state = state }

        switch state {
        case .notInserted, .failed: panel.ignoresMouseEvents = false
        default: panel.ignoresMouseEvents = true
        }

        if state == .idle { hide() } else { show(height: Self.height(for: state)) }
    }

    private static func kind(of state: DictationState) -> Int {
        switch state {
        case .idle: return 0
        case .recording: return 1
        case .processing: return 2
        case .inserted: return 3
        case .notInserted: return 4
        case .failed: return 5
        case .hint: return 6
        }
    }

    private func push(level: Float) {
        guard model.state.isRecordingState else { return }
        var levels = model.levels
        levels.removeFirst()
        levels.append(level)
        model.levels = levels
        model.level = level
    }

    static func pillHeight(for state: DictationState) -> CGFloat {
        switch state {
        case .notInserted, .failed: return 92
        default: return 60
        }
    }

    static func height(for state: DictationState) -> CGFloat { pillHeight(for: state) + duckArea + 16 }

    private func show(height: CGFloat) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? NSScreen.screens[0]
        let visibleFrame = screen.visibleFrame
        let frame = NSRect(x: visibleFrame.midX - Self.width / 2, y: visibleFrame.minY + 20, width: Self.width, height: height)
        panel.setFrame(frame, display: true)
        if !visible {
            visible = true
            panel.alphaValue = 0
            model.duckUp = false
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
            // The duck pops up from behind the pill a beat after it appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                withAnimation(.spring(response: 0.38, dampingFraction: 0.55)) { self?.model.duckUp = true }
            }
        }
    }

    private func hide() {
        guard visible else { return }
        visible = false
        withAnimation(.easeIn(duration: 0.15)) { model.duckUp = false }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.visible else { return }
                self.panel.orderOut(nil)
                self.model.startedAt = nil
                self.model.levels = Array(repeating: 0, count: self.model.levels.count)
            }
        })
    }
}

extension DictationState {
    var isRecordingState: Bool {
        if case .recording = self { return true }
        return false
    }
}

enum LeBlabStyle {
    static let pill = Color(red: 0.086, green: 0.075, blue: 0.063)
    static let text = Color(red: 1.0, green: 0.98, blue: 0.94)
    static let secondary = Color(red: 1.0, green: 0.98, blue: 0.94).opacity(0.62)
    static let tertiary = Color(red: 1.0, green: 0.98, blue: 0.94).opacity(0.38)
    static let accent = Color(red: 1.0, green: 0.510, blue: 0.020)
}

struct OverlayView: View {
    @ObservedObject var model: OverlayModel
    let onCopy: () -> Void
    let onRetry: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: -3) {
            Spacer(minLength: 0)
            // Duck stands on the pill's top edge; while hidden it sits below this clip line, behind the pill.
            HStack {
                AnimatedDuck(state: model.state, level: model.level, stateChangedAt: model.stateChangedAt)
                    .frame(width: 72, height: 64)
                    .offset(y: model.duckUp ? 0 : 70)
                    .padding(.leading, 14)
                Spacer()
            }
            .frame(height: OverlayController.duckArea, alignment: .bottom)
            .clipped()

            pill
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
        .frame(width: OverlayController.width)
    }

    private var pill: some View {
        content
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, minHeight: OverlayController.pillHeight(for: model.state) - 8, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LeBlabStyle.pill.opacity(0.94))
                    .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
            )
            .overlay(alignment: .top) {
                // Mistral-style gradient strip along the top edge.
                HStack(spacing: 0) {
                    ForEach(Array(DuckSprite.gradient.enumerated()), id: \.offset) { _, ink in
                        Rectangle().fill(ink.color ?? .orange)
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 18)
                .opacity(model.state.isRecordingState ? 1 : 0.55)
            }
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5)
            )
            .foregroundStyle(LeBlabStyle.text)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            Color.clear.frame(height: 1)
        case .recording(let preview):
            HStack(spacing: 14) {
                PixelBars(levels: model.levels)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview.isEmpty || !model.showPreview ? "Listening… blab away" : preview)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(preview.isEmpty ? LeBlabStyle.secondary : LeBlabStyle.text)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Text("esc to cancel" + (model.language.map { " · \($0.uppercased())" } ?? ""))
                        .font(.system(size: 10))
                        .foregroundStyle(LeBlabStyle.tertiary)
                }
                Spacer(minLength: 4)
                if let started = model.startedAt {
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(Self.elapsed(from: started, to: context.date))
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(LeBlabStyle.accent)
                    }
                }
            }
        case .processing(let preview):
            HStack(spacing: 12) {
                ProgressView().controlSize(.small).tint(LeBlabStyle.accent)
                Text(preview.isEmpty || !model.showPreview ? "Quacking it into words…" : preview)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LeBlabStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Spacer(minLength: 0)
            }
        case .inserted(let text, _, let latency):
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 17)).foregroundStyle(LeBlabStyle.accent)
                Text(text).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if let latency {
                    Text(DiagnosticsService.format(latency)).font(.system(size: 10).monospacedDigit()).foregroundStyle(LeBlabStyle.tertiary)
                }
            }
        case .notInserted(let text, let reason, let copied):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: copied ? "doc.on.clipboard.fill" : "text.badge.xmark")
                        .font(.system(size: 16)).foregroundStyle(Color.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(text).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                        Text(reason).font(.system(size: 10)).foregroundStyle(LeBlabStyle.secondary).lineLimit(2)
                    }
                }
                HStack {
                    Spacer()
                    Button("Copy", action: onCopy).controlSize(.small)
                    Button("Dismiss", action: onDismiss).controlSize(.small)
                }
            }
        case .failed(let message, let canRetry):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 16)).foregroundStyle(LeBlabStyle.accent)
                    Text(message).font(.system(size: 12)).lineLimit(3)
                }
                HStack {
                    Spacer()
                    if canRetry { Button("Retry", action: onRetry).controlSize(.small) }
                    Button("Dismiss", action: onDismiss).controlSize(.small)
                }
            }
        case .hint(let text):
            HStack(spacing: 12) {
                Image(systemName: "info.circle").font(.system(size: 16)).foregroundStyle(LeBlabStyle.secondary)
                Text(text).font(.system(size: 12)).foregroundStyle(LeBlabStyle.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
        }
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
