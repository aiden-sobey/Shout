import Foundation
import Observation

public enum EngineState: Equatable, Sendable {
    case stopped
    case starting
    case loadingModel(String)
    case ready(ModelConfig)
    case modelMissing(String)
    case failed(String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    public var label: String {
        switch self {
        case .stopped: "Engine stopped"
        case .starting: "Engine starting…"
        case let .loadingModel(model): "Loading \(model)…"
        case let .ready(config): "\(config.summary) · ready"
        case let .modelMissing(model): "\(model) isn't downloaded"
        case let .failed(message): message
        }
    }
}

/// Keeps one engine process alive with the model the settings ask for.
///
/// Restarts the engine after a crash (1 s, 2 s, then 5 s apart) and gives up after three
/// failures in a row. A successful model load resets the count.
@MainActor
@Observable
public final class EngineSupervisor {
    public private(set) var state: EngineState = .stopped
    public private(set) var status: EngineStatus?

    @ObservationIgnored private var client: EngineClient?
    @ObservationIgnored private var desired: ModelConfig
    @ObservationIgnored private var engineDirectory: URL?
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var restartTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let backoff: [Duration] = [.seconds(1), .seconds(2), .seconds(5)]

    public init(config: ModelConfig, engineDirectory: URL?) {
        self.desired = config
        self.engineDirectory = engineDirectory
    }

    public var isReady: Bool { state.isReady }

    /// How the silero detector is named in "… isn't downloaded".
    public static let sileroName = "Silero voice detection"

    public func start() {
        guard client == nil else { return }
        guard let engineDirectory else {
            state = .failed("Engine folder not set (see Settings → Advanced)")
            return
        }
        generation += 1
        let myGeneration = generation
        let client = EngineClient(launch: .standard(engineDirectory: engineDirectory, threads: desired.threads))
        self.client = client
        state = .starting
        let onExit: @Sendable (Int32) -> Void = { [weak self] status in
            Task { @MainActor in self?.engineExited(status: status, generation: myGeneration) }
        }
        let onEvent: EngineClient.EventHandler = { [weak self] event, fields in
            guard event == "model_loading", let model = fields["model"] as? String else { return }
            Task { @MainActor in self?.state = .loadingModel(model) }
        }
        Task {
            await client.setHandlers(onExit: onExit, onEvent: onEvent)
            do {
                try await client.start()
                guard myGeneration == generation else { return }
                await refreshStatus()
                await loadDesiredModel()
            } catch {
                guard myGeneration == generation else { return }
                Log.engine.error("Engine failed to start: \(error.localizedDescription)")
                switch error {
                case EngineError.exited, EngineError.timedOut:
                    break  // The process has exited (or is being killed); engineExited restarts it.
                default:
                    // The process never ran (e.g. missing venv). Nothing to retry until setup is fixed.
                    state = .failed(error.localizedDescription)
                    self.client = nil
                }
            }
        }
    }

    public func stop() async {
        generation += 1
        restartTask?.cancel()
        restartTask = nil
        let client = self.client
        self.client = nil
        state = .stopped
        await client?.shutdown()
    }

    public func restart() {
        Task {
            await stop()
            consecutiveFailures = 0
            start()
        }
    }

    /// Point at a different engine folder and restart.
    public func setEngineDirectory(_ url: URL?) {
        guard url != engineDirectory else { return }
        engineDirectory = url
        restart()
    }

    /// Load a different model or settings. Thread changes need a restart for OMP_NUM_THREADS.
    public func apply(_ config: ModelConfig) {
        guard config != desired else { return }
        let threadsChanged = config.threads != desired.threads
        desired = config
        if threadsChanged {
            restart()
        } else {
            Task { await loadDesiredModel() }
        }
    }

    public func refreshStatus() async {
        guard let client else { return }
        do {
            status = try await client.status()
        } catch {
            Log.engine.error("Engine status failed: \(error.localizedDescription)")
        }
    }

    public func transcribe(_ samples: [Float], options: TranscribeOptions) async throws -> TranscriptionResult {
        guard let client, state.isReady else { throw EngineError.notRunning }
        return try await client.transcribe(samples: samples, options: options)
    }

    private func loadDesiredModel() async {
        guard let client else { return }
        let config = desired
        if let status, !status.downloadedModels.contains(config.model) {
            state = .modelMissing(config.model)
            return
        }
        if config.vadMethod == "silero", status?.sileroVadDownloaded == false {
            state = .modelMissing(Self.sileroName)
            return
        }
        state = .loadingModel(config.model)
        do {
            let result = try await client.loadModel(config)
            guard config == desired else { return }  // settings changed meanwhile; a newer load is coming
            consecutiveFailures = 0
            state = .ready(config)
            Log.engine.info("Loaded \(result.model) \(result.computeType) in \(result.loadMs) ms (warm-up \(result.warmupMs) ms)")
            await refreshStatus()
        } catch let error as EngineError where error.remoteCode == "model_not_found" {
            // Either the Whisper model or (if the model is present) the silero detector.
            let modelPresent = status?.downloadedModels.contains(config.model) ?? false
            state = .modelMissing(modelPresent && config.vadMethod == "silero" ? Self.sileroName : config.model)
        } catch let error as EngineError {
            if case .exited = error { return }  // engineExited handles it
            state = .failed(error.localizedDescription)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func engineExited(status: Int32, generation exitedGeneration: Int) {
        guard exitedGeneration == generation else { return }
        client = nil
        consecutiveFailures += 1
        guard consecutiveFailures <= backoff.count else {
            state = .failed("Engine crashed — see ~/Library/Logs/Shout/engine.log")
            return
        }
        let delay = backoff[consecutiveFailures - 1]
        state = .starting
        Log.engine.notice("Restarting engine in \(delay) (attempt \(self.consecutiveFailures))")
        restartTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            start()
        }
    }
}
