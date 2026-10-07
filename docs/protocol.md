# Shout app ⇄ engine protocol

The app starts the engine as a child process and talks to it over stdio:

```
<engine>/.venv/bin/python -m shout_engine
```

- **Transport:** JSON Lines, UTF-8. Each message is one JSON object on one line. The app writes requests to stdin and the engine writes responses and events to stdout.
- **stderr** is free-form logging. The app appends it to `~/Library/Logs/Shout/engine.log`. The engine reroutes everything libraries print to stderr, so stdout carries protocol messages only.
- **Lifetime:** the engine exits when stdin closes or when it receives `shutdown`. It never outlives the app.
- **Ordering:** requests are handled one at a time, in the order they arrive.

## Messages

| Kind | Direction | Shape |
|---|---|---|
| Request | app → engine | `{"id": "<string>", "op": "<op>", ...params}` |
| Success | engine → app | `{"id": "<same id>", "ok": true, "result": {...}}` |
| Failure | engine → app | `{"id": "<same id>", "ok": false, "error": {"code": "<code>", "message": "<text>"}}` |
| Event | engine → app | `{"event": "<name>", ...fields}`, with no `id` |

A request that can't be parsed far enough to read its `id` gets a failure with `"id": null`.

### Error codes

| Code | Meaning |
|---|---|
| `bad_request` | Invalid JSON, a missing field or a field of the wrong type |
| `unknown_op` | `op` isn't one listed below |
| `model_not_found` | The model isn't downloaded. Run `shout-engine download <model>`. |
| `model_not_loaded` | `transcribe` was sent before a successful `load_model` |
| `unsupported_compute_type` | The CPU doesn't support this compute type. `status` lists the supported ones. |
| `not_implemented` | Reserved for meeting-mode features (`align: true`, diarization) |
| `internal` | Unexpected exception. The traceback is in the engine log. |

## Events

| Event | Fields | When |
|---|---|---|
| `ready` | `engine_version`, `whisperx_version` | Once, after start-up, before any request is read |
| `model_loading` | `model`, `compute_type` | When `load_model` starts its slow part |

## Operations

### `status`

No params.

```json
→ {"id":"1","op":"status"}
← {"id":"1","ok":true,"result":{
     "engine_version":"0.1.0","whisperx_version":"3.8.6","python_version":"3.12.x",
     "models_dir":"/Users/me/Library/Application Support/Shout/models",
     "downloaded_models":["small.en"],
     "supported_compute_types":["float32","int8","int8_float32"],
     "silero_vad_downloaded":false,
     "loaded":{"model":"small.en","compute_type":"int8","threads":6,"vad_method":"pyannote","beam_size":5}}}
```

`loaded` is `null` until a model has been loaded. `silero_vad_downloaded` says whether `vad_method: "silero"` can be used (`shout-engine download silero-vad`).

### `load_model`

| Param | Type | Notes |
|---|---|---|
| `model` | string | e.g. `"small.en"`. Must already be downloaded. |
| `compute_type` | string | e.g. `"int8"`. Must be in `supported_compute_types`. |
| `threads` | int ≥ 1 | CPU threads for CTranslate2 and torch |
| `vad_method` | `"pyannote"` \| `"silero"` | Voice-activity detection used to cut audio into speech chunks |
| `beam_size` | int 1–10 | 1 = greedy decoding (fastest) |

The engine sends `model_loading`, loads the model (offline only), runs one warm-up transcription, and replies:

```json
← {"id":"2","ok":true,"result":{"model":"small.en","compute_type":"int8","load_ms":2140,"warmup_ms":480}}
```

Sending `load_model` again replaces the loaded model. If loading fails, the previous model stays loaded.

### `transcribe`

| Param | Type | Notes |
|---|---|---|
| `sample_rate` | int | Must be `16000` |
| `pcm_s16le_b64` | string | Base64 of mono, signed 16-bit little-endian PCM samples |
| `options.initial_prompt` | string \| null | Context text that nudges spelling and style. Optional. |
| `options.hotwords` | string \| null | Words to favour, such as names and jargon. Optional. |
| `options.align` | bool | Must be `false` in v1. `true` returns `not_implemented`. |
| `options.format_lists` | bool | Default `false`. Puts a spoken numbered list ("1, … 2, …") on separate lines as "1. …". Only applies when the numbers count up from 1 with at least two items of two or more words. Applied to `text` only, not `segments`. See `formatting.py`. |
| `options.spelling` | `"en-US"` \| `"en-GB"` | Default `"en-US"`. `"en-GB"` rewrites American spellings to British (recognise, colour). Words whose spelling depends on meaning (meter, program, license, practice…) are left alone. See `spelling.py`. |

Audio longer than 10 minutes is rejected with `bad_request`.

```json
→ {"id":"3","op":"transcribe","sample_rate":16000,"pcm_s16le_b64":"...","options":{"initial_prompt":null,"hotwords":null,"align":false,"spelling":"en-GB","format_lists":true}}
← {"id":"3","ok":true,"result":{"text":"Hello world.","segments":[{"start":0.03,"end":1.2,"text":"Hello world."}],"audio_ms":2400,"transcribe_ms":610}}
```

- `text` is the segment texts, each trimmed and joined with single spaces.
- `text` is `""` when voice detection finds no speech. The app should insert nothing in that case.

### `shutdown`

No params. The engine replies `{"id":..., "ok":true, "result":{}}` and exits with status 0.

## Planned for meeting mode (not implemented)

- `transcribe_file {path, align, diarize}`, with `progress` events (`{"event":"progress","id":...,"fraction":0.42}`).
- Diarization needs a Hugging Face token. The app passes it to the engine through the `HF_TOKEN` environment variable at spawn, never in a message.
