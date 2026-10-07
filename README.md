# Shout

Push-to-talk dictation for macOS, running using a local model - [WhisperX](https://github.com/m-bain/whisperX).
Hold a hotkey, speak, let go, and the text appears in whatever text field you're typing in, in any app. Nothing leaves your Mac.

## Setup

You need macOS 14 or later, Apple Silicon, the Xcode Command Line Tools and [`uv`](https://docs.astral.sh/uv/).

```bash
make engine-setup                  # creates engine/.venv with WhisperX (~1 GB)
make engine-download MODEL=small.en
make install                       # builds, signs, copies to ~/Applications/Shout.app and opens it
```

On first launch a window asks for two permissions - microphone & accessibility.

## Using it

- **Hold the hotkey**, speak, release. The text is pasted where your cursor is.
- **Cancel:** press Esc, or any other key, while holding.
- **Mistaken presses are ignored**, so brushing the key does nothing.
- **Menu-bar icon:** 🎙 ready, red 🎙 recording, ⋯ transcribing, ⚠︎ needs attention.
- **If you switch apps** before the text is ready, it goes to the clipboard instead of being pasted.
- **Password fields:** when Secure Input is on, Shout won't record or insert.

### Settings

| Setting | Default | Notes |
|---|---|---|
| Model | `small.en` | Size of the model to use. Larger has greater accuracy, but consumes more memory. |
| Precision | `int8` | Whatever the CPU supports. On an M5: `int8`, `int8_float32`, `float32`. |
| Insertion method | Paste | **Type** sends keystrokes instead. It's slower but leaves the clipboard alone. |
| Restore clipboard | on, 250 ms | Delay before restoring your previous clip board item. |
| Spelling | British | Whisper's English models write American spelling. British rewrites it afterwards using [breame](https://github.com/cdpierse/breame)'s word list. |
| Custom vocabulary | – | Names and jargon, sent to Whisper as `hotwords` |

## Performance

Run `make bench` to measure performance on your machine.

Below is measured on an Apple M5 with 32 GB RAM. WhisperX runs on the CPU only on macOS, because CTranslate2 has no Metal backend.

| Model | int8 | float32 | 9 s clip, int8 → float32 |
|---|---|---|---|
| tiny.en | 0.89 GB | 0.96 GB | 0.25 → 0.22 s |
| base.en | 1.01 GB | 1.13 GB | 0.36 → 0.34 s |
| small.en | 1.49 GB | 2.06 GB | 1.0 → 1.3 s |
| large-v3-turbo | 2.65 GB | 4.42 GB | 3.7 → 2.2 s |
| medium.en | ~2.4 GB (estimate) | ~4.2 GB (estimate) | not measured |
| distil-large-v3 | ~2.6 GB (estimate) | ~4.3 GB (estimate) | not measured |

## Development

Structure:
- **`app/`** is a native Swift menu-bar app. It handles the hotkey, microphone, text insertion, permissions and UI. It has no Dock icon.
- **`engine/`** is a Python process that keeps WhisperX loaded. The app starts it and talks to it over stdin and stdout (see [`docs/protocol.md`](docs/protocol.md)). It needs no permissions of its own.

```bash
make test             # fast tests: engine (pytest) + app (swift-testing), no model needed
make test-engine-slow # real WhisperX transcription (needs small.en and tiny.en)
make self-test        # the built app drives the real engine on a fixture, no UI or permissions
make app              # debug build; SHOUT_ENGINE_DIR=$PWD/engine swift run --package-path app
```

Logs:

- `~/Library/Logs/Shout/engine.log` (engine stderr) and `download.log`.
- App logs are in Console.app under subsystem `dev.local.Shout`. **Transcripts and keystrokes are never logged.**

### Signing

macOS ties permissions to the app's code signature. Ad-hoc signed builds are identified by a hash of the binary, so **every rebuild loses Accessibility and Microphone access**. Create a self-signed certificate once and every build keeps the same identity:

```bash
scripts/make-dev-cert.sh   # adds "Shout Dev" to your login keychain (undo: security delete-identity -c "Shout Dev")
make install               # now signs with it
```

Then grant both permissions one last time. If an old **Shout** entry is already in the Accessibility list, remove it with **−** first. It belongs to an ad-hoc build and will never match again.

`bundle.sh` refuses to fall back to ad-hoc signing when the certificate exists but can't be used. If it reports `errSecInternalComponent`, run it from a normal Terminal (not a sandboxed shell) and choose **Always Allow** if macOS asks to use the key.

> ⚠️ On a company-managed Mac, check with IT before adding a code-signing certificate or giving a self-built app Accessibility access. Device-management profiles can block either.

## Troubleshooting

| Symptom | Fix |
|---|---|
| Hotkey does nothing anywhere | Check the menu for "Hotkey not active". Re-add Shout under Accessibility (remove it with −, then add it again after a rebuild). If it still fails, also allow it under Input Monitoring. |
| Hotkey stops working in one app | That app has Secure Input on (password field, Terminal → Secure Keyboard Entry, some password managers). The menu shows a warning. |
| "isn't downloaded" | Settings → Model → Download, or `make engine-download MODEL=…` |
| Engine crashed | See `~/Library/Logs/Shout/engine.log`. Settings → Advanced → Restart engine. |
| Old clipboard pasted instead of the transcript | Raise "Restore after" in Settings → General |
| Paste doesn't work with Dvorak/Colemak | Shout sends the key in the "V" position of a US layout. Use Type mode. |

## Not done yet

- Picking a specific microphone.
- Adding a leading space or capital based on the text before the cursor.
- Meeting notes: system-audio capture, alignment and diarization. The protocol reserves `align` and diarization for this.
