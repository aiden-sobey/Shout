import Foundation
import Testing
@testable import ShoutCore

@MainActor
final class FakeRecorder: AudioRecording {
    var started = 0
    var stopped = 0
    var cancelled = 0
    var failStart = false

    func start() throws {
        if failStart { throw AudioRecorderError.noInputDevice }
        started += 1
    }
    func stop() -> [Float] { stopped += 1; return [Float](repeating: 0.1, count: 16_000) }
    func cancel() { cancelled += 1 }
}

@MainActor
final class FakeEngine: Transcribing {
    var isReady = true
    var text = "hello world"
    var error: Error?
    var calls = 0

    func transcribe(_ samples: [Float]) async throws -> TranscriptionResult {
        calls += 1
        if let error { throw error }
        return TranscriptionResult(text: text, segments: [], audioMs: 1000, transcribeMs: 100)
    }
}

@MainActor
final class FakeInserter: TextInserting {
    var inserted: [(String, pid_t?)] = []
    var outcome: InsertOutcome = .inserted

    func insert(_ text: String, targetPID: pid_t?) async -> InsertOutcome {
        inserted.append((text, targetPID))
        return outcome
    }
}

@MainActor
final class FakeSystem: SystemContext {
    var frontmostPID: pid_t? = 42
    var isSecureInputEnabled = false
}

@MainActor
@Suite struct DictationControllerTests {
    let recorder = FakeRecorder()
    let engine = FakeEngine()
    let inserter = FakeInserter()
    let system = FakeSystem()

    private func makeController(minimumHold: Duration = .zero) -> DictationController {
        var timing = DictationTiming()
        timing.minimumHold = minimumHold
        timing.releaseTail = .zero
        timing.noticeDuration = .seconds(60)
        return DictationController(recorder: recorder, engine: engine, inserter: inserter, system: system, timing: timing)
    }

    /// Lets the controller's async steps run to completion.
    private func settle(_ controller: DictationController) async {
        for _ in 0..<50 where controller.state != .idle {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func holdSpeakRelease() async {
        let controller = makeController()
        controller.handle(.pressed)
        #expect(controller.state == .recording)
        #expect(recorder.started == 1)
        controller.handle(.released)
        await settle(controller)
        #expect(controller.state == .idle)
        #expect(recorder.stopped == 1)
        #expect(inserter.inserted.count == 1)
        #expect(inserter.inserted.first?.0 == "hello world")
        #expect(inserter.inserted.first?.1 == 42)  // the app that was in front at key-down
        #expect(controller.recent.first?.text == "hello world")
    }

    @Test func shortTapIsDiscarded() async {
        let controller = makeController(minimumHold: .seconds(10))
        controller.handle(.pressed)
        controller.handle(.released)
        await settle(controller)
        #expect(recorder.cancelled == 1)
        #expect(engine.calls == 0)
        #expect(inserter.inserted.isEmpty)
    }

    @Test func cancelDuringRecording() async {
        let controller = makeController()
        controller.handle(.pressed)
        controller.handle(.cancelled)
        #expect(controller.state == .idle)
        #expect(recorder.cancelled == 1)
        controller.handle(.released)  // stray release after cancel does nothing
        await settle(controller)
        #expect(engine.calls == 0)
    }

    @Test func secureInputBlocksRecording() {
        system.isSecureInputEnabled = true
        let controller = makeController()
        controller.handle(.pressed)
        #expect(controller.state == .idle)
        #expect(recorder.started == 0)
        #expect(controller.notice?.kind == .warning)
    }

    @Test func engineNotReadyBlocksRecording() {
        engine.isReady = false
        let controller = makeController()
        controller.handle(.pressed)
        #expect(controller.state == .idle)
        #expect(recorder.started == 0)
    }

    @Test func emptyTranscriptInsertsNothing() async {
        engine.text = "   "
        let controller = makeController()
        controller.handle(.pressed)
        controller.handle(.released)
        await settle(controller)
        #expect(inserter.inserted.isEmpty)
        #expect(controller.notice?.message == "No speech detected")
        #expect(controller.recent.isEmpty)
    }

    @Test func engineErrorShowsNoticeAndReturnsToIdle() async {
        engine.error = EngineError.timedOut("transcribe")
        let controller = makeController()
        controller.handle(.pressed)
        controller.handle(.released)
        await settle(controller)
        #expect(controller.state == .idle)
        #expect(controller.notice?.kind == .error)
        #expect(inserter.inserted.isEmpty)
    }

    @Test func focusChangeIsReported() async {
        inserter.outcome = .copiedBecauseFocusChanged
        let controller = makeController()
        controller.handle(.pressed)
        controller.handle(.released)
        await settle(controller)
        #expect(controller.notice?.message == "Copied — focus changed")
    }

    @Test func pressWhileTranscribingIsIgnored() async {
        let controller = makeController()
        controller.handle(.pressed)
        controller.handle(.released)
        controller.handle(.pressed)
        await settle(controller)
        #expect(recorder.started == 1)
    }

    @Test func recentIsCapped() async {
        let controller = makeController()
        for index in 0..<(DictationController.recentLimit + 3) {
            engine.text = "line \(index)"
            controller.handle(.pressed)
            controller.handle(.released)
            await settle(controller)
        }
        #expect(controller.recent.count == DictationController.recentLimit)
        #expect(controller.recent.first?.text == "line \(DictationController.recentLimit + 2)")
    }

    @Test func recorderFailureShowsError() {
        recorder.failStart = true
        let controller = makeController()
        controller.handle(.pressed)
        #expect(controller.state == .idle)
        #expect(controller.notice?.kind == .error)
    }
}
