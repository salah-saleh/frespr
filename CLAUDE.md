# Frespr

Native macOS menu bar app for voice-to-text transcription using Gemini Live API. Hold Right Option (⌥) to record, release to transcribe and inject text into the focused app.

## Build & Install

```bash
bash build.sh          # compiles, signs, packages → Frespr.pkg
open Frespr.pkg        # installs to /Applications
```

No Xcode needed — uses `swiftc` from Command Line Tools.

## Project Structure

```
Frespr/
├── App/
│   ├── main.swift                    # Entry point
│   └── AppDelegate.swift             # Wires all subsystems; owns settings window lifecycle
├── Audio/
│   └── AudioCaptureEngine.swift      # AVAudioEngine → 16kHz Int16 PCM chunks
├── Coordinator/
│   └── GeminiSessionCoordinator.swift # State machine: idle→connecting→recording→processing
├── Gemini/
│   ├── GeminiProtocol.swift          # Codable WebSocket message types
│   └── GeminiLiveService.swift       # URLSessionWebSocketTask connection + send/receive
├── HotKey/
│   └── GlobalHotKeyMonitor.swift     # CGEventTap on Right Option (keycode 61)
├── MenuBar/
│   └── MenuBarController.swift       # NSStatusItem; mic/mic.fill/waveform icons
├── Permissions/
│   └── PermissionManager.swift       # Mic + Accessibility permission gating
├── Storage/
│   └── AppSettings.swift             # @Observable UserDefaults wrapper
├── TextInjection/
│   └── TextInjector.swift            # AXUIElement primary; NSPasteboard+Cmd+V fallback
├── UI/
│   ├── OverlayView.swift             # SwiftUI: mic indicator + live transcript
│   ├── OverlayWindow.swift           # NSPanel floating above all apps
│   └── SettingsView.swift            # API key, hotkey mode, permissions
├── Frespr.entitlements               # Sandbox OFF, network.client, audio-input
└── Info.plist                        # LSUIElement=YES (no Dock icon)
```

## Key Architecture Decisions

- **Swift 6, `@MainActor`** — `AppDelegate` and `GeminiSessionCoordinator` are both `@MainActor`; `main.swift` uses `MainActor.assumeIsolated { AppDelegate() }`
- **No Xcode** — built entirely with `swiftc` + `pkgbuild`; `$(EXECUTABLE_NAME)` in Info.plist must be the literal string `Frespr`
- **LSUIElement app focus** — settings window requires temporarily switching `NSApp.setActivationPolicy(.regular)` so text fields can receive keyboard input; switches back to `.accessory` on close
- **Settings text fields** — use local `@State` vars synced via `onChange`, NOT `$settings.geminiAPIKey` directly (breaks paste with `@Observable`)
- **Ad-hoc signing** — no `--options runtime` flag; Hardened Runtime requires a real Apple cert and causes Gatekeeper rejection on local installs
- **postinstall script** — runs `chown` + `xattr -dr com.apple.quarantine` since pkg installs as root

## Gemini Live API

```
wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key={KEY}
```

Flow: connect → send setup (`responseModalities: ["TEXT"]`, `inputAudioTranscription: {}`) → wait for `setupComplete` → stream PCM chunks as base64 → send `audioStreamEnd: true` on hotkey release → receive final transcript → inject → disconnect.

Model: `models/gemini-live-2.5-flash-native-audio`

## Type-checking Without Xcode

```bash
swiftc -typecheck \
  -target arm64-apple-macosx14.0 \
  -sdk $(xcrun --show-sdk-path --sdk macosx) \
  Frespr/**/*.swift Frespr/App/*.swift
```

## Known Gotchas

- `#Preview` macro requires Xcode plugins — remove from files before CLI type-checking
- `GeminiLiveError.localizedDescription` is `String` not `String?` — no `??` needed
- CGEventTap requires Accessibility permission; fails silently if not granted
- Right Option keycode is 61; detect via `.flagsChanged` + `.maskAlternate` without other modifier flags
