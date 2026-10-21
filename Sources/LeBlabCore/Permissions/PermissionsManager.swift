import AppKit
import ApplicationServices
import AVFoundation

/// Tracks the two permissions Le Blab needs. Input Monitoring is not required:
/// the event-tap hotkey runs under the Accessibility grant.
@MainActor
public final class PermissionsManager: ObservableObject {
    public enum Status: String, Sendable { case granted, denied, notDetermined }

    @Published public private(set) var microphone: Status = .notDetermined
    @Published public private(set) var accessibility: Status = .notDetermined

    /// Fires when Accessibility flips (the hotkey backend is re-evaluated).
    public var onAccessibilityChange: ((Bool) -> Void)?
    private var pollTimer: Timer?

    public init() { refresh() }

    public var allGranted: Bool { microphone == .granted && accessibility == .granted }

    public func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .denied, .restricted: microphone = .denied
        case .notDetermined: microphone = .notDetermined
        @unknown default: microphone = .notDetermined
        }
        let trusted: Status = AXIsProcessTrusted() ? .granted : .denied
        if trusted != accessibility {
            let changed = accessibility != .notDetermined || trusted == .granted
            accessibility = trusted
            if changed { onAccessibilityChange?(trusted == .granted) }
        }
    }

    public func requestMicrophone() async -> Bool {
        if microphone == .granted { return true }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        refresh()
        return granted
    }

    /// Shows the system prompt that deep-links into Accessibility settings. Does not grant anything itself.
    public func promptAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        startPolling()
    }

    public func openMicrophoneSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        startPolling()
    }

    public func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        startPolling()
    }

    /// Accessibility changes don't post a notification; poll briefly after sending the user to Settings.
    public func startPolling(for seconds: TimeInterval = 120) {
        pollTimer?.invalidate()
        let deadline = Date().addingTimeInterval(seconds)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.refresh()
                if self.allGranted || Date() > deadline { timer.invalidate() }
            }
        }
    }
}
