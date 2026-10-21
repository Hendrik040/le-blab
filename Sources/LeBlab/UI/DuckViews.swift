import AppKit
import LeBlabCore
import SwiftUI

extension DuckSprite.Ink {
    var color: Color? {
        switch self {
        case .clear: return nil
        case .outline: return Color(red: 0.118, green: 0.106, blue: 0.086)
        case .white: return Color(red: 1.0, green: 0.992, blue: 0.957)
        case .cream: return Color(red: 1.0, green: 0.937, blue: 0.761)
        case .yellow: return Color(red: 1.0, green: 0.847, blue: 0.0)
        case .amber: return Color(red: 1.0, green: 0.686, blue: 0.0)
        case .orange: return Color(red: 1.0, green: 0.510, blue: 0.020)
        case .redOrange: return Color(red: 0.980, green: 0.314, blue: 0.059)
        case .red: return Color(red: 0.882, green: 0.020, blue: 0.0)
        case .gray: return Color(red: 0.231, green: 0.212, blue: 0.192)
        case .blush: return Color(red: 1.0, green: 0.604, blue: 0.478)
        case .mouth: return Color(red: 0.639, green: 0.0, blue: 0.106)
        case .shadow: return Color.black.opacity(0.22)
        case .sparkle: return .white
        }
    }

    var nsColor: NSColor? { color.map { NSColor($0) } }
}

/// Draws one duck frame as crisp pixels.
struct DuckCanvas: View {
    let pose: DuckPose

    var body: some View {
        Canvas { context, size in
            let cell = floor(min(size.width / CGFloat(DuckSprite.width), size.height / CGFloat(DuckSprite.height)) * 2) / 2
            let ox = (size.width - cell * CGFloat(DuckSprite.width)) / 2
            let oy = size.height - cell * CGFloat(DuckSprite.height)
            let pixels = DuckSprite.render(pose)
            for y in 0..<DuckSprite.height {
                for x in 0..<DuckSprite.width {
                    guard let color = pixels[y * DuckSprite.width + x].color else { continue }
                    context.fill(Path(CGRect(x: ox + CGFloat(x) * cell, y: oy + CGFloat(y) * cell, width: cell + 0.01, height: cell + 0.01)),
                                 with: .color(color))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The animated mascot. Mood follows the dictation state; the beak follows your voice.
struct AnimatedDuck: View {
    let state: DictationState
    let level: Float
    let stateChangedAt: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            DuckCanvas(pose: Self.pose(state: state, level: level, now: context.date, since: stateChangedAt))
        }
    }

    static func pose(state: DictationState, level: Float, now: Date, since: Date) -> DuckPose {
        let t = now.timeIntervalSinceReferenceDate
        let elapsed = now.timeIntervalSince(since)
        let blink = t.truncatingRemainder(dividingBy: 3.4) < 0.13
        let frame = Int(t * 10)
        let l = Double(level)
        switch state {
        case .recording:
            let talking = l > 0.12
            let bob = talking && Int(t * 5) % 2 == 0 ? -1 : 0
            return DuckPose(mood: .listening, beakOpen: min(1, max(0, (l - 0.08) * 1.8)), blink: blink, bob: bob,
                            soundLevel: l, frame: frame)
        case .processing:
            return DuckPose(mood: .thinking, blink: blink, bob: Int(t * 3) % 2 == 0 ? 0 : -1, frame: frame)
        case .inserted:
            // A little hop when the text lands.
            let hop = elapsed < 0.45 ? -Int((sin(elapsed / 0.45 * .pi) * 3).rounded()) : 0
            return DuckPose(mood: .happy, beakOpen: 0.35, bob: hop, frame: frame)
        case .failed:
            return DuckPose(mood: .dizzy, bob: 0, frame: frame)
        case .notInserted, .hint, .idle:
            return DuckPose(mood: .idle, blink: blink, frame: frame)
        }
    }
}

/// Voice meter as stacked pixel blocks in Mistral's gradient (yellow at the bottom, red on top).
struct PixelBars: View {
    let levels: [Float]
    private let rows = 6

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                let lit = max(1, Int((CGFloat(levels[i]) * CGFloat(rows)).rounded()))
                VStack(spacing: 2) {
                    ForEach((0..<rows).reversed(), id: \.self) { row in
                        Rectangle()
                            .fill(row < lit ? Self.color(row: row, rows: rows) : Color.white.opacity(0.08))
                            .frame(width: 3, height: 3)
                    }
                }
            }
        }
        .frame(height: CGFloat(rows) * 5)
    }

