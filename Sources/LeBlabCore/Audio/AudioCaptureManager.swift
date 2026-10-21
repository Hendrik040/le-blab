import AVFoundation
import CoreAudio
import Foundation

public struct AudioChunk: Sendable {
    /// 16 kHz mono s16le PCM.
    public let pcm: Data
    /// 0…1 loudness for UI meters.
    public let level: Float
    /// Local energy-based voice activity for this chunk.
    public let voiced: Bool

    public init(pcm: Data, level: Float, voiced: Bool) {
        self.pcm = pcm
        self.level = level
        self.voiced = voiced
    }
}

public enum AudioCaptureError: Error, Equatable, CustomStringConvertible {
    case permissionDenied
    case noInputDevice
    case engineFailed(String)

    public var description: String {
        switch self {
        case .permissionDenied: return "Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone."
        case .noInputDevice: return "No microphone found."
        case .engineFailed(let m): return "Couldn't start the microphone: \(m)"
        }
    }
}

public protocol AudioCapturing: AnyObject {
    /// Called on the main queue for every converted chunk (~50–100 ms of audio).
    var onChunk: ((AudioChunk) -> Void)? { get set }
    /// Called on the main queue if the input device disappears mid-recording and can't be recovered.
    var onInterrupted: ((AudioCaptureError) -> Void)? { get set }
    func start(deviceUID: String?) throws
    func stop()
}

/// Microphone capture via AVAudioEngine. Audio is converted to 16 kHz mono Int16 in memory
/// and handed straight to the caller — nothing is persisted.
public final class AudioCaptureManager: AudioCapturing {
    public var onChunk: ((AudioChunk) -> Void)?
    public var onInterrupted: ((AudioCaptureError) -> Void)?

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var configObserver: NSObjectProtocol?
    private var deviceUID: String?
    private var running = false
    private let vad = EnergyVAD()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(PCMFormat.sampleRate),
                                             channels: 1, interleaved: true)!

    public init() {}

    public func start(deviceUID: String?) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw AudioCaptureError.permissionDenied }
        stop()
        self.deviceUID = deviceUID
        vad.reset()
        try startEngine()
        running = true
    }

    public func stop() {
        running = false
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let uid = deviceUID, let id = AudioDevices.deviceID(forUID: uid), let unit = input.audioUnit {
            var deviceID = id
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status != noErr { Log.audio.error("Selecting input device failed (\(status)); using system default") }
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else { throw AudioCaptureError.noInputDevice }
        guard let converter = AVAudioConverter(from: inFormat, to: outputFormat) else {
            throw AudioCaptureError.engineFailed("unsupported input format \(inFormat)")
        }
        converter.downmix = true
        self.converter = converter

        // ~50 ms buffers keep the first-partial latency low without flooding the socket.
        let bufferSize = AVAudioFrameCount(inFormat.sampleRate * 0.05)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inFormat) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                                queue: .main) { [weak self] _ in
            self?.handleConfigurationChange()
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw AudioCaptureError.engineFailed(error.localizedDescription)
        }
        self.engine = engine
    }

    /// Device unplugged / default input switched mid-dictation: try to continue on the new default.
    private func handleConfigurationChange() {
        guard running else { return }
        Log.audio.info("Audio configuration changed during capture; restarting input")
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        if let uid = deviceUID, AudioDevices.deviceID(forUID: uid) == nil { deviceUID = nil }
        do {
            try startEngine()
        } catch {
            running = false
            onInterrupted?(error as? AudioCaptureError ?? .engineFailed(error.localizedDescription))
        }
    }

    // Runs on the audio render thread.
    private func process(_ buffer: AVAudioPCMBuffer) {
        guard let converter, buffer.frameLength > 0 else { return }
        let level = Self.rmsLevel(buffer)
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return }
        let pcm = Data(bytes: samples, count: Int(out.frameLength) * PCMFormat.bytesPerSample)
        let voiced = vad.process(levelDB: level.db)
        let chunk = AudioChunk(pcm: pcm, level: level.normalized, voiced: voiced)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running else { return }
            self.onChunk?(chunk)
        }
    }

    static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> (db: Float, normalized: Float) {
        guard let data = buffer.floatChannelData?[0] else { return (-160, 0) }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        let rms = sqrt(sum / Float(max(n, 1)))
        let db = 20 * log10(max(rms, 1e-8))
        // Map -55 dB…-10 dB onto 0…1 for the waveform.
        let normalized = min(max((db + 55) / 45, 0), 1)
        return (db, normalized)
    }
}

/// Minimal adaptive energy VAD: tracks the noise floor and flags chunks well above it.
final class EnergyVAD {
    private var noiseFloor: Float = -60
    private var initialized = false

    func reset() {
        noiseFloor = -60
        initialized = false
    }

    func process(levelDB: Float) -> Bool {
        if !initialized {
            noiseFloor = min(levelDB, -40)
            initialized = true
        }
        let voiced = levelDB > max(noiseFloor + 12, -50)
        // Floor follows quiet chunks quickly and loud chunks very slowly.
        let alpha: Float = levelDB < noiseFloor ? 0.3 : 0.005
        noiseFloor += alpha * (levelDB - noiseFloor)
        return voiced
    }
}

public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: String      // CoreAudio device UID (stable across launches)
    public let name: String
}

public enum AudioDevices {
    public static func inputDevices() -> [AudioInputDevice] {
        allDeviceIDs().compactMap { id in
            guard inputChannelCount(id) > 0, let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
            return AudioInputDevice(id: uid, name: name)
        }
    }

    public static func defaultInputDevice() -> AudioInputDevice? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0,
              let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName) else { return nil }
        return AudioInputDevice(id: uid, name: name)
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { stringProperty($0, kAudioDevicePropertyDeviceUID) == uid && inputChannelCount($0) > 0 }
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func inputChannelCount(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
