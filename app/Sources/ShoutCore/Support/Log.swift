import Foundation
import os

/// Logging rules: timings, states and errors only. Never log keystrokes or transcript text.
public enum Log {
    public static let subsystem = "dev.local.Shout"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let dictation = Logger(subsystem: subsystem, category: "dictation")
    public static let engine = Logger(subsystem: subsystem, category: "engine")
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let insert = Logger(subsystem: subsystem, category: "insert")

    /// ~/Library/Logs/Shout
    public static var directory: URL {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Shout", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A handle that appends to `name` in the log directory, creating it if needed.
    ///
    /// Opened with O_APPEND so every write lands at the current end of the file, even when
    /// an exiting engine and its replacement write at the same time, or the file is truncated.
    public static func appendingHandle(named name: String) -> FileHandle? {
        let path = directory.appendingPathComponent(name).path
        let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else { return nil }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
