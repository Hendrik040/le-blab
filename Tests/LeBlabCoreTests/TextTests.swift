import Foundation
import Testing
@testable import LeBlabCore

@Suite("Vocabulary, formatting guardrails, spacing")
struct TextTests {
    let corrector = VocabularyCorrector(entries: VocabularyEntry.defaults)

    @Test(arguments: [
        ("ask code rabbit to review", "ask CodeRabbit to review"),
        ("push it to github today", "push it to GitHub today"),
        ("the dev rel team", "the DevRel team"),
        ("Code-Rabbit's review", "CodeRabbit's review"),
        ("we use mistral and vox trail", "we use Mistral and Voxtral"),
        ("coderabbit", "CodeRabbit"),
    ])
    func correctsVariants(input: String, expected: String) {
        #expect(corrector.apply(input) == expected)
    }

    @Test(arguments: [
        "see https://github.com/foo",
        "mail me at dev@github.com",
        "open ~/code/github/notes",
        "mistralai is a package",     // partial word untouched
    ])
    func leavesURLsPathsAndPartialWordsAlone(input: String) {
        #expect(corrector.apply(input) == input)
    }

    @Test func splitsCamelCase() {
        #expect(VocabularyCorrector.parts(of: "CodeRabbit") == ["Code", "Rabbit"])
        #expect(VocabularyCorrector.parts(of: "HTTPServer") == ["HTTP", "Server"])
        #expect(VocabularyCorrector.parts(of: "GPT-4o") == ["GPT", "4o"])
    }

    @Test func biasTermsAreDeduplicated() {
        let terms = VocabularyCorrector.biasTerms([.init(term: "GitHub"), .init(term: "github"), .init(term: " "), .init(term: "Voxtral")])
        #expect(terms == ["GitHub", "Voxtral"])
    }

    @Test func guardAcceptsAGenuineEdit() {
        let input = "Hey David um I just wanted to check if we can move the meeting to Friday at three actually make that four."
        let output = "Hey David, I just wanted to check if we can move the meeting to Friday at 4 PM."
        #expect(FormatterGuard.rejectionReason(input: input, output: output) == nil)
    }

    @Test func guardRejectsAnAnswerInsteadOfAnEdit() {
        let input = "what is the capital of france and how many people live there"
        let output = "The capital of France is Paris, and roughly 2.1 million people live in the city proper."
        #expect(FormatterGuard.rejectionReason(input: input, output: output) != nil)
    }

    @Test func guardRejectsInventedContent() {
        let input = "send the report"
        let output = "Send the report to the whole leadership team by Friday, including the Q3 numbers and the hiring plan."
        #expect(FormatterGuard.rejectionReason(input: input, output: output) != nil)
    }

    @Test func guardRejectsEmpty() {
        #expect(FormatterGuard.rejectionReason(input: "hello there", output: "") == "empty output")
    }

    @Test func stripsWrappingTheModelMightAdd() {
        #expect(FormatterGuard.stripWrapping("<transcript>Hello.</transcript>") == "Hello.")
        #expect(FormatterGuard.stripWrapping("\"Hello there.\"") == "Hello there.")
        #expect(FormatterGuard.stripWrapping("```\nHello\n```") == "Hello")
    }

    @Test func keepsListsButNoTrailingNewline() {
        #expect(FormatterGuard.finalizePreservingLayout("We need:\n\n- Milk\n- Eggs\n\n\n\n") == "We need:\n\n- Milk\n- Eggs")
    }

    @Test func localCleanupRemovesFillersInEnglishAndGerman() {
        #expect(LocalCleanup.apply("um, yes") == "Yes")
        #expect(LocalCleanup.apply("Hey David, um, I just wanted to check") == "Hey David, I just wanted to check")
        #expect(LocalCleanup.apply("ähm ja genau") == "Ja genau")
        #expect(LocalCleanup.apply("uh, sure") == "Sure")
        #expect(LocalCleanup.apply("umbrella") == "Umbrella")   // not a filler
    }

    @Test func bareEnglishFillersAreRemovedButNotGermanUm() {
        #expect(LocalCleanup.apply("um I think we should ship it") == "I think we should ship it")
        #expect(LocalCleanup.apply("so uh we can go") == "So we can go")
        #expect(LocalCleanup.apply("Wir sehen uns um, äh, 16 Uhr.") == "Wir sehen uns um, 16 Uhr.")
        #expect(LocalCleanup.apply("Es geht um die Präsentation.", language: "de") == "Es geht um die Präsentation.")
    }

