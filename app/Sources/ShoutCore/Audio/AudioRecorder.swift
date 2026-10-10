@preconcurrency import AVFoundation
import Foundation

public enum AudioRecorderError: LocalizedError {
    case noInputDevice
    case converterUnavailable
    case alreadyRecording

    public var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone is available."
        case .converterUnavailable: "Couldn't convert the microphone's audio format."
        case .alreadyRecording: "Already recording."
        }
    }
}

/// Records the chosen microphone (or the system default) as 16 kHz mono Float32, the format
/// Whisper wants.
///
/// The audio engine only runs between `start()` and `stop()`/`cancel()`, so the macOS
/// microphone indicator is only on while you're dictating.
public final class AudioRecorder: @unchecked Sendable {
    public static let sampleRate: Double = 16_000

    private var engine = AVAudioEngine()
    private let lock = NSLock()
    private var samples: [Float] = []
    private var converter: AVAudioConverter?
    private var isRecording = false
    private var configObserver: NSObjectProtocol?

    /// Called on the audio thread with a 0–1 loudness value, roughly 20 times a second.
    public var onLevel: (@Sendable (Float) -> Void)?
    /// Called on the main queue if the input device changes while recording.
    public var onInterrupted: (@Sendable () -> Void)?
    /// UID of the microphone to record from; nil follows the system default input. If that
    /// microphone isn't connected when recording starts, the system default is used instead.
    public var inputDeviceUID: String?

    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.sampleRate,
        channels: 1,
        interleaved: false
    )!

    public init() {}

    public func start() throws {
        try lock.withLock {
            guard !isRecording else { throw AudioRecorderError.alreadyRecording }
            samples.removeAll(keepingCapacity: true)
        }
        let input = engine.inputNode
        selectInputDevice(on: input)
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw AudioRecorderError.noInputDevice
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioRecorderError.converterUnavailable
        }
        converter.downmix = true
        lock.withLock { self.converter = converter }

        let bufferSize = AVAudioFrameCount(inputFormat.sampleRate / 20)
        input.installTap(onBus: 0, bufferSize: bufferSize, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer)
        }
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, engine] _ in
            // Choosing a device in selectInputDevice also posts this, about 100 ms later,
            // but the engine carries on recording. A real change (the device unplugged, a
            // new default input) stops the engine.
            guard !engine.isRunning else { return }
            Log.audio.notice("Audio configuration changed while recording")
            self?.onInterrupted?()
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            removeObserver()
            throw error
        }
        lock.withLock { isRecording = true }
    }

    /// Stops recording and returns everything captured.
    public func stop() -> [Float] {
        tearDown()
        return lock.withLock {
            let captured = samples
            samples.removeAll()
            return captured
        }
    }

    public func cancel() {
        tearDown()
        lock.withLock { samples.removeAll() }
    }

    private func tearDown() {
        let wasRecording = lock.withLock { () -> Bool in
            defer { isRecording = false; converter = nil }
            return isRecording
        }
        guard wasRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        removeObserver()
        // A fresh engine picks up the current default input device next time.
        engine = AVAudioEngine()
    }

    /// Points the engine's input at the chosen microphone. Without this, AVAudioEngine records
    /// from the system default input. Must run before the input format is read.
    private func selectInputDevice(on input: AVAudioInputNode) {
        guard let uid = inputDeviceUID else { return }
        guard let device = AudioDevices.deviceID(forUID: uid) else {
            Log.audio.notice("Chosen microphone isn't connected; using the system default")
            return
        }
        do {
            try input.auAudioUnit.setDeviceID(device)
        } catch {
            Log.audio.error("Couldn't switch to the chosen microphone, using the system default: \(error.localizedDescription)")
        }
    }

    private func removeObserver() {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
    }

    private func append(_ buffer: AVAudioPCMBuffer) {
        guard let converter = lock.withLock({ converter }) else { return }
        guard let chunk = AudioConversion.convert(buffer, with: converter, to: targetFormat), !chunk.isEmpty else {
            return
        }
        lock.withLock { samples.append(contentsOf: chunk) }
        onLevel?(chunk.withUnsafeBufferPointer(AudioConversion.level(of:)))
    }
}

public enum AudioConversion {
    /// Converts one buffer with a long-lived converter (it keeps resampler state between
    /// calls) and returns every output frame available. The converter is drained fully each
    /// time; a single fixed-size call can leave a growing backlog inside it.
    public static func convert(
        _ buffer: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to format: AVAudioFormat
    ) -> [Float]? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 256
        var supplied = false
        var result: [Float] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if supplied {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                supplied = true
                inputStatus.pointee = .haveData
                return buffer
            }
            guard status != .error, error == nil else { return nil }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                result.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            // .haveData means the output filled up and more is waiting.
            guard status == .haveData else { return result }
        }
    }

    /// Reads an audio file and converts it to 16 kHz mono Float32. Used by `--self-test`.
    public static func loadFile(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: AudioRecorder.sampleRate, channels: 1, interleaved: false
        )!
        guard let converter = AVAudioConverter(from: file.processingFormat, to: target) else {
            throw AudioRecorderError.converterUnavailable
        }
        converter.downmix = true
        var result: [Float] = []
        let chunkFrames: AVAudioFrameCount = 16_384
        while file.framePosition < file.length {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
                break
            }
            try file.read(into: buffer, frameCount: chunkFrames)
            if buffer.frameLength == 0 { break }
            if let converted = convert(buffer, with: converter, to: target) {
                result.append(contentsOf: converted)
            }
        }
        return result
    }

    /// Rough loudness for the HUD meter: RMS mapped from about -50…0 dBFS to 0…1.
    public static func level(of samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        let rms = (sum / Float(samples.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return min(max((db + 50) / 50, 0), 1)
    }

    /// Float samples → base64 of signed 16-bit little-endian PCM (the engine's wire format).
    public static func pcm16Base64(_ samples: [Float]) -> String {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (index, sample) in samples.enumerated() {
                let clamped = min(max(sample, -1), Float(Int16.max) / 32768)
                out[index] = Int16(clamped * 32768).littleEndian
            }
        }
        return data.base64EncodedString()
    }
}
