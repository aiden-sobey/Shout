import Foundation

public enum EngineError: LocalizedError, Equatable {
    case notRunning
    case engineMissing(String)
    case exited(Int32)
    case timedOut(String)
    case remote(code: String, message: String)
    case badResponse(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "The transcription engine isn't running."
        case let .engineMissing(path): "No engine found at \(path). Run `make engine-setup`."
        case let .exited(status): "The transcription engine stopped (exit status \(status))."
        case let .timedOut(op): "The engine took too long to answer `\(op)`."
        case let .remote(_, message): message
        case let .badResponse(detail): "The engine sent something unexpected: \(detail)"
        }
    }

    public var remoteCode: String? {
        if case let .remote(code, _) = self { return code }
        return nil
    }
}

/// Where the engine lives and how to start it.
public struct EngineLaunch: Sendable {
    public var python: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var stderrLogName: String?

    public init(python: URL, arguments: [String], environment: [String: String] = [:], stderrLogName: String? = nil) {
        self.python = python
        self.arguments = arguments
        self.environment = environment
        self.stderrLogName = stderrLogName
    }

    /// `<engineDirectory>/.venv/bin/python -m shout_engine`, offline, logging to engine.log.
    public static func standard(engineDirectory: URL, threads: Int) -> EngineLaunch {
        EngineLaunch(
            python: engineDirectory.appendingPathComponent(".venv/bin/python"),
            arguments: ["-m", "shout_engine"],
            environment: [
                "HF_HUB_OFFLINE": "1",
                "TOKENIZERS_PARALLELISM": "false",
                "OMP_NUM_THREADS": String(threads),
                "PYTHONUNBUFFERED": "1",
            ],
            stderrLogName: "engine.log"
        )
    }
}

