# Dictation Tool

An open-source, **bring-your-own-LLM** dictation tool for macOS.

Press the **`fn` (globe) key** once to start listening, press it again to stop.
Your speech is transcribed, handed to an LLM you configure to clean up and
organize it, and the result is typed straight into whatever app has focus.

The quality is in your hands: you pick the transcription backend, the LLM
provider/model, and — most importantly — the **system prompt** that controls how
your raw speech gets turned into polished, ready-to-send text.

> Status: **v0.1 — infrastructure.** The full pipeline works end to end. See the
> [Roadmap](#roadmap) for what's next.

---

## How it works

```
fn key (CGEventTap) ──toggle──▶ AudioRecorder (AVAudioEngine → 16 kHz mono WAV)
                                      │ stop
                                      ▼
                         Transcriber  ┌─ cloud  (Whisper-style API)
                          (protocol)  ├─ apple  (SFSpeechRecognizer, on-device)
                                      └─ local  (OpenAI Whisper, on-device Python helper)
                                      ▼ raw text
                         LLMProvider  ┌─ openaiCompatible (openai/gemini/deepseek/kimi/glm/…)
                          (protocol)  └─ anthropic        (claude /v1/messages)
                                      ▼ organized text
                         TextInserter (clipboard + ⌘V) ──▶ focused app
```

Everything behind `Transcriber` and `LLMProvider` is a swappable protocol, so
adding a backend is a single small file.

| Source file | Responsibility |
|---|---|
| `Hotkey/FnKeyMonitor.swift` | Global `fn`-key toggle via a `CGEventTap` |
| `Audio/AudioRecorder.swift` | Mic capture → 16 kHz mono WAV |
| `Transcription/*` | `Transcriber` protocol + cloud (Whisper), Apple & local Whisper backends |
| `LLM/*` | `LLMProvider` protocol + OpenAI-compatible & Anthropic backends |
| `Insertion/TextInserter.swift` | Inserts text into the focused app |
| `Pipeline/DictationController.swift` | Orchestrates record → transcribe → organize → insert |
| `App/*` | Menu-bar UI and app lifecycle |
| `Config/Config.swift` | `~/.config/dictation-tool/config.json` |

---

## Requirements

- macOS 13 or later
- Swift toolchain (Xcode or Command Line Tools — `xcode-select --install`)
- An API key for whatever cloud transcription / LLM provider you choose
  (not needed if you use the on-device Apple transcription backend with the LLM
  step disabled)
- For the `local` transcription backend: nothing up front — on first use the
  app offers a model picker, downloads the checkpoint, and provisions a
  private Python environment with
  [`openai-whisper`](https://github.com/openai/whisper) automatically
  (a `python3` on the machine is required, which the Xcode Command Line Tools
  already provide)

## Build & run

```bash
make run       # release build, assemble Dictation.app, and launch it
```

Other targets:

```bash
make bundle    # build + assemble .build/Dictation.app (no launch)
make install   # copy to /Applications and launch
make debug     # fast debug build, no bundle
make clean
```

> Run the **bundled app**, not a bare `swift run`. macOS attaches microphone and
> accessibility permissions to a signed bundle identity; a loose binary won't get
> a stable identity and permissions won't stick.

The app lives in the **menu bar** (no Dock icon). Click the 🎙️ glyph for the menu.

---

## Permissions (one-time setup)

On first launch macOS will prompt for these. If you miss a prompt, grant them in
**System Settings ▸ Privacy & Security**:

1. **Accessibility** — required to detect the `fn` key and to paste text.
   The app re-checks every 2 s, so just toggle it on and you're set.
2. **Microphone** — required to record audio.
3. **Speech Recognition** — only if you use the `apple` transcription backend.

### Make the `fn` key behave

By default macOS may pop the emoji picker or its own dictation when you press
`fn`. Two options:

- Leave `hotkey.suppressFnDefault: true` (default) — we swallow the bare `fn`
  event so the system action doesn't fire, **or**
- Set **System Settings ▸ Keyboard ▸ "Press 🌐 key to" → Do Nothing** for the
  cleanest behavior.

---

## Configuration

Config lives at `~/.config/dictation-tool/config.json` and is created on first
run. Edit it from the menu (**Open Config File…**) and apply changes with
**Reload Config** — no restart needed.

Keys can be set inline (`apiKey`) or pulled from an environment variable
(`apiKeyEnv`, used when `apiKey` is empty) so you can keep secrets out of the
file.

Defaults are zero-config: **Apple on-device transcription with the LLM step off**,
so it works immediately with no API key. Add a key and flip `llm.enabled` to turn
on the LLM polishing (the headline feature).

```jsonc
{
  "transcription": {
    "backend": "apple",                // "apple" (no key) | "cloud" | "local"
    "cloud": {
      "baseURL": "https://api.openai.com/v1",
      "model": "whisper-1",
      "apiKey": "",
      "apiKeyEnv": "OPENAI_API_KEY",
      "language": null                 // ISO-639-1 e.g. "en", or null = auto
    },
    "apple": {
      "locale": "en-US",
      "onDevice": false                // true = audio never leaves the Mac
    },
    "local": {
      "pythonPath": "",                // "" = app-managed env (auto-installed); or your own python with openai-whisper
      "modelDir": "",                  // "" = app-managed models dir (auto-downloaded); or your own .pt folder
      "model": "turbo",                // turbo | large-v3 | medium | small | base | tiny
      "device": "cpu",                 // torch device; "cpu" is the safe default
      "language": null                 // ISO-639-1 e.g. "en", or null = auto
    }
  },
  "llm": {
    "enabled": false,                  // false = insert the raw transcript
    "provider": "openaiCompatible",    // "openaiCompatible" | "anthropic"
    "baseURL": "https://api.openai.com/v1",
    "model": "gpt-4o-mini",
    "apiKey": "",
    "apiKeyEnv": "OPENAI_API_KEY",
    "systemPrompt": "You are a dictation assistant. ...",
    "temperature": 0.3,
    "maxTokens": 1024
  },
  "hotkey": { "suppressFnDefault": true },
  "insertion": { "method": "paste", "restoreClipboard": true }
}
```

### Provider presets

Most providers expose an OpenAI-compatible `/chat/completions` endpoint, so set
`provider: "openaiCompatible"` and point `baseURL` at them:

| Provider | `baseURL` | Example `model` |
|---|---|---|
| OpenAI | `https://api.openai.com/v1` | `gpt-4o-mini` |
| Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | `gemini-2.0-flash` |
| DeepSeek | `https://api.deepseek.com` | `deepseek-chat` |
| Kimi (Moonshot) | `https://api.moonshot.cn/v1` | `moonshot-v1-8k` |
| GLM (Zhipu) | `https://open.bigmodel.cn/api/paas/v4` | `glm-4-flash` |
| OpenRouter | `https://openrouter.ai/api/v1` | `openai/gpt-4o-mini` |
| Groq | `https://api.groq.com/openai/v1` | `llama-3.3-70b-versatile` |
| Local (Ollama) | `http://localhost:11434/v1` | `llama3.1` |

**Claude** uses its own API shape — set `provider: "anthropic"`,
`baseURL: "https://api.anthropic.com/v1"`, `model: "claude-3-5-sonnet-latest"`.

For **cloud transcription**, any OpenAI-compatible `/audio/transcriptions`
endpoint works (OpenAI Whisper, or Groq with `baseURL` `…/openai/v1` and model
`whisper-large-v3`).

### Local Whisper transcription

The `local` backend runs [OpenAI Whisper](https://github.com/openai/whisper)
entirely on your Mac — no audio leaves the machine and no STT API key is
needed.

**Zero-setup first run.** Switch `transcription.backend` to `"local"` (leave
`pythonPath` and `modelDir` empty) and reload the config. The app detects that
nothing is provisioned yet and walks you through a one-time setup:

1. A dialog lets you pick a model — `tiny` (76 MB) up to `large-v3` (3.1 GB),
   with `turbo` (1.6 GB) recommended as the best accuracy-per-second.
2. The checkpoint is downloaded from OpenAI's official URLs (SHA-256 verified)
   to `~/Library/Application Support/Dictation/models/`, and a private Python
   environment with `openai-whisper` is created next to it. Progress shows in
   the menu bar.

Everything is downloaded **once** and reused across launches, rebuilds, and
app updates. You can also pre-provision from the terminal:

```bash
.build/release/Dictation --setup-local turbo
```

**Already have Whisper installed?** Point `pythonPath` at any Python with
`openai-whisper` importable and `modelDir` at your folder of `.pt` checkpoints,
and the app uses those instead — nothing is re-downloaded.

At runtime the app spawns a small resident helper (`whisper_server.py`) that
loads the model **once** and serves every dictation from memory, so only the
first dictation after launch pays the model-load cost (a few seconds for
`turbo`). The helper exits automatically when the app quits. ffmpeg is **not**
required — the helper decodes the recorder's WAV directly.

---

## Roadmap

- [ ] Store API keys in the macOS Keychain instead of plaintext config
- [ ] Configurable hotkey (not just `fn`) + push-to-talk mode
- [ ] Streaming partial transcription with live preview
- [ ] Per-app prompt profiles (email vs. chat vs. code comments)
- [ ] Settings UI instead of hand-edited JSON
- [x] Local Whisper transcription backend (openai-whisper via resident Python helper)
- [ ] Sound/HUD feedback on start/stop
- [ ] Notarized, signed release build + auto-update

## Contributing

Backends are intentionally tiny and isolated. To add one, conform to
`Transcriber` or `LLMProvider` and wire it into the factory in
`DictationController`. PRs welcome.

## License

MIT — see [LICENSE](LICENSE).
