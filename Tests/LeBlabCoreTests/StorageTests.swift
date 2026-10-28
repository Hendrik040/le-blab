import AppKit
import Foundation
import Testing
@testable import LeBlabCore

@Suite("Settings, history, clipboard, audio utils") @MainActor
struct StorageTests {
    func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("leblab-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func privacyPreservingDefaults() {
        let defaults = UserDefaults(suiteName: "leblab-test-\(UUID().uuidString)")!
        let s = SettingsStore(defaults: defaults)
        #expect(s.historyEnabled == false)
        #expect(s.hotkey == .controlShift)
        #expect(s.activationMode == .holdToTalk)
        #expect(s.quality == .fast)
        #expect(s.language == "auto")
        #expect(s.streamingDelayMs == 240)
        #expect(s.skipCleanTranscripts && s.optimisticInsert && s.speedFirstInPasteApps)
        let options = s.sessionOptions(turnDetection: false)
        #expect(options.realtime.model == "voxtral-mini-transcribe-realtime-3-0")
        #expect(options.realtime.contextBias.contains("CodeRabbit"))
        #expect(options.accuracyModel == nil)
        s.quality = .accurate
        #expect(SettingsStore(defaults: defaults).sessionOptions(turnDetection: false).accuracyModel == "voxtral-small-transcribe-3-0")
    }

    @Test func settingsPersistAndNeverContainTheAPIKey() {
        let name = "leblab-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let s = SettingsStore(defaults: defaults)
        s.hotkey = .fnKey
        s.formattingMode = .raw
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.hotkey == .fnKey)
        #expect(reloaded.formattingMode == .raw)
        let dump = defaults.persistentDomain(forName: name)?.description ?? ""
        #expect(!dump.lowercased().contains("api"))
    }

    @Test func historyDisabledWritesNothing() {
        let dir = tempDir()
        let store = HistoryStore(directory: dir, enabled: false)
        store.append(HistoryEntry(text: "private", rawText: nil, language: "en", model: "m"))
        #expect(store.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func historyIsLocalPrivateAndClearable() throws {
        let dir = tempDir()
        let store = HistoryStore(directory: dir, enabled: true)
        store.append(HistoryEntry(text: "hello", rawText: "hello", language: "en", model: "m"))
        let attrs = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let values = try store.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
        #expect(HistoryStore(directory: dir, enabled: true).entries.map(\.text) == ["hello"])
        store.clear()
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func turningHistoryOffDeletesTheFile() {
        let dir = tempDir()
        let store = HistoryStore(directory: dir, enabled: true)
        store.append(HistoryEntry(text: "x", rawText: nil, language: nil, model: "m"))
        store.isEnabled = false
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(store.entries.isEmpty)
    }

    @Test func historyRetentionPrunesOldEntries() {
        let store = HistoryStore(directory: tempDir(), enabled: true)
        store.retentionDays = 7
        store.append(HistoryEntry(date: Date().addingTimeInterval(-30 * 86_400), text: "old", rawText: nil, language: nil, model: "m"))
        store.append(HistoryEntry(text: "new", rawText: nil, language: nil, model: "m"))
        #expect(store.entries.map(\.text) == ["new"])
    }

    @Test func pasteboardSnapshotRestoresEveryTypeOfEveryItem() {
        let pb = NSPasteboard(name: NSPasteboard.Name("leblab-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        let a = NSPasteboardItem()
        a.setString("original text", forType: .string)
        a.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("com.example.custom"))
        let b = NSPasteboardItem()
        b.setString("https://example.com", forType: .URL)
        pb.clearContents()
        pb.writeObjects([a, b])

        let snapshot = PasteboardSnapshot(of: pb)
        let change = PasteboardMarkers.writeTransient("dictated", to: pb)
        #expect(pb.string(forType: .string) == "dictated")
        #expect(pb.types?.contains(PasteboardMarkers.transient) == true)
        #expect(pb.types?.contains(PasteboardMarkers.concealed) == true)
        #expect(pb.changeCount == change)

        snapshot.restore(to: pb)
        #expect(pb.pasteboardItems?.count == 2)
        #expect(pb.pasteboardItems?[0].string(forType: .string) == "original text")
        #expect(pb.pasteboardItems?[0].data(forType: NSPasteboard.PasteboardType("com.example.custom")) == Data([1, 2, 3]))
        #expect(pb.pasteboardItems?[1].string(forType: .URL) == "https://example.com")
    }

    @Test func wavHeaderDescribes16kMonoPCM() {
        let pcm = Data(count: 3200)
        let wav = WAVEncoder.wav(fromPCM16Mono: pcm)
        #expect(wav.count == 44 + 3200)
        #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: wav[8..<12], as: UTF8.self) == "WAVE")
        let rate = wav[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        #expect(UInt32(littleEndian: rate) == 16_000)
        let channels = wav[22..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
        #expect(UInt16(littleEndian: channels) == 1)
    }

    @Test func multipartRepeatsListFieldsLikeTheSDK() {
        var form = MultipartForm()
        form.addField("context_bias", "CodeRabbit")
        form.addField("context_bias", "Voxtral")
        let body = String(decoding: form.finalize(), as: UTF8.self)
        #expect(body.components(separatedBy: "name=\"context_bias\"").count == 3)
        #expect(body.hasSuffix("--\(form.boundary)--\r\n"))
    }

    @Test func vadFlagsSpeechAboveNoiseFloor() {
        let vad = EnergyVAD()
        #expect(!vad.process(levelDB: -60))
        #expect(!vad.process(levelDB: -58))
        #expect(vad.process(levelDB: -25))
    }

    @Test func percentiles() {
        #expect(DiagnosticsService.percentile([1, 2, 3, 4], 0.5) == 2.5)
        #expect(DiagnosticsService.percentile([], 0.5) == nil)
        #expect(DiagnosticsService.format(0.4321) == "432 ms")
    }

    @Test func keyComboDisplayAndCoding() throws {
        #expect(KeyCombo.optionSpace.displayString == "⌥Space")
        #expect(KeyCombo.controlShift.displayString == "⌃⇧")
        #expect(KeyCombo.fnShift.displayString == "Fn⇧")
        #expect(KeyCombo.controlShift.needsChordDebounce && !KeyCombo.optionSpace.needsChordDebounce)
        #expect(KeyCombo.fnKey.displayString == "Fn (Globe)")
        let data = try JSONEncoder().encode(KeyCombo.rightOption)
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == .rightOption)
        #expect(KeyCombo(keyCode: 49, modifiers: .command).knownConflict?.contains("Spotlight") == true)
    }

    @Test func privacyCopyNeverClaimsZeroRetention() {
        let text = PrivacyManager.retentionNotice.lowercased()
        #expect(text.contains("30"))
        #expect(text.contains("not on by default"))
        #expect(!text.contains("we never store"))
    }
}