    @Test func germanUmIsAWordNotAFiller() {
        #expect(LocalCleanup.apply("Können wir das um 16 Uhr machen?") == "Können wir das um 16 Uhr machen?")
        #expect(LocalCleanup.apply("Es geht um die Präsentation.") == "Es geht um die Präsentation.")
    }

    @Test func rawFormatterNeverEndsWithNewline() async {
        let raw = RawFormatter(vocabulary: corrector)
        let result = await raw.format("  hello   code rabbit \n\n", language: nil)
        #expect(result.text == "hello CodeRabbit")
        #expect(!result.usedLanguageModel)
    }

    @Test func smartFormatterSkipsNetworkForShortUtterances() async {
        let client = MistralChatClient(region: { .global }, apiKey: { nil })
        let smart = SmartFormatter(client: client, model: "x", vocabulary: [])
        let result = await smart.format("um, yes", language: "en")
        #expect(result.text == "Yes")
        #expect(result.fallbackReason == "short utterance")
    }

    @Test func smartFormatterFallsBackToRawWhenTheModelIsUnavailable() async {
        let client = MistralChatClient(region: { .global }, apiKey: { nil })   // no key → request fails
        let smart = SmartFormatter(client: client, model: "x", vocabulary: VocabularyEntry.defaults)
        let result = await smart.format("um, please ask code rabbit to review the pull request, actually the issue", language: "en")
        #expect(result.text == "Please ask CodeRabbit to review the pull request, actually the issue")
        #expect(!result.usedLanguageModel)
        #expect(result.fallbackReason == "language model unavailable")
    }

    @Test func promptKeepsTheTranscriptDelimitedAndHintsLanguage() {
        let messages = FormatterPrompt.messages(transcript: "hallo welt", language: "de", vocabulary: ["Voxtral"])
        #expect(messages.first?["role"] == "system")
        #expect(messages.first?["content"]?.contains("Never answer") == true)
        #expect(messages.first?["content"]?.contains("Voxtral") == true)
        #expect(messages.last?["content"] == "<transcript lang=\"de\">hallo welt</transcript>")
    }

    @Test(arguments: [
        ("hello", Character?("d"), Character?.none, " hello"),
        ("hello", Character?(" "), Character?.none, "hello"),
        ("hello", Character?("("), Character?.none, "hello"),
        (", and more", Character?("d"), Character?.none, ", and more"),
        ("hello", Character?.none, Character?("w"), "hello "),
        ("hello", Character?("."), Character?("W"), " hello "),
    ])
    func spacing(text: String, before: Character?, after: Character?, expected: String) {
        #expect(SpacingRules.adjust(text, before: before, after: after) == expected)
    }
}

@Suite("Focus classifier (copy instead of pasting into nothing)")
struct FocusClassifierTests {
    @Test(arguments: ["AXTextArea", "AXTextField", "AXComboBox", "AXWebArea", "AXSomethingNew"])
    func textRolesAndUnknownRolesAreTypeable(role: String) {
        #expect(FocusClassifier.canReceiveText(role: role, isInsideWebArea: false, hasTextRange: { false }))
    }

    @Test(arguments: ["AXWindow", "AXList", "AXOutline", "AXScrollArea", "AXGroup", "AXButton"])
    func containersWithoutACaretAreNot(role: String) {
        #expect(!FocusClassifier.canReceiveText(role: role, isInsideWebArea: false, hasTextRange: { false }))
    }

    @Test func noRoleCountsAsTypeable() {
        #expect(FocusClassifier.canReceiveText(role: nil, isInsideWebArea: false, hasTextRange: { false }))
    }

    @Test func contentEditableGroupInAWebPageIsTypeable() {
        #expect(FocusClassifier.canReceiveText(role: "AXGroup", isInsideWebArea: true, hasTextRange: { false }))
    }

    @Test func nativeGroupWithACaretIsTypeable() {
        #expect(FocusClassifier.canReceiveText(role: "AXGroup", isInsideWebArea: false, hasTextRange: { true }))
    }
}
