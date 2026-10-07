@preconcurrency import AVFoundation
import Foundation
import Testing
@testable import ShoutCore

@Suite struct WireFormat {
    @Test func pcm16Base64() {
        let encoded = AudioConversion.pcm16Base64([0, 0.5, -0.5, 1, -1])
        let data = Data(base64Encoded: encoded)!
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }.map { Int16(littleEndian: $0) }
        #expect(values == [0, 16384, -16384, Int16.max, Int16.min])
    }

    @Test func loadModelRequestIsFlatAndSnakeCase() throws {
        let config = ModelConfig(model: "small.en", computeType: "int8", threads: 4, vadMethod: "pyannote", beamSize: 5)
        let data = try EngineCoding.encoder.encode(OutgoingRequest(id: "7", op: "load_model", params: config))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["id"] as? String == "7")
        #expect(object["op"] as? String == "load_model")
        #expect(object["compute_type"] as? String == "int8")
        #expect(object["vad_method"] as? String == "pyannote")
        #expect(object["beam_size"] as? Int == 5)
    }

    @Test func transcribeRequestKeys() throws {
        let params = TranscribeParams(
            sampleRate: 16000, pcmS16leB64: "AAA=", options: TranscribeOptions(hotwords: "Gridsight", spelling: "en-GB")
        )
        let data = try EngineCoding.encoder.encode(OutgoingRequest(id: "1", op: "transcribe", params: params))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["sample_rate"] as? Int == 16000)
        #expect(object["pcm_s16le_b64"] as? String == "AAA=")
        let options = object["options"] as! [String: Any]
        #expect(options["hotwords"] as? String == "Gridsight")
        #expect(options["align"] as? Bool == false)
        #expect(options["spelling"] as? String == "en-GB")
    }

    @Test func decodesStatus() throws {
        let line = """
        {"id":"1","ok":true,"result":{"engine_version":"0.1.0","whisperx_version":"3.8.6","python_version":"3.12.1",\
        "models_dir":"/tmp/m","downloaded_models":["small.en"],"supported_compute_types":["int8","float32"],\
        "loaded":{"model":"small.en","compute_type":"int8","threads":4,"vad_method":"pyannote","beam_size":5}}}
        """
        let status = try EngineCoding.decoder.decode(ResultEnvelope<EngineStatus>.self, from: Data(line.utf8)).result
        #expect(status.downloadedModels == ["small.en"])
        #expect(status.loaded?.computeType == "int8")
    }

    @Test func resamples48kTo16k() throws {
        let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let converter = try #require(AVAudioConverter(from: input, to: output))
        converter.downmix = true
        var total = 0
        for _ in 0..<600 {  // 60 s in 100 ms buffers
            let buffer = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 4800)!
            buffer.frameLength = 4800
            let converted = try #require(AudioConversion.convert(buffer, with: converter, to: output))
            total += converted.count
        }
        // The resampler holds back up to ~30 ms internally, but nothing should accumulate
        // over a long recording (a fixed-size, undrained output once lost ~1.5% of audio).
        #expect(abs(total - 960_000) < 800)
    }
}

/// Runs EngineClient against a tiny fake engine written in Python (system python3),
/// so these tests don't need WhisperX installed.
@Suite(.serialized) struct EngineClientAgainstStub {
    private static let stub = """
    import json, sys, os
    out = sys.stdout
    def send(m): out.write(json.dumps(m) + "\\n"); out.flush()
    print("this is noise on stderr", file=sys.stderr)
    send({"event": "ready", "engine_version": "stub", "whisperx_version": "none"})
    for line in sys.stdin:
        req = json.loads(line)
        op = req.get("op")
        if op == "status":
            send({"id": req["id"], "ok": True, "result": {"engine_version": "stub", "whisperx_version": "none",
                  "python_version": "3", "models_dir": "/tmp", "downloaded_models": ["tiny.en"],
                  "supported_compute_types": ["int8"], "loaded": None}})
        elif op == "load_model":
            if req["model"] != "tiny.en":
                send({"id": req["id"], "ok": False, "error": {"code": "model_not_found", "message": "nope"}})
            else:
                send({"event": "model_loading", "model": req["model"], "compute_type": req["compute_type"]})
                send({"id": req["id"], "ok": True, "result": {"model": "tiny.en", "compute_type": "int8", "load_ms": 1, "warmup_ms": 1}})
        elif op == "transcribe":
            if os.environ.get("STUB_CRASH") == "1":
                os._exit(3)
            n = len(req["pcm_s16le_b64"])
            send({"id": req["id"], "ok": True, "result": {"text": "stub heard %d" % n, "segments": [], "audio_ms": 0, "transcribe_ms": 0}})
        elif op == "shutdown":
            send({"id": req["id"], "ok": True, "result": {}})
            sys.exit(0)
    """

