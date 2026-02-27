# Frespr

Native macOS menu bar app for voice-to-text dictation using Gemini Live API. Hold a hotkey to record, release to transcribe and inject text into the focused app.

## Build & Install

```bash
bash build.sh          # compiles, signs, launches (dev mode)
bash build.sh pkg      # compiles, signs, packages → Frespr.pkg
open Frespr.pkg        # installs to /Applications
```

No Xcode needed — uses `swiftc` from Command Line Tools.

## Versioning & Releases

Version is controlled by the `VERSION` file at the repo root (e.g. `1.0.0`).
`build.sh` reads it automatically; Info.plist uses `FRESPR_VERSION` as a placeholder that gets patched at bundle time.

**To ship a new release:**
1. Edit `VERSION` to the new version (e.g. `1.1.0`)
2. Commit: `git commit -am "bump version to 1.1.0"`
3. Tag: `git tag v1.1.0 && git push origin main --tags`
4. GitHub Actions (`.github/workflows/release.yml`) builds `Frespr.pkg` on a macOS runner and publishes it as a GitHub Release automatically.
5. The landing page download links point to `releases/latest/download/Frespr.pkg` so they update immediately.

## GitHub Pages

Landing page at `docs/index.html` is deployed via `.github/workflows/pages.yml` on every push to `main` that touches `docs/`.
Custom domain: `frespr.com` — configure in repo Settings → Pages → Custom domain.
The `docs/` folder is the Pages root; add a `CNAME` file there if needed after configuring the domain in Namecheap.

## Project Structure

