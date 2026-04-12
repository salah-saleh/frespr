# Frespr

Native macOS menu bar app for voice-to-text dictation powered by Deepgram Nova-3. Press your hotkey to record, press again to stop — text is injected directly into whatever app you're typing in.

<img src="docs/icons/icon_128x128@2x.png" width="128" alt="Frespr app icon">

## Features

- **Push-to-talk or toggle mode** — hold your hotkey while speaking, or press once to start and again to stop
- **Live transcript overlay** — floating window shows your words as you speak in real time
- **Deepgram Nova-3** — state-of-the-art streaming transcription, ~300ms latency, 70+ languages
- **Multi-language detection** — speak in multiple languages in the same session
- **Post-processing** — optionally clean up filler words, summarize, or apply a custom prompt via Gemini
- **Translation** — translate transcriptions before injecting, with quick-switch language favorites
- **Configurable hotkey** — Right ⌥, Left ⌥, Fn/Globe, Right ⌘, or Ctrl+Option
- **Silence detection** — auto-stops recording after configurable silence timeout
- **Transcription history** — last 20 transcriptions accessible from the menu bar
- **Copy to clipboard** — optionally copies every transcription to the pasteboard
- **Smart text injection** — uses Accessibility API (AXUIElement) with pasteboard+Cmd+V fallback
- **Free & open source** — AGPLv3 licensed

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel Mac
- [Deepgram API key](https://console.deepgram.com/signup) (free tier available — required)
- [Gemini API key](https://aistudio.google.com/apikey) (free tier — optional, for post-processing & translation)
- Xcode Command Line Tools (`xcode-select --install`)

## Install

Download the latest `Frespr.pkg` from [Releases](../../releases) and double-click to install.

> [!WARNING]
> **macOS will block the installer** — Frespr is not signed with a paid Apple Developer certificate, so Gatekeeper will show a warning when you open the package.
>
> **To bypass it, choose one of:**
> - Right-click `Frespr.pkg` → **Open** → click **Open** in the dialog
> - **System Settings → Privacy & Security** → scroll down → **Open Anyway**

Or build from source:

```bash
git clone https://github.com/salah-saleh/frespr
cd frespr
bash build.sh
```

## Setup

1. Launch Frespr — a microphone icon appears in your menu bar
2. Click the icon → **Settings**
3. Paste your **Deepgram API key** (required)
4. Optionally paste your **Gemini API key** for post-processing and translation
5. Grant **Microphone** and **Accessibility** permissions when prompted
6. Press your hotkey (default: Right ⌥) and speak

## Usage

| Action | Result |
|--------|--------|
| Press hotkey | Start recording |
| Press hotkey again | Stop, transcribe, and inject |
| Press Escape | Cancel recording |
| Click menu bar icon | Open menu / history |

The overlay window shows a live transcript while you speak. When you stop, the final text is injected into the focused app at the cursor position.

## Post-Processing

Configure in Settings under **Post-processing** (requires a Gemini API key):

| Mode | Description |
|------|-------------|
| None | Inject raw transcript |
| Clean up | Remove filler words, fix grammar and punctuation |
| Summarize | Clean up + condense to concise prose |
| Custom | Your own system prompt |

Post-processing adds ~1–2s latency (a Gemini REST call).

## How It Works

1. Hotkey pressed → audio capture starts immediately (AVAudioEngine → 16kHz Int16 PCM)
2. WebSocket connects to Deepgram Nova-3 streaming API
3. PCM chunks stream to Deepgram in real time
4. Partial transcripts appear in the overlay as you speak
5. Hotkey pressed again → `CloseStream` sent, Deepgram flushes and returns final transcript
6. Optional post-processing via Gemini Flash REST API
7. Text injected into focused app via AXUIElement; falls back to clipboard+Cmd+V

## Build from Source

No Xcode required — only Command Line Tools.

```bash
bash build.sh   # compiles, signs, launches
```

## Permissions

Frespr requires two permissions:

- **Microphone** — to record audio
- **Accessibility** — to inject text into other apps and detect the hotkey

Both are requested on first launch and can be managed in System Settings → Privacy & Security.

## License

GNU Affero General Public License v3.0 — see [LICENSE](LICENSE) for details.
