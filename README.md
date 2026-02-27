# Frespr

Native macOS menu bar app for voice-to-text dictation powered by the Gemini Live API. Hold a hotkey to record, release to transcribe — text is injected directly into whatever app you're typing in. Supports **70 languages** out of the box.

<img src="docs/icons/icon_128x128@2x.png" width="128" alt="Frespr app icon">

## Features

- **Push-to-talk or toggle mode** — hold your hotkey while speaking, or press once to start and again to stop
- **Live transcript overlay** — floating window shows your words as you speak
- **Post-processing** — optionally clean up filler words, summarize, or apply a custom prompt via a second Gemini call
- **Configurable hotkey** — Right ⌥, Left ⌥, Fn/Globe, Right ⌘, or Ctrl+Option
- **Silence detection** — auto-stops recording after configurable silence timeout (default 15s)
- **Transcription history** — last 20 transcriptions accessible from the menu bar
- **Copy to clipboard** — optionally copies every transcription to the pasteboard
- **Smart text injection** — uses Accessibility API (AXUIElement) with pasteboard+Cmd+V fallback
- **Free & open source** — AGPLv3 licensed
- **Audio buffering** — captures audio immediately on keypress while the WebSocket is still connecting, so the first word is never lost
- **70 languages** — transcribes in any language Gemini Live supports, including English, Spanish, French, German, Japanese, Chinese, Arabic, Hindi, and 62 more

## Requirements

- macOS 14 (Sonoma) or later
- Apple Silicon or Intel Mac
- [Gemini API key](https://aistudio.google.com/apikey) (free tier available)
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
git clone https://github.com/yourusername/frespr
cd frespr
bash build.sh
open Frespr.pkg
```

## Setup

1. Launch Frespr — a microphone icon appears in your menu bar
2. Click the icon → **Settings** (or press ⌘,)
3. Paste your Gemini API key
4. Grant **Microphone** and **Accessibility** permissions when prompted
5. Hold Right ⌥ (or your configured hotkey) and speak

## Usage

| Action | Result |
|--------|--------|
| Hold hotkey | Start recording |
| Release hotkey | Transcribe and inject |
| Press hotkey twice (toggle mode) | Same as hold/release |
| Press Escape | Cancel recording |
| Click menu bar icon | Open menu |
| ⌘, | Open Settings |

The overlay window shows a live transcript while you speak. When you release the hotkey, the final text is injected into the focused app at the cursor position.

## Post-Processing Modes

Configure in Settings under **Post-processing**:

| Mode | Description |
|------|-------------|
| None | Inject raw transcript |
| Clean up | Remove filler words, fix grammar and punctuation |
| Summarize | Clean up + condense to concise prose |
| Custom | Your own system prompt |

Post-processing adds ~1–2s latency (a second Gemini REST call).

## Build from Source

No Xcode required — only Command Line Tools.

```bash
bash build.sh        # compiles, signs, packages → Frespr.pkg
open Frespr.pkg      # installs to /Applications
```

To type-check without building:

```bash
swiftc -typecheck \
  -target arm64-apple-macosx14.0 \
  -sdk $(xcrun --show-sdk-path --sdk macosx) \
  Frespr/**/*.swift Frespr/App/*.swift
```

## Permissions

Frespr requires two permissions:

- **Microphone** — to record audio
- **Accessibility** — to inject text into other apps via the AXUIElement API

Both are requested on first use and can be managed in System Settings → Privacy & Security.

## How It Works

1. Hotkey pressed → audio capture starts immediately (AVAudioEngine → 16kHz Int16 PCM)
2. WebSocket connects to Gemini Live API (`gemini-live-2.5-flash-native-audio`)
3. PCM chunks are base64-encoded and streamed to Gemini
4. Partial transcripts appear in the overlay in real time
5. Hotkey released → `audioStreamEnd` sent, 1.2s collection window, final transcript assembled
6. Optional post-processing via Gemini Flash REST API
7. Text injected into focused app via AXUIElement; falls back to clipboard+Cmd+V

## License

GNU Affero General Public License v3.0 — see [LICENSE](LICENSE) for details.
