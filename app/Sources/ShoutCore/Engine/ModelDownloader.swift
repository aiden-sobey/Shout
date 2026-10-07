import Foundation
import Observation

/// Runs `python -m shout_engine download <model>` (the only time the engine goes online).
@MainActor
@Observable
public final class ModelDownloader {
    public private(set) var downloading: String?
    public private(set) var lastError: String?

    public init() {}

    public func download(_ model: String, engineDirectory: URL) async -> Bool {
        guard downloading == nil else { return false }
        downloading = model
        lastError = nil
        defer { downloading = nil }

        let python = engineDirectory.appendingPathComponent(".venv/bin/python")
        let process = Process()
        process.executableURL = python
        process.arguments = ["-m", "shout_engine", "download", model]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = Log.appendingHandle(named: "download.log") ?? FileHandle.nullDevice
        Log.engine.info("Downloading model \(model)")

        let status: Int32 = await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: -1)
            }
        }
        if status != 0 {
            lastError = "Downloading \(model) failed — see ~/Library/Logs/Shout/download.log"
            Log.engine.error("Model download failed with status \(status)")
            return false
        }
        return true
    }
}
