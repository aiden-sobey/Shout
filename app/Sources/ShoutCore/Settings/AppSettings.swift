import Foundation
import Observation

public enum InsertionMethod: String, Codable, CaseIterable, Sendable {
    case paste
    case type

    public var label: String {
        switch self {
        case .paste: "Paste (fast, uses the clipboard)"
        case .type: "Type (slower, leaves the clipboard alone)"
        }
    }
}

public enum Spelling: String, Codable, CaseIterable, Sendable {
    case british = "en-GB"
    case american = "en-US"

    public var label: String {
        switch self {
        case .british: "British (recognise, colour)"
        case .american: "American (recognize, color)"
        }
    }
}

/// Every user setting, saved to UserDefaults as soon as it changes.
@MainActor
@Observable
public final class AppSettings {
    public static let models = [
        "tiny.en", "base.en", "small.en", "medium.en", "distil-large-v3", "large-v3-turbo",
    ]
    public static let vadMethods = ["pyannote", "silero"]

    public enum Defaults {
        public static let model = "small.en"
        public static let computeType = "int8"
        // From the Milestone 0 benchmark on an M5 (README): 6 threads beat 4, 8 and 10, and
        // greedy decoding (beam 1) takes a 9 s clip from ~1.5 s to ~1.1 s with near-identical text.
        public static let threads = 6
        public static let beamSize = 1
        public static let vadMethod = "pyannote"
        public static let restoreDelayMs = 250
    }

    @ObservationIgnored private let store: UserDefaults

    public var model: String { didSet { store.set(model, forKey: Key.model) } }
    public var computeType: String { didSet { store.set(computeType, forKey: Key.computeType) } }
    public var threads: Int { didSet { store.set(threads, forKey: Key.threads) } }
    public var beamSize: Int { didSet { store.set(beamSize, forKey: Key.beamSize) } }
    public var vadMethod: String { didSet { store.set(vadMethod, forKey: Key.vadMethod) } }
    public var hotkey: Hotkey { didSet { store.set(try? JSONEncoder().encode(hotkey), forKey: Key.hotkey) } }
    public var insertionMethod: InsertionMethod {
        didSet { store.set(insertionMethod.rawValue, forKey: Key.insertionMethod) }
    }
    public var restoreClipboard: Bool { didSet { store.set(restoreClipboard, forKey: Key.restoreClipboard) } }
    public var restoreDelayMs: Int { didSet { store.set(restoreDelayMs, forKey: Key.restoreDelayMs) } }
    public var customVocabulary: String { didSet { store.set(customVocabulary, forKey: Key.customVocabulary) } }
    public var spelling: Spelling { didSet { store.set(spelling.rawValue, forKey: Key.spelling) } }
    public var formatLists: Bool { didSet { store.set(formatLists, forKey: Key.formatLists) } }
    public var playSounds: Bool { didSet { store.set(playSounds, forKey: Key.playSounds) } }
    public var showHUD: Bool { didSet { store.set(showHUD, forKey: Key.showHUD) } }
    /// Empty means "use the folder baked into Info.plist by scripts/bundle.sh".
    public var engineDirectoryOverride: String {
        didSet { store.set(engineDirectoryOverride, forKey: Key.engineDirectoryOverride) }
    }

    public init(store: UserDefaults = .standard) {
        self.store = store
        model = store.string(forKey: Key.model) ?? Defaults.model
        computeType = store.string(forKey: Key.computeType) ?? Defaults.computeType
        threads = store.object(forKey: Key.threads) as? Int ?? Defaults.threads
        beamSize = store.object(forKey: Key.beamSize) as? Int ?? Defaults.beamSize
        vadMethod = store.string(forKey: Key.vadMethod) ?? Defaults.vadMethod
        hotkey = store.data(forKey: Key.hotkey).flatMap { try? JSONDecoder().decode(Hotkey.self, from: $0) }
            ?? .default
        insertionMethod = store.string(forKey: Key.insertionMethod).flatMap(InsertionMethod.init) ?? .paste
        restoreClipboard = store.object(forKey: Key.restoreClipboard) as? Bool ?? true
        restoreDelayMs = store.object(forKey: Key.restoreDelayMs) as? Int ?? Defaults.restoreDelayMs
        customVocabulary = store.string(forKey: Key.customVocabulary) ?? ""
        spelling = store.string(forKey: Key.spelling).flatMap(Spelling.init) ?? .british
        formatLists = store.object(forKey: Key.formatLists) as? Bool ?? true
        playSounds = store.object(forKey: Key.playSounds) as? Bool ?? true
        showHUD = store.object(forKey: Key.showHUD) as? Bool ?? true
        engineDirectoryOverride = store.string(forKey: Key.engineDirectoryOverride) ?? ""
    }

    public var modelConfig: ModelConfig {
        ModelConfig(model: model, computeType: computeType, threads: threads, vadMethod: vadMethod, beamSize: beamSize)
    }

    public var transcribeOptions: TranscribeOptions {
        let vocabulary = customVocabulary.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscribeOptions(
            initialPrompt: nil,
            hotwords: vocabulary.isEmpty ? nil : vocabulary,
            align: false,
            spelling: spelling.rawValue,
            formatLists: formatLists
        )
    }

    /// The engine folder: the override if set, else `ShoutEngineDirectory` from Info.plist,
    /// else the `SHOUT_ENGINE_DIR` environment variable (handy for `swift run`).
    public var engineDirectory: URL? {
        let candidates = [
            engineDirectoryOverride,
            Bundle.main.object(forInfoDictionaryKey: "ShoutEngineDirectory") as? String ?? "",
            ProcessInfo.processInfo.environment["SHOUT_ENGINE_DIR"] ?? "",
        ]
        guard let path = candidates.first(where: { !$0.isEmpty && !$0.hasPrefix("$(") }) else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    private enum Key {
        static let model = "model"
        static let computeType = "computeType"
        static let threads = "threads"
        static let beamSize = "beamSize"
        static let vadMethod = "vadMethod"
        static let hotkey = "hotkey"
        static let insertionMethod = "insertionMethod"
        static let restoreClipboard = "restoreClipboard"
        static let restoreDelayMs = "restoreDelayMs"
        static let customVocabulary = "customVocabulary"
        static let spelling = "spelling"
        static let formatLists = "formatLists"
        static let playSounds = "playSounds"
        static let showHUD = "showHUD"
        static let engineDirectoryOverride = "engineDirectoryOverride"
    }
}
