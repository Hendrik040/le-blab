import Foundation

/// Le Blab's mascot: a pixel-art duck with headphones, in Mistral's block-gradient palette.
///
/// The sprite is rasterized from simple shapes onto a fixed grid every frame, then outlined
/// automatically — so poses (beak opening with your voice, blinking, hopping, shimmering
/// headphones) are just parameters, not hand-drawn frames.
public struct DuckPose: Equatable, Sendable {
    public enum Mood: Sendable { case idle, listening, thinking, happy, dizzy }

    public var mood: Mood
    /// 0 (closed) … 1 (wide open).
    public var beakOpen: Double
    public var blink: Bool
    /// Vertical offset in cells; negative = up.
    public var bob: Int
    /// 0…1 microphone level; drives the "sound bits" leaving the beak.
    public var soundLevel: Double
    /// Animation tick for flicker, thinking dots and headphone shimmer.
    public var frame: Int

    public init(mood: Mood = .idle, beakOpen: Double = 0, blink: Bool = false, bob: Int = 0,
                soundLevel: Double = 0, frame: Int = 0) {
        self.mood = mood
        self.beakOpen = beakOpen
        self.blink = blink
        self.bob = bob
        self.soundLevel = soundLevel
        self.frame = frame
    }
}

public enum DuckSprite {
    public static let width = 36
    public static let height = 32

    public enum Ink: UInt8, Sendable {
        case clear = 0, outline, white, cream, yellow, amber, orange, redOrange, red, gray, blush, mouth, shadow, sparkle
    }

    /// Mistral's block gradient, top (red) to bottom (yellow).
    public static let gradient: [Ink] = [.red, .redOrange, .orange, .amber, .yellow]

    private enum Group: UInt8 { case none = 0, skin, beak, phones, feet }

