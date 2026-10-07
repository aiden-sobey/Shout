import AppKit
import Foundation
import Observation

// Seams so the state machine can be tested without a microphone, engine or keyboard.

@MainActor
public protocol AudioRecording: AnyObject {
    func start() throws
    func stop() -> [Float]
    func cancel()
}

@MainActor
public protocol Transcribing: AnyObject {
    var isReady: Bool { get }
    func transcribe(_ samples: [Float]) async throws -> TranscriptionResult
}

@MainActor
public protocol TextInserting: AnyObject {
    func insert(_ text: String, targetPID: pid_t?) async -> InsertOutcome
}

@MainActor
public protocol SystemContext: AnyObject {
    var frontmostPID: pid_t? { get }
    var isSecureInputEnabled: Bool { get }
}

public enum DictationState: Equatable, Sendable {
    case idle
    case recording
    case transcribing
    case inserting
}

/// A short message for the HUD and menu, e.g. "No speech detected".
public struct DictationNotice: Equatable, Sendable {
    public enum Kind: Sendable { case info, warning, error }
    public var kind: Kind
    public var message: String
}

public struct TranscriptRecord: Equatable, Identifiable, Sendable {
    public let id = UUID()
    public let text: String
    public let date: Date
}

public struct DictationTiming {
    public var minimumHold: Duration = .milliseconds(250)
    public var releaseTail: Duration = .milliseconds(150)
    public var maximumRecording: Duration = .seconds(300)
    public var noticeDuration: Duration = .seconds(2.5)

    public init() {}
}

/// Hold-to-talk: hotkey down → record, hotkey up → transcribe → insert.
@MainActor
@Observable
public final class DictationController {
    public private(set) var state: DictationState = .idle
    public private(set) var notice: DictationNotice?
    public private(set) var recent: [TranscriptRecord] = []
    public static let recentLimit = 10

    /// Called when recording starts, stops (with or without a result) or fails, for sounds.
    @ObservationIgnored public var onCue: ((Cue) -> Void)?
    public enum Cue { case start, stop, cancel, error }

    @ObservationIgnored private let recorder: AudioRecording
    @ObservationIgnored private let engine: Transcribing
    @ObservationIgnored private let inserter: TextInserting
    @ObservationIgnored private let system: SystemContext
    @ObservationIgnored private let timing: DictationTiming
    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var pressedAt: ContinuousClock.Instant?
    @ObservationIgnored private var targetPID: pid_t?
    @ObservationIgnored private var maxDurationTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Bumped on every new recording so a stale async step can tell it's been superseded.
    @ObservationIgnored private var session = 0

    public init(
        recorder: AudioRecording,
        engine: Transcribing,
        inserter: TextInserting,
        system: SystemContext,
        timing: DictationTiming = DictationTiming()
    ) {
        self.recorder = recorder
        self.engine = engine
        self.inserter = inserter
        self.system = system
        self.timing = timing
    }

    public func handle(_ action: HotkeyAction) {
        switch action {
        case .pressed: hotkeyPressed()
        case .released: Task { await hotkeyReleased() }
        case .cancelled: cancelRecording()
        }
    }

    /// The audio device changed mid-recording; keep what we have.
    public func recordingInterrupted() {
        guard state == .recording else { return }
        Task { await hotkeyReleased(skipTail: true) }
    }

    public func pasteLastTranscript() async {
        guard let last = recent.first else { return }
        let outcome = await inserter.insert(last.text, targetPID: nil)
        report(outcome)
    }

    // MARK: - Steps

    private func hotkeyPressed() {
        guard state == .idle else { return }
        if system.isSecureInputEnabled {
            show(.init(kind: .warning, message: "Secure input is on — can't dictate here"))
            onCue?(.error)
            return
        }
        guard engine.isReady else {
            show(.init(kind: .warning, message: "Engine isn't ready yet"))
            onCue?(.error)
            return
        }
        let startRequested = clock.now
        do {
            try recorder.start()
            Log.dictation.info("Microphone started in \((self.clock.now - startRequested).milliseconds) ms")
        } catch {
            show(.init(kind: .error, message: error.localizedDescription))
            onCue?(.error)
            return
        }
        session += 1
        targetPID = system.frontmostPID
        pressedAt = clock.now
        notice = nil
        state = .recording
        onCue?(.start)
        let thisSession = session
        maxDurationTask = Task { [timing] in
            try? await Task.sleep(for: timing.maximumRecording)
            guard !Task.isCancelled, self.session == thisSession, self.state == .recording else { return }
            Log.dictation.notice("Maximum recording length reached")
            await self.hotkeyReleased()
        }
    }