/// One engine process and the JSON Lines conversation with it.
///
/// Restarting after a crash is the caller's job (see `EngineSupervisor`): when the process
/// exits, every waiting request fails with `.exited` and `onExit` is called.
public actor EngineClient {
    public typealias EventHandler = @Sendable (String, [String: Any]) -> Void

    private let launch: EngineLaunch
    private var process: Process?
    private var stdin: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var pending: [String: CheckedContinuation<Data, Error>] = [:]
    private var readyWaiter: CheckedContinuation<Void, Error>?
    private var isReady = false
    private var nextID = 1
    private var onExit: (@Sendable (Int32) -> Void)?
    private var onEvent: EventHandler?

    public init(launch: EngineLaunch) {
        self.launch = launch
    }

    public func setHandlers(onExit: (@Sendable (Int32) -> Void)?, onEvent: EventHandler?) {
        self.onExit = onExit
        self.onEvent = onEvent
    }

    /// Starts the process and waits for its `ready` event.
    public func start(readyTimeout: Duration = .seconds(60)) async throws {
        guard process == nil else { return }
        guard FileManager.default.isExecutableFile(atPath: launch.python.path) else {
            throw EngineError.engineMissing(launch.python.path)
        }

        let process = Process()
        process.executableURL = launch.python
        process.arguments = launch.arguments
        process.environment = ProcessInfo.processInfo.environment.merging(launch.environment) { _, new in new }
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        if let name = launch.stderrLogName, let log = Log.appendingHandle(named: name) {
            process.standardError = log
        } else {
            process.standardError = FileHandle.nullDevice
        }
        process.terminationHandler = { [weak self] finished in
            let status = finished.terminationStatus
            Task { await self?.processExited(finished, status: status) }
        }

        try process.run()
        self.process = process
        self.stdin = stdinPipe.fileHandleForWriting
        self.isReady = false
        Log.engine.info("Engine started (pid \(process.processIdentifier))")

        let output = stdoutPipe.fileHandleForReading
        readerTask = Task.detached { [weak self] in
            do {
                for try await line in output.bytes.lines {
                    await self?.handle(line: line)
                }
            } catch {
                Log.engine.error("Engine stdout read failed: \(error.localizedDescription)")
            }
        }

        try await withTimeout(readyTimeout, op: "ready", onTimeout: { await self.readyTimedOut() }) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                Task { await self.registerReadyWaiter(continuation) }
            }
        }
    }

    public func status() async throws -> EngineStatus {
        try await send("status", NoParams(), timeout: .seconds(30))
    }

    public func loadModel(_ config: ModelConfig) async throws -> LoadModelResult {
        // First loads of large models can be slow; the warm-up adds a bit more.
        try await send("load_model", config, timeout: .seconds(300))
    }

    public func transcribe(samples: [Float], options: TranscribeOptions) async throws -> TranscriptionResult {
        let params = TranscribeParams(
            sampleRate: Int(AudioRecorder.sampleRate),
            pcmS16leB64: AudioConversion.pcm16Base64(samples),
            options: options
        )
        // Generous: a 5-minute recording on a slow model can take a while on the CPU.
        let seconds = 30 + Double(samples.count) / AudioRecorder.sampleRate * 2
        return try await send("transcribe", params, timeout: .seconds(seconds))
    }

    /// Asks the engine to exit, then makes sure it has.
    public func shutdown() async {
        guard process != nil else { return }
        let _: EmptyResult? = try? await send("shutdown", NoParams(), timeout: .seconds(3))
        terminate()
    }

    public func terminate() {
        guard let process else { return }
        try? stdin?.close()
        if process.isRunning { process.terminate() }
    }

    // MARK: - Internals

    private func registerReadyWaiter(_ continuation: CheckedContinuation<Void, Error>) {
        if isReady {
            continuation.resume()
        } else if process == nil {
            continuation.resume(throwing: EngineError.notRunning)
        } else {
            readyWaiter = continuation
        }
    }

    private func readyTimedOut() {
        readyWaiter?.resume(throwing: EngineError.timedOut("ready"))
        readyWaiter = nil
        terminate()
    }

    private func send<Params: Encodable, Result: Decodable>(
        _ op: String, _ params: Params, timeout: Duration
    ) async throws -> Result {
        guard let stdin, process != nil else { throw EngineError.notRunning }
        let id = String(nextID)
        nextID += 1
        var encoded = try EngineCoding.encoder.encode(OutgoingRequest(id: id, op: op, params: params))
        encoded.append(0x0A)
        let line = encoded

        let data = try await withTimeout(timeout, op: op, onTimeout: { await self.timedOut(id: id, op: op) }) {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                Task { await self.register(id: id, continuation: continuation, line: line, stdin: stdin) }
            }
        }
        do {
            return try EngineCoding.decoder.decode(ResultEnvelope<Result>.self, from: data).result
        } catch {
            throw EngineError.badResponse("\(op): \(error)")
        }
    }

    private func register(id: String, continuation: CheckedContinuation<Data, Error>, line: Data, stdin: FileHandle) {
        guard process != nil else {
            continuation.resume(throwing: EngineError.notRunning)
            return
        }
        pending[id] = continuation
        do {
            try stdin.write(contentsOf: line)
        } catch {
            pending.removeValue(forKey: id)?.resume(throwing: EngineError.notRunning)
        }
    }

    private func timedOut(id: String, op: String) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(throwing: EngineError.timedOut(op))
        // A stuck engine is no use; kill it so the supervisor restarts a fresh one.
        Log.engine.error("Engine timed out on \(op); terminating it")
        terminate()
    }

    private func handle(line: String) {
        let data = Data(line.utf8)
        guard let envelope = try? EngineCoding.decoder.decode(IncomingEnvelope.self, from: data) else {
            Log.engine.error("Ignoring non-protocol line from engine (\(line.count) chars)")
            return
        }
        if let event = envelope.event {
            if event == "ready" {
                isReady = true
                readyWaiter?.resume()
                readyWaiter = nil
            }
            let fields = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            onEvent?(event, fields)
            return
        }
        guard let id = envelope.id, let continuation = pending.removeValue(forKey: id) else {
            if let error = envelope.error {
                Log.engine.error("Engine error without request: \(error.code) \(error.message)")
            }
            return
        }
        if envelope.ok == true {
            continuation.resume(returning: data)
        } else {
            let error = envelope.error ?? RemoteError(code: "internal", message: "Unknown engine error")
            continuation.resume(throwing: EngineError.remote(code: error.code, message: error.message))
        }
    }

    private func processExited(_ finished: Process, status: Int32) {
        guard finished === process else { return }
        Log.engine.notice("Engine exited with status \(status)")
        process = nil
        stdin = nil
        isReady = false
        readerTask?.cancel()
        readerTask = nil
        readyWaiter?.resume(throwing: EngineError.exited(status))
        readyWaiter = nil
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: EngineError.exited(status))
        }
        onExit?(status)
    }
}

/// Runs `operation`, failing with `.timedOut` if it doesn't finish in time.
private func withTimeout<T: Sendable>(
    _ timeout: Duration,
    op: String,
    onTimeout: (@Sendable () async -> Void)? = nil,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw EngineError.timedOut(op) }
        if let value = first { return value }
        // The timer won. Let the owner fail the pending request, which ends `operation`.
        await onTimeout?()
        throw EngineError.timedOut(op)
    }
}
