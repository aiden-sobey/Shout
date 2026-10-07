import Foundation

// Swift mirrors of docs/protocol.md. Keys are converted to and from snake_case.

public struct ModelConfig: Codable, Equatable, Hashable, Sendable {
    public var model: String
    public var computeType: String
    public var threads: Int
    public var vadMethod: String
    public var beamSize: Int

    public init(model: String, computeType: String, threads: Int, vadMethod: String, beamSize: Int) {
        self.model = model
        self.computeType = computeType
        self.threads = threads
        self.vadMethod = vadMethod
        self.beamSize = beamSize
    }

    public var summary: String { "\(model) · \(computeType)" }
}

public struct TranscribeOptions: Codable, Equatable, Sendable {
    public var initialPrompt: String?
    public var hotwords: String?
    public var align: Bool
    /// "en-US" or "en-GB".
    public var spelling: String
    /// Put spoken numbered lists ("1, … 2, …") on separate lines.
    public var formatLists: Bool

    public init(
        initialPrompt: String? = nil,
        hotwords: String? = nil,
        align: Bool = false,
        spelling: String = "en-US",
        formatLists: Bool = false
    ) {
        self.initialPrompt = initialPrompt
        self.hotwords = hotwords
        self.align = align
        self.spelling = spelling
        self.formatLists = formatLists
    }
}

public struct EngineStatus: Decodable, Equatable, Sendable {
    public var engineVersion: String
    public var whisperxVersion: String
    public var pythonVersion: String
    public var modelsDir: String
    public var downloadedModels: [String]
    public var supportedComputeTypes: [String]
    /// Whether `vadMethod: "silero"` can be used. Nil from engines that predate the field.
    public var sileroVadDownloaded: Bool?
    public var loaded: ModelConfig?
}

public struct LoadModelResult: Decodable, Equatable, Sendable {
    public var model: String
    public var computeType: String
    public var loadMs: Int
    public var warmupMs: Int
}

public struct TranscriptSegment: Decodable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
}

public struct TranscriptionResult: Decodable, Equatable, Sendable {
    public var text: String
    public var segments: [TranscriptSegment]
    public var audioMs: Int
    public var transcribeMs: Int
}

public struct EmptyResult: Decodable, Equatable, Sendable {}

// MARK: - Wire envelopes

struct OutgoingRequest<Params: Encodable>: Encodable {
    let id: String
    let op: String
    let params: Params

    func encode(to encoder: Encoder) throws {
        // Params are flattened into the top-level object next to `id` and `op`.
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(id, forKey: Key("id"))
        try container.encode(op, forKey: Key("op"))
        try params.encode(to: encoder)
    }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

struct NoParams: Encodable {}

struct TranscribeParams: Encodable {
    let sampleRate: Int
    let pcmS16leB64: String
    let options: TranscribeOptions

    enum CodingKeys: String, CodingKey {
        case sampleRate = "sample_rate"
        case pcmS16leB64 = "pcm_s16le_b64"
        case options
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(pcmS16leB64, forKey: .pcmS16leB64)
        try container.encode(options, forKey: .options)
    }
}

/// The fields every incoming line may carry. The full line is kept for decoding `result`.
struct IncomingEnvelope: Decodable {
    let id: String?
    let event: String?
    let ok: Bool?
    let error: RemoteError?
}

struct RemoteError: Decodable, Equatable {
    let code: String
    let message: String
}

struct ResultEnvelope<Result: Decodable>: Decodable {
    let result: Result
}

enum EngineCoding {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()
}