    private func hotkeyReleased(skipTail: Bool = false) async {
        guard state == .recording, let pressedAt else { return }
        let thisSession = session
        maxDurationTask?.cancel()
        let held = clock.now - pressedAt
        if held < timing.minimumHold {
            recorder.cancel()
            finish()
            return
        }
        // Keep the mic open a moment so the last word isn't clipped.
        state = .transcribing
        if !skipTail { try? await Task.sleep(for: timing.releaseTail) }
        guard session == thisSession else { return }
        let samples = recorder.stop()
        onCue?(.stop)

        let releasedAt = clock.now
        let result: TranscriptionResult
        do {
            result = try await engine.transcribe(samples)
        } catch {
            Log.dictation.error("Transcription failed: \(error.localizedDescription)")
            show(.init(kind: .error, message: error.localizedDescription))
            onCue?(.error)
            finish()
            return
        }
        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            show(.init(kind: .info, message: "No speech detected"))
            finish()
            return
        }

        state = .inserting
        recent.insert(TranscriptRecord(text: text, date: Date()), at: 0)
        if recent.count > Self.recentLimit { recent.removeLast(recent.count - Self.recentLimit) }
        let outcome = await inserter.insert(text, targetPID: targetPID)
        let total = clock.now - releasedAt
        Log.dictation.info(
            "audio \(result.audioMs) ms, engine \(result.transcribeMs) ms, release→inserted \(total.milliseconds) ms, \(text.count) chars, outcome \(String(describing: outcome))"
        )
        report(outcome)
        finish()
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        maxDurationTask?.cancel()
        recorder.cancel()
        onCue?(.cancel)
        finish()
    }

    private func finish() {
        pressedAt = nil
        targetPID = nil
        state = .idle
    }

    private func report(_ outcome: InsertOutcome) {
        switch outcome {
        case .inserted, .empty: break
        case .copiedBecauseFocusChanged:
            show(.init(kind: .info, message: "Copied — focus changed"))
        case .blockedBySecureInput:
            show(.init(kind: .warning, message: "Secure input is on — not inserted"))
        }
    }

    private func show(_ newNotice: DictationNotice) {
        notice = newNotice
        noticeTask?.cancel()
        noticeTask = Task { [timing] in
            try? await Task.sleep(for: timing.noticeDuration)
            guard !Task.isCancelled else { return }
            if self.notice == newNotice { self.notice = nil }
        }
    }
}

extension Duration {
    var milliseconds: Int {
        let (seconds, attoseconds) = components
        return Int(seconds * 1000 + attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: - Live implementations of the seams

extension AudioRecorder: AudioRecording {}

@MainActor
public final class LiveSystemContext: SystemContext {
    public init() {}
    public var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    public var isSecureInputEnabled: Bool { SecureInput.isEnabled }
}

/// Adapts the supervisor to `Transcribing`, reading the vocabulary from settings each time.
@MainActor
public final class LiveTranscriber: Transcribing {
    private let supervisor: EngineSupervisor
    private let settings: AppSettings

    public init(supervisor: EngineSupervisor, settings: AppSettings) {
        self.supervisor = supervisor
        self.settings = settings
    }

    public var isReady: Bool { supervisor.isReady }

    public func transcribe(_ samples: [Float]) async throws -> TranscriptionResult {
        try await supervisor.transcribe(samples, options: settings.transcribeOptions)
    }
}

@MainActor
public final class LiveInserter: TextInserting {
    private let inserter: TextInserter
    private let settings: AppSettings

    public init(inserter: TextInserter, settings: AppSettings) {
        self.inserter = inserter
        self.settings = settings
    }

    public func insert(_ text: String, targetPID: pid_t?) async -> InsertOutcome {
        let insertion = InsertionSettings(
            method: settings.insertionMethod,
            restoreClipboard: settings.restoreClipboard,
            restoreDelay: .milliseconds(settings.restoreDelayMs)
        )
        return await inserter.insert(text, targetPID: targetPID, settings: insertion)
    }
}
