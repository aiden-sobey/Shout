import Foundation

/// How much memory the engine needs for a model and precision, for the hints in Settings.
///
/// Peak memory of the engine process after loading the model and transcribing a 9 s clip
/// (Apple M5, 6 threads, pyannote voice detection), measured with a fresh process per
/// combination; see README → Performance. medium.en and distil-large-v3 weren't downloaded
/// when this was measured, so theirs are estimates from their size relative to the others.
public enum ModelFootprint {
    public struct Memory: Equatable, Sendable {
        public let gigabytes: Double
        public let measured: Bool

        /// e.g. "~1.5 GB", or "~2.4 GB est." for unmeasured models.
        public var label: String {
            String(format: "~%.1f GB", gigabytes) + (measured ? "" : " est.")
        }
    }

    private struct Entry {
        let int8: Double
        let float32: Double
        let measured: Bool
    }

    private static let table: [String: Entry] = [
        "tiny.en": Entry(int8: 0.89, float32: 0.96, measured: true),
        "base.en": Entry(int8: 1.01, float32: 1.13, measured: true),
        "small.en": Entry(int8: 1.49, float32: 2.06, measured: true),
        "medium.en": Entry(int8: 2.4, float32: 4.2, measured: false),
        "distil-large-v3": Entry(int8: 2.6, float32: 4.3, measured: false),
        "large-v3-turbo": Entry(int8: 2.65, float32: 4.42, measured: true),
    ]

    /// Nil for models or precisions there's no figure for.
    public static func memory(model: String, computeType: String) -> Memory? {
        guard let entry = table[model] else { return nil }
        switch computeType {
        // On the CPU, int8 and int8_float32 measured identically.
        case "int8", "int8_float32": return Memory(gigabytes: entry.int8, measured: entry.measured)
        case "float32": return Memory(gigabytes: entry.float32, measured: entry.measured)
        default: return nil
        }
    }
}