```
Frespr/
├── App/
│   ├── main.swift                    # Entry point
│   ├── AppDelegate.swift             # Wires all subsystems; owns settings window lifecycle
│   └── Debug.swift                   # dbg() helper (no-op in release builds)
├── Audio/
│   └── AudioCaptureEngine.swift      # AVAudioEngine → 16kHz Int16 PCM chunks
├── Coordinator/
│   └── GeminiSessionCoordinator.swift # State machine: idle→connecting→recording→processing
├── Gemini/
│   ├── GeminiProtocol.swift          # Codable WebSocket message types
│   ├── GeminiLiveService.swift       # URLSessionWebSocketTask connection + send/receive
│   └── GeminiPostProcessor.swift     # REST call to Flash for post-processing (cleanup/summarize/custom)
├── HotKey/
│   ├── GlobalHotKeyMonitor.swift     # CGEventTap for configurable hotkeys
│   └── HotKeyOption.swift            # Enum: rightOption/leftOption/fn/rightCommand/ctrlOption
├── MenuBar/
│   └── MenuBarController.swift       # NSStatusItem; mic/mic.fill/waveform icons; history menu
├── Permissions/
│   └── PermissionManager.swift       # Mic + Accessibility permission gating
├── Storage/
│   ├── AppSettings.swift             # @Observable UserDefaults wrapper
│   └── TranscriptionLog.swift        # In-memory + persisted history of last 20 transcriptions
├── TextInjection/
│   └── TextInjector.swift            # AXUIElement primary; NSPasteboard+Cmd+V fallback
├── UI/
│   ├── OverlayView.swift             # SwiftUI: mic indicator + live transcript
│   ├── OverlayWindow.swift           # NSPanel floating above all apps
│   ├── SettingsView.swift            # API key, hotkey, post-processing, permissions
│   └── SettingsWindowController.swift # Manages activation policy switch for text field focus
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
- **Audio buffering** — `connectBuffer` in `GeminiSessionCoordinator` captures audio chunks during the WebSocket handshake and flushes them on `setupComplete`; avoids dropping the first word(s)
- **Transcript accumulation** — server VAD delivers multiple `turnComplete` segments during a long recording; `accumulatedTranscript` joins them; `currentTurnTranscript` in `GeminiLiveService` snapshots the final partial turn at key release
- **Hotkey** — `HotKeyOption` enum covers 5 choices; `GlobalHotKeyMonitor` uses CGEventTap + `.flagsChanged`; hotkey changes post a `hotKeyChanged` notification so the monitor can swap the tap without restart
- **Post-processing callback race** — `onTranscriptUpdate` is called synchronously from a `@MainActor` context; do NOT re-wrap in `Task { @MainActor }` or `stopRecording()` races against `accumulatedTranscript` updates

## Gemini Live API

```
wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent?key={KEY}
```

Flow: connect → send setup (`responseModalities: ["TEXT"]`, `inputAudioTranscription: {}`) → wait for `setupComplete` → stream PCM chunks as base64 → send `audioStreamEnd: true` on hotkey release → 1.2s collection window → snap `currentTurnTranscript` → post-process (optional) → inject → disconnect.

Model: `models/gemini-live-2.5-flash-native-audio`

## Type-checking Without Xcode

```bash
swiftc -typecheck \
  -target arm64-apple-macosx14.0 \
  -sdk $(xcrun --show-sdk-path --sdk macosx) \
  Frespr/**/*.swift Frespr/App/*.swift
```

## Running Tests

```bash
swiftc -target arm64-apple-macosx14.0 -sdk $(xcrun --show-sdk-path --sdk macosx) \
  Frespr/App/Debug.swift \
  Frespr/Audio/AudioCaptureEngine.swift \
  Frespr/Coordinator/GeminiSessionCoordinator.swift \
  Frespr/Gemini/GeminiLiveService.swift \
  Frespr/Gemini/GeminiPostProcessor.swift \
  Frespr/Gemini/GeminiProtocol.swift \
  Frespr/HotKey/GlobalHotKeyMonitor.swift \
  Frespr/HotKey/HotKeyOption.swift \
  Frespr/MenuBar/MenuBarController.swift \
  Frespr/Permissions/PermissionManager.swift \
  Frespr/Storage/AppSettings.swift \
  Frespr/Storage/TranscriptionLog.swift \
  Frespr/TextInjection/TextInjector.swift \
  Frespr/UI/OverlayView.swift \
  Frespr/UI/OverlayWindow.swift \
  Frespr/UI/SettingsView.swift \
  Frespr/UI/SettingsWindowController.swift \
  Tests/SettingsTests.swift \
  -o /tmp/SettingsTests && /tmp/SettingsTests
```

Tests cover: `AppSettings` CRUD round-trips, default values, enum logic (`PostProcessingMode`, `HotKeyOption`), `SettingsWindowController` init smoke test, and action round-trips via `perform(NSSelectorFromString(...))`.

## End of Every Task

Always finish each task by running `bash build.sh` and then `open Frespr.pkg` to install, so the user can immediately test the result.

## Landing Page (`docs/index.html`)

The landing page highlights the app's key features. Update the `.features` grid in `docs/index.html` when a major new user-facing feature ships. Current highlighted features (8 cards):

1. **Hold to record** — push-to-talk hotkey, text at cursor
2. **Powered by Gemini Live** — real-time streaming transcription + live overlay
3. **Post-processing** — cleanup / summarize / custom prompt modes
4. **Configurable hotkey** — Right ⌥, Left ⌥, Fn/Globe, Right ⌘, Ctrl+Option
5. **History & re-inject** — last 20 transcriptions in menu bar, click to re-inject
6. **70 languages** — speak in any of the 70 languages Gemini Live supports (English, Spanish, French, Japanese, Arabic, Hindi, and more)
7. **Your key, your data** — direct audio to Google, no third-party servers
8. **Open source** — AGPL-3.0, build with Swift CLI tools, no Xcode

## Known Gotchas

- `#Preview` macro requires Xcode plugins — remove from files before CLI type-checking
- `GeminiLiveError.localizedDescription` is `String` not `String?` — no `??` needed
- CGEventTap requires Accessibility permission; fails silently if not granted
- Right Option keycode is 61; detect via `.flagsChanged` + `.maskAlternate` without other modifier flags
- Gemini Live native audio model often returns ALL-CAPS transcriptions — `normalizeTranscription()` in `GeminiSessionCoordinator` converts to sentence case
- `SettingsWindowController` must call `NSApp.setActivationPolicy(.regular)` before `makeKeyAndOrderFront` so text fields accept keyboard input; call `.accessory` on `windowWillClose`
- `TranscriptionLog` is in-memory only during a session; persisted to `UserDefaults` as a JSON array
- **`NSHostingView` sizing** — `sizingOptions = []` makes `fittingSize` always return `(0,0)`; must use `sizingOptions = [.intrinsicContentSize]` for `fittingSize` to reflect SwiftUI layout. Set the hosting view as direct `contentView` (not wrapped in a container) for reliable sizing. Use a repeating Timer polling `fittingSize.height` to drive window resizing — KVO on `intrinsicContentSize` is unreliable for SwiftUI state updates.
- **`NSScrollView` document view width** — do NOT use `scrollView.contentView.leadingAnchor/trailingAnchor` to size the document view; the clip view shrinks when the scrollbar is visible, causing asymmetric margins. Instead use a fixed `widthAnchor` constant (= window width − margins) + `centerXAnchor` on the `scrollView` itself.
