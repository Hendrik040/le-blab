import Testing
@testable import LeBlabCore

@Suite("Word error rate (benchmark scoring)")
struct WordErrorRateTests {
    @Test func identicalTextIsZero() {
        #expect(WordErrorRate.compute(reference: "Move the meeting to Friday.", hypothesis: "move the meeting to friday").wer == 0)
    }

    @Test(arguments: [
        ("move the meeting to friday at four pm", "Move the meeting to Friday at 4 PM."),
        ("meet at four p.m.", "Meet at 4:00 p.m."),
        ("twenty percent", "20%"),
        ("about 3,000 euros", "about 3000 euros"),
        ("Hey David, um, hi", "Hey David hi"),
        ("speech to text", "speech-to-text"),
        ("let us go", "Let’s go!"),
        ("it is ok", "It's okay."),
        ("twenty-one people", "21 people"),
        ("read the docs/api page", "read the docs api page"),
    ])
    func formattingDifferencesDontCount(reference: String, hypothesis: String) {
        #expect(WordErrorRate.compute(reference: reference, hypothesis: hypothesis).wer == 0)
    }

    @Test func compoundsStayErrors() {
        let r = WordErrorRate.compute(reference: "ask code rabbit to review", hypothesis: "ask coderabbit to review it")
        #expect(r.referenceWords == 5)
        #expect(r.errors == 3)
        #expect(abs(r.wer - 0.6) < 1e-9)
    }

    @Test func emptyHypothesisIsFullError() {
        #expect(WordErrorRate.compute(reference: "hello world", hypothesis: "").wer == 1)
    }

    @Test func germanKeepsUmButDropsÄh() {
        // "um" is a German preposition, not a filler.
        let r = WordErrorRate.compute(reference: "Wir treffen uns um vier Uhr", hypothesis: "Wir treffen uns 4 Uhr.", language: "de")
        #expect(r.deletions == 1)
        #expect(WordErrorRate.compute(reference: "äh um vier Uhr", hypothesis: "Um 4 Uhr.", language: "de").wer == 0)
        #expect(WordErrorRate.compute(reference: "einundzwanzig Tage", hypothesis: "21 Tage", language: "de").wer == 0)
        #expect(WordErrorRate.compute(reference: "Straße", hypothesis: "Strasse", language: "de").wer == 0)
    }

    @Test func bestPicksTheClosestReference() {
        let r = WordErrorRate.best(references: ["Friday at three, actually make that four", "Friday at four"],
                                   hypothesis: "Friday at 4 PM.")
        #expect(r.referenceWords == 3)
        #expect(r.insertions == 1)   // "pm" — fine: the formatter added it
    }
}
