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
                          (protocol)  └─ apple  (SFSpeechRecognizer, on-device)
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
| `Transcription/*` | `Transcriber` protocol + cloud (Whisper) & Apple backends |
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
    "backend": "apple",                // "apple" (no key) | "cloud"
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

---

## Roadmap

- [ ] Store API keys in the macOS Keychain instead of plaintext config
- [ ] Configurable hotkey (not just `fn`) + push-to-talk mode
- [ ] Streaming partial transcription with live preview
- [ ] Per-app prompt profiles (email vs. chat vs. code comments)
- [ ] Settings UI instead of hand-edited JSON
- [ ] Local Whisper (whisper.cpp) transcription backend
- [ ] Sound/HUD feedback on start/stop
- [ ] Notarized, signed release build + auto-update

## Contributing

Backends are intentionally tiny and isolated. To add one, conform to
`Transcriber` or `LLMProvider` and wire it into the factory in
`DictationController`. PRs welcome.

## License

MIT — see [LICENSE](LICENSE).
