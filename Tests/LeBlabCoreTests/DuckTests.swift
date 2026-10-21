import Testing
@testable import LeBlabCore

@Suite("Pixel duck")
struct DuckTests {
    @Test func rendersAFullGrid() {
        let pixels = DuckSprite.render(DuckPose())
        #expect(pixels.count == DuckSprite.width * DuckSprite.height)
        #expect(pixels.contains(.outline) && pixels.contains(.white) && pixels.contains(.redOrange))
    }

    @Test func beakOpensWithTheVoice() {
        let closed = DuckSprite.render(DuckPose(mood: .listening, beakOpen: 0))
        let open = DuckSprite.render(DuckPose(mood: .listening, beakOpen: 1, soundLevel: 0.9))
        #expect(!closed.contains(.mouth))
        #expect(open.contains(.mouth))
        #expect(closed != open)
    }

    @Test func moodsLookDifferent() {
        let poses: [DuckPose.Mood] = [.idle, .thinking, .happy, .dizzy]
        let frames = poses.map { DuckSprite.render(DuckPose(mood: $0, frame: 3)) }
        #expect(Set(frames.map { $0.map(\.rawValue) }).count == poses.count)
    }

    @Test func staysInsideTheGridWhenHopping() {
        let pixels = DuckSprite.render(DuckPose(mood: .happy, bob: -3, frame: 1))
        #expect(pixels.count == DuckSprite.width * DuckSprite.height)
    }
}