    static func color(row: Int, rows: Int) -> Color {
        let inks = DuckSprite.gradient.reversed()   // yellow … red
        let index = min(inks.count - 1, row * inks.count / rows)
        return Array(inks)[index].color ?? .orange
    }
}

enum DuckArt {
    /// Renders a duck frame (and optional background) to a bitmap — used for the app icon.
    static func image(pose: DuckPose, pixelSize: Int, background: NSColor?, cornerRadius: CGFloat = 0, padding: CGFloat = 0) -> NSImage {
        let width = CGFloat(DuckSprite.width * pixelSize) + padding * 2
        let height = CGFloat(DuckSprite.height * pixelSize) + padding * 2
        let side = max(width, height)
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        NSGraphicsContext.current?.shouldAntialias = false
        if let background {
            background.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: side, height: side), xRadius: cornerRadius, yRadius: cornerRadius).fill()
        }
        let pixels = DuckSprite.render(pose)
        let ox = (side - CGFloat(DuckSprite.width * pixelSize)) / 2
        let oy = (side - CGFloat(DuckSprite.height * pixelSize)) / 2
        for y in 0..<DuckSprite.height {
            for x in 0..<DuckSprite.width {
                guard let color = pixels[y * DuckSprite.width + x].nsColor else { continue }
                color.setFill()
                // AppKit's origin is bottom-left.
                NSRect(x: ox + CGFloat(x * pixelSize), y: oy + CGFloat((DuckSprite.height - 1 - y) * pixelSize),
                       width: CGFloat(pixelSize), height: CGFloat(pixelSize)).fill()
            }
        }
        image.unlockFocus()
        return image
    }

    /// Menu bar template: a duck silhouette with a headphone band (beak opens while recording).
    /// Rasterized from shapes on an 18×16 grid at 2 px per cell for Retina crispness.
    static func menuBarImage(open: Bool) -> NSImage {
        let w = 18, h = 16
        var on = [[Bool]](repeating: [Bool](repeating: false, count: w), count: h)
        func ellipse(_ px: Double, _ py: Double, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Bool {
            let dx = (px - cx) / rx, dy = (py - cy) / ry
            return dx * dx + dy * dy <= 1
        }
        for y in 0..<h {
            for x in 0..<w {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                let d = hypot(px - 10, py - 6.5)
                var ink = d <= 3.9                                              // head
                ink = ink || ellipse(px, py, 8.2, 12, 7.2, 3.3)                 // body
                ink = ink || (px >= 8 && px < 12.5 && py >= 9 && py < 11.5)     // neck
                ink = ink || (px < 4.5 && py > 8 && py < 13 && px > 0 && (py - 8) > (px - 0.5) * 0.5) // tail
                if d >= 5, d < 6.1, py < 6.2, px < 14.2 { ink = true }          // headphone band
                if px >= 4.4, px < 7.2, py >= 4.6, py < 9 { ink = true }       // ear cup
                on[y][x] = ink
            }
        }
        // Beak.
        if open {
            for x in 14...16 { on[5][x] = true }
            for x in 14...15 { on[8][x] = true }
        } else {
            for x in 14...16 { on[6][x] = true; on[7][x] = true }
        }
        on[5][11] = false                                                       // eye
        let image = NSImage(size: NSSize(width: w, height: h), flipped: true) { _ in
            NSColor.black.setFill()
            for y in 0..<h { for x in 0..<w where on[y][x] { NSRect(x: x, y: y, width: 1, height: 1).fill() } }
            return true
        }
        image.isTemplate = true
        return image
    }
}
