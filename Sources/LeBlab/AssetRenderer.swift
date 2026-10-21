import AppKit
import LeBlabCore
import SwiftUI

/// `--render-assets <dir>`: writes the app iconset and offscreen snapshots of the overlay states
/// (no screen capture involved), then quits.
@MainActor
enum AssetRenderer {
    static func run(into dir: String) {
        let base = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

        // App icon: cream tile, happy duck mid-quack.
        let iconset = base.appendingPathComponent("AppIcon.iconset")
        try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        let pose = DuckPose(mood: .listening, beakOpen: 0.7, soundLevel: 0.8, frame: 0)
        let cream = NSColor(red: 1.0, green: 0.973, blue: 0.894, alpha: 1)
        for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                           ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
            let pixel = max(1, px / 44)
            let tile = DuckArt.image(pose: pose, pixelSize: 24, background: cream, cornerRadius: 1024 * 0.2237, padding: 0)
            let sized = NSImage(size: NSSize(width: px, height: px))
            sized.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = px >= 128 ? .none : .high
            // Inset like Apple's icon grid (≈10% margin), then draw the tile.
            let inset = CGFloat(px) * 0.09
            let rect = NSRect(x: inset, y: inset, width: CGFloat(px) - inset * 2, height: CGFloat(px) - inset * 2)
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: px, height: px).fill()
            let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)
            cream.setFill()
            path.fill()
            let duck = DuckArt.image(pose: pose, pixelSize: max(pixel, 1) * 8, background: nil)
            let duckSide = rect.width * 0.86
            duck.draw(in: NSRect(x: rect.midX - duckSide / 2, y: rect.minY + rect.height * 0.05, width: duckSide, height: duckSide))
            sized.unlockFocus()
            _ = tile
            write(sized, to: iconset.appendingPathComponent("icon_\(name).png"))
        }

        // Overlay states.
        let states: [(String, DictationState, Float)] = [
            ("1-recording", .recording(preview: "Hey David, I just wanted to check if we can move the meeting"), 0.7),
            ("2-recording-quiet", .recording(preview: ""), 0.05),
            ("3-processing", .processing(preview: "Hey David, I just wanted to check if we can move the meeting to Friday"), 0),
            ("4-inserted", .inserted(text: "Hey David, I just wanted to check if we can move the meeting to Friday at 4 PM.",
                                     method: "accessibility", latency: 1.21), 0),
            ("5-failed", .failed(message: "Network problem: You appear to be offline.", canRetry: true), 0),
        ]
        for (name, state, level) in states {
            let model = OverlayModel()
            model.state = state
            model.duckUp = true
            model.level = level
            model.levels = (0..<9).map { i in level * Float([0.3, 0.6, 0.9, 1.0, 0.7, 0.85, 0.5, 0.75, 0.4][i]) }
            model.startedAt = Date().addingTimeInterval(-7)
            model.stateChangedAt = Date().addingTimeInterval(-5)
            let view = OverlayView(model: model, onCopy: {}, onRetry: {}, onDismiss: {})
                .frame(width: OverlayController.width, height: OverlayController.height(for: state))
                .background(Color(red: 0.55, green: 0.62, blue: 0.70))   // stand-in desktop
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let image = renderer.nsImage { write(image, to: base.appendingPathComponent("overlay-\(name).png")) }
        }

        // Duck poses sheet + menu bar icons.
        let poses: [DuckPose] = [
            DuckPose(mood: .idle), DuckPose(mood: .listening, beakOpen: 1, soundLevel: 0.9, frame: 1),
            DuckPose(mood: .thinking, frame: 6), DuckPose(mood: .happy, beakOpen: 0.35, bob: -2), DuckPose(mood: .dizzy),
        ]
        for (i, p) in poses.enumerated() {
            write(DuckArt.image(pose: p, pixelSize: 8, background: cream), to: base.appendingPathComponent("duck-\(i).png"))
        }
        for open in [false, true] {
            let template = DuckArt.menuBarImage(open: open)
            let big = NSImage(size: NSSize(width: 18 * 8, height: 16 * 8))
            big.lockFocus()
            NSGraphicsContext.current?.imageInterpolation = .none
            NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 18 * 8, height: 16 * 8).fill()
            template.draw(in: NSRect(x: 0, y: 0, width: 18 * 8, height: 16 * 8))
            big.unlockFocus()
            write(big, to: base.appendingPathComponent("menubar-\(open ? "open" : "closed").png"))
        }
    }

    private static func write(_ image: NSImage, to url: URL) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}