    public static func render(_ pose: DuckPose) -> [Ink] {
        var ink = [Ink](repeating: .clear, count: width * height)
        var group = [Group](repeating: .none, count: width * height)
        let b = Double(pose.bob)
        let open = max(0, min(3, Int((pose.beakOpen * 3).rounded())))

        func set(_ x: Int, _ y: Int, _ i: Ink, _ g: Group? = nil) {
            guard x >= 0, y >= 0, x < width, y < height else { return }
            ink[y * width + x] = i
            if let g { group[y * width + x] = g }
        }
        func inEllipse(_ px: Double, _ py: Double, _ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double) -> Bool {
            let dx = (px - cx) / rx, dy = (py - cy) / ry
            return dx * dx + dy * dy <= 1
        }
        func inTriangle(_ px: Double, _ py: Double, _ a: (Double, Double), _ b: (Double, Double), _ c: (Double, Double)) -> Bool {
            func sign(_ p1: (Double, Double), _ p2: (Double, Double), _ p3: (Double, Double)) -> Double {
                (p1.0 - p3.0) * (p2.1 - p3.1) - (p2.0 - p3.0) * (p1.1 - p3.1)
            }
            let p = (px, py)
            let d1 = sign(p, a, b), d2 = sign(p, b, c), d3 = sign(p, c, a)
            let neg = d1 < 0 || d2 < 0 || d3 < 0, pos = d1 > 0 || d2 > 0 || d3 > 0
            return !(neg && pos)
        }

        // 1. Ground shadow and feet (they stay planted while the body bobs).
        for y in 0..<height {
            for x in 0..<width {
                let px = Double(x) + 0.5, py = Double(y) + 0.5
                if inEllipse(px, py, 15.5, 31, 9.5, 0.9) { set(x, y, .shadow) }
            }
        }
        let legTop = 26 + pose.bob
        for (footX, legX) in [(8, 10), (16, 18)] {
            for x in footX...(footX + 5) { set(x, 29, x == footX + 5 ? .redOrange : .orange, .feet) }
            for x in (footX + 1)...(footX + 4) { set(x, 30, .redOrange, .feet) }
            if legTop <= 28 { for y in legTop...28 { for x in legX...(legX + 1) { set(x, y, .orange, .feet) } } }
        }

        // 2. Body, tail, wing, neck, head (skin).
        let flap = pose.mood == .happy && pose.frame % 4 < 2 ? 1.0 : 0
        for y in 0..<height {
            for x in 0..<width {
                let px = Double(x) + 0.5, py = Double(y) + 0.5 - b
                var skin: Ink? = nil
                if inTriangle(px, py, (2.5, 13.5), (9.5, 17), (5.5, 21.5)) { skin = .white }
                if inEllipse(px, py, 14.5, 20.5, 10.5, 6.8) { skin = py > 23.6 ? .cream : .white }
                if px >= 15, px < 22, py >= 13, py < 18.5 { skin = .white }
                if inEllipse(px, py, 19.5, 10.5, 6.6, 6.6) { skin = .white }
                // Wing: cream feathers with an amber crescent along the bottom/back edge.
                let wing = { (qx: Double, qy: Double) in inEllipse(qx, qy, 11.8, 20.2 - flap, 5.4, 2.9) }
                if wing(px, py) {
                    let edge = !wing(px, py + 1) || (py >= 20.2 - flap && !wing(px - 1.4, py))
                    skin = edge ? .amber : .cream
                }
                if let skin { set(x, y, skin, .skin) }
            }
        }

        // 3. Headphones: gradient band over the head, ear cup on the back of the head.
        let shimmer = pose.mood == .thinking ? pose.frame / 2 : 0
        for y in 0..<height {
            for x in 0..<width {
                let px = Double(x) + 0.5, py = Double(y) + 0.5 - b
                let d = hypot(px - 19.5, py - 10.5)
                // Band ends at the top-right of the head (the far side is hidden behind it).
                if d >= 6.6, d < 8.4, py < 9.6, px > 11.5, px < 24.5, !(px > 22 && py > 6) {
                    let segment = Int(((px - 12) / 15 * 5).rounded(.down))
                    set(x, y, gradient[((max(0, min(4, segment)) + shimmer) % 5 + 5) % 5], .phones)
                }
                if inEllipse(px, py, 12.8, 11.6, 2.9, 3.7) { set(x, y, .redOrange, .phones) }
                if px >= 15, px < 16, py >= 8.2, py < 15 { set(x, y, .gray, .phones) }
            }
        }
        let by = pose.bob
        set(12, 10 + by, .yellow, .phones); set(12, 11 + by, .yellow, .phones); set(11, 12 + by, .amber, .phones)
        set(13, 14 + by, .red, .phones); set(12, 14 + by, .red, .phones)

        // 4. Beak (opens with the voice).
        for x in 25...28 { set(x, 9 + by, .amber, .beak) }
        for x in 25...31 { set(x, 10 + by, .orange, .beak) }
        for x in 25...31 { set(x, 11 + by, .redOrange, .beak) }
        for row in 0...open {
            for x in 25...(open == 0 ? 30 : 29) { set(x, 12 + row + by, open == 0 ? .outline : .mouth, .beak) }
        }
        if open >= 2 { for x in 26...28 { set(x, 12 + open + by, .redOrange, .beak) } }   // tongue
        for x in 25...30 { set(x, 13 + open + by, .orange, .beak) }
        for x in 25...28 { set(x, 14 + open + by, .redOrange, .beak) }

        // 5. Outlines: around the whole duck, and where beak/headphones meet the skin.
        var result = ink
        for y in 0..<height {
            for x in 0..<width where group[y * width + x] == .none {
                var touches = false
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, ny >= 0, nx < width, ny < height, group[ny * width + nx] != .none { touches = true }
                } }
                if touches { result[y * width + x] = .outline }
            }
        }
        for y in 0..<height {
            for x in 0..<width where group[y * width + x] == .skin {
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, ny = y + dy
                    guard nx >= 0, ny >= 0, nx < width, ny < height else { continue }
                    let g = group[ny * width + nx]
                    if g == .beak || g == .phones { result[y * width + x] = .outline; break }
                }
            }
        }
        ink = result

        // 6. Face.
        switch (pose.mood, pose.blink) {
        case (.happy, _):
            set(20, 9 + by, .outline); set(21, 8 + by, .outline); set(22, 9 + by, .outline)
        case (.dizzy, _):
            for (dx, dy) in [(0, 0), (2, 0), (1, 1), (0, 2), (2, 2)] { set(20 + dx, 7 + dy + by, .outline) }
        case (_, true):
            set(21, 9 + by, .outline); set(22, 9 + by, .outline)
        default:
            set(21, 8 + by, .outline); set(21, 9 + by, .outline)
        }
        if ink[(12 + pose.bob) * width + 20] == .white { set(20, 12 + by, .blush) }
        if ink[(12 + pose.bob) * width + 21] == .white { set(21, 12 + by, .blush) }

        // 7. Effects.
        switch pose.mood {
        case .listening:
            let jitter = pose.frame % 2
            if pose.soundLevel > 0.08 { for x in (33 + jitter)...(34 + jitter) { set(x, 11 + by, .orange) } }
            if pose.soundLevel > 0.28 { set(33 + jitter, 7 + by, .amber); set(34 + jitter, 6 + by, .amber) }
            if pose.soundLevel > 0.5 { set(33 + jitter, 15 + by, .redOrange); set(34 + jitter, 16 + by, .redOrange) }
        case .thinking:
            let active = (pose.frame / 3) % 3
            for i in 0..<3 {
                let color: Ink = i == active ? .orange : .amber
                for dx in 0...1 { for dy in 0...1 { set(25 + i * 3 + dx, 1 + dy + by, i == active ? color : .yellow) } }
            }
        case .happy:
            let on = pose.frame % 2 == 0
            set(31, 3 + by, on ? .yellow : .amber); set(33, 6 + by, on ? .amber : .yellow)
            set(29, 1 + by, on ? .orange : .clear); set(32, 0 + by, on ? .clear : .orange)
        default:
            break
        }
        return ink
    }
}