    private func makeClient(crash: Bool = false) throws -> EngineClient {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shout-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("stub.py")
        try Self.stub.write(to: script, atomically: true, encoding: .utf8)
        return EngineClient(launch: EngineLaunch(
            python: URL(fileURLWithPath: "/usr/bin/python3"),
            arguments: ["-I", script.path],
            environment: crash ? ["STUB_CRASH": "1"] : [:]
        ))
    }

    @Test func fullConversation() async throws {
        let client = try makeClient()
        try await client.start()
        let status = try await client.status()
        #expect(status.downloadedModels == ["tiny.en"])
        let config = ModelConfig(model: "tiny.en", computeType: "int8", threads: 2, vadMethod: "silero", beamSize: 1)
        let loaded = try await client.loadModel(config)
        #expect(loaded.model == "tiny.en")
        let result = try await client.transcribe(samples: [0, 0, 0], options: TranscribeOptions())
        #expect(result.text == "stub heard 8")  // 3 samples → 6 bytes → 8 base64 chars
        await client.shutdown()
    }

    @Test func remoteErrorsAreTyped() async throws {
        let client = try makeClient()
        try await client.start()
        let config = ModelConfig(model: "huge", computeType: "int8", threads: 2, vadMethod: "silero", beamSize: 1)
        await #expect(throws: EngineError.remote(code: "model_not_found", message: "nope")) {
            _ = try await client.loadModel(config)
        }
        await client.shutdown()
    }

    @Test func crashFailsPendingRequestAndReportsExit() async throws {
        let client = try makeClient(crash: true)
        let exited = AsyncStream<Int32>.makeStream()
        await client.setHandlers(onExit: { exited.continuation.yield($0) }, onEvent: nil)
        try await client.start()
        await #expect(throws: EngineError.exited(3)) {
            _ = try await client.transcribe(samples: [0], options: TranscribeOptions())
        }
        var iterator = exited.stream.makeAsyncIterator()
        #expect(await iterator.next() == 3)
        await #expect(throws: EngineError.notRunning) {
            _ = try await client.status()
        }
    }

    @Test func missingPythonIsReported() async {
        let client = EngineClient(launch: EngineLaunch(python: URL(fileURLWithPath: "/nonexistent/python"), arguments: []))
        await #expect(throws: EngineError.engineMissing("/nonexistent/python")) {
            try await client.start()
        }
    }
}

@Suite struct Footprints {
    @Test func measuredAndEstimatedLabels() {
        #expect(ModelFootprint.memory(model: "small.en", computeType: "int8")?.label == "~1.5 GB")
        #expect(ModelFootprint.memory(model: "large-v3-turbo", computeType: "float32")?.label == "~4.4 GB")
        #expect(ModelFootprint.memory(model: "medium.en", computeType: "int8")?.label == "~2.4 GB est.")
    }

    @Test func int8Float32MatchesInt8() {
        #expect(ModelFootprint.memory(model: "base.en", computeType: "int8_float32")
            == ModelFootprint.memory(model: "base.en", computeType: "int8"))
    }

    @Test func unknownCombinationsHaveNoFigure() {
        #expect(ModelFootprint.memory(model: "small.en", computeType: "float16") == nil)
        #expect(ModelFootprint.memory(model: "huge.en", computeType: "int8") == nil)
    }

    @MainActor @Test func everyOfferedModelHasAFigure() {
        for model in AppSettings.models {
            #expect(ModelFootprint.memory(model: model, computeType: "int8") != nil, "\(model)")
        }
    }

    @Test func decodesSileroStatus() throws {
        let line = """
        {"id":"1","ok":true,"result":{"engine_version":"0.1.0","whisperx_version":"3.8.6","python_version":"3.12.1",\
        "models_dir":"/tmp/m","downloaded_models":[],"supported_compute_types":["int8"],\
        "silero_vad_downloaded":false,"loaded":null}}
        """
        let status = try EngineCoding.decoder.decode(ResultEnvelope<EngineStatus>.self, from: Data(line.utf8)).result
        #expect(status.sileroVadDownloaded == false)
    }
}
