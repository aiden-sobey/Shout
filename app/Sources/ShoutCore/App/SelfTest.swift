import Foundation

/// `Shout --self-test <audio-file> [--model small.en] [--compute-type int8]`
///
/// Runs the real engine through `EngineClient` without any UI, microphone or permissions,
/// and prints the transcript and timings. Exit status 0 on success.
public enum SelfTest {
    @MainActor
    public static func run(arguments: [String]) async -> Int32 {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard let path = value(after: "--self-test") else {
            print("usage: Shout --self-test <audio-file> [--model NAME] [--compute-type TYPE]")
            return 2
        }
        let settings = AppSettings()
        guard let engineDirectory = settings.engineDirectory else {
            print("FAIL: engine folder unknown. Set SHOUT_ENGINE_DIR or build with scripts/bundle.sh.")
            return 1
        }
        var config = settings.modelConfig
        config.model = value(after: "--model") ?? config.model
        config.computeType = value(after: "--compute-type") ?? config.computeType

        let client = EngineClient(launch: .standard(engineDirectory: engineDirectory, threads: config.threads))
        do {
            let clock = ContinuousClock()
            var started = clock.now
            try await client.start()
            print("engine ready in \((clock.now - started).milliseconds) ms")

            let status = try await client.status()
            print("whisperx \(status.whisperxVersion), compute types \(status.supportedComputeTypes), downloaded \(status.downloadedModels)")

            let loaded = try await client.loadModel(config)
            print("loaded \(loaded.model) \(loaded.computeType) in \(loaded.loadMs) ms, warm-up \(loaded.warmupMs) ms")

            let samples = try AudioConversion.loadFile(URL(fileURLWithPath: path))
            started = clock.now
            let result = try await client.transcribe(samples: samples, options: settings.transcribeOptions)
            let roundTrip = (clock.now - started).milliseconds
            print("audio \(result.audioMs) ms, engine \(result.transcribeMs) ms, round trip \(roundTrip) ms")
            print("text: \(result.text)")
            await client.shutdown()
            return result.text.isEmpty ? 1 : 0
        } catch {
            print("FAIL: \(error.localizedDescription)")
            await client.terminate()
            return 1
        }
    }
}
