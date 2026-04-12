# Frespr

Native macOS menu bar app for voice-to-text dictation using Deepgram Nova-3. Press a hotkey to record, press again to transcribe and inject text into the focused app.

## Build & Install

```bash
bash build.sh          # compiles, signs, launches (dev mode)
bash build.sh pkg      # compiles, signs, packages → Frespr.pkg
open Frespr.pkg        # installs to /Applications
```

Very Important, always use `bash build.sh` (dev mode with claude).
No Xcode needed — uses `swiftc` from Command Line Tools.

## Versioning & Releases

Version is controlled by the `VERSION` file at the repo root (e.g. `2.0.0`).
`build.sh` reads it automatically; Info.plist uses `FRESPR_VERSION` as a placeholder that gets patched at bundle time.

**To ship a new release — follow ALL steps in order:**
1. Update `README.md` — verify backend names, setup steps, feature list, and API key requirements are current
2. Update `docs/index.html` — verify all feature cards, privacy copy, comparison table, and setup instructions reflect the current version
3. Update `CLAUDE.md` — verify project structure, architecture decisions, and gotchas are current
4. Edit `VERSION` to the new version (e.g. `2.1.0`)
5. Commit everything: `git commit -am "bump version to 2.1.0"`
6. Tag: `git tag v2.1.0 && git push origin main --tags`
7. GitHub Actions (`.github/workflows/release.yml`) builds `Frespr.pkg` on a macOS runner and publishes it as a GitHub Release automatically.
8. The landing page download links point to `releases/latest/download/Frespr.pkg` so they update immediately.

**Never bump the version or tag before steps 1–3 are done.**

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
│   └── Debug.swift                   # dbg() helper (writes to /tmp/frespr_debug.log)
├── Audio/
│   └── AudioCaptureEngine.swift      # AVAudioEngine → 16kHz Int16 PCM chunks
├── Coordinator/
│   ├── TranscriptionBackend.swift    # Protocol: connect/disconnect/send/callbacks
│   └── TranscriptionCoordinator.swift # State machine: idle→connecting→recording→processing
├── Deepgram/
│   └── DeepgramService.swift         # Deepgram Nova-3 WebSocket streaming (primary backend)
├── Gemini/
│   ├── GeminiProtocol.swift          # Codable WebSocket message types (retained, unused in v2.0)
│   ├── GeminiLiveService.swift       # NOT instantiated in v2.0; retained for future re-enablement
│   └── GeminiPostProcessor.swift     # REST call to Gemini Flash for post-processing (optional)
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
│   ├── SettingsView.swift            # Dead code — never shown; real settings is SettingsWindowController
│   └── SettingsWindowController.swift # Pure AppKit settings: card-style sections, 560px wide
├── Frespr.entitlements               # Sandbox OFF, network.client, audio-input
└── Info.plist                        # LSUIElement=YES (no Dock icon)
```

## Key Architecture Decisions

- **Swift 6, `@MainActor`** — `AppDelegate` and `TranscriptionCoordinator` are both `@MainActor`; `main.swift` uses `MainActor.assumeIsolated { AppDelegate() }`
- **No Xcode** — built entirely with `swiftc` + `pkgbuild`; `$(EXECUTABLE_NAME)` in Info.plist must be the literal string `Frespr`
- **Deepgram v2.0** — `DeepgramService` is the sole transcription backend. `GeminiLiveService` is retained but never instantiated. End-of-stream via `{"type":"CloseStream"}` JSON message (not WebSocket close frame).
- **TranscriptionBackend protocol** — `@MainActor` protocol; `DeepgramService` conforms. Allows future backends without changing the coordinator.
- **LSUIElement app focus** — settings window requires temporarily switching `NSApp.setActivationPolicy(.regular)` so text fields can receive keyboard input; switches back to `.accessory` on close
- **Settings UI** — pure AppKit `NSStackView` + `NSBox` cards; `SettingsView.swift` is dead code. Always edit `SettingsWindowController.swift` for settings UI changes.
- **Settings text fields** — `NSTextFieldDelegate` + `controlTextDidChange` for live saving; do NOT rely on `.action` (only fires on Return) or window close for multiline fields.
- **Ad-hoc signing** — no `--options runtime` flag; Hardened Runtime requires a real Apple cert and causes Gatekeeper rejection on local installs
- **postinstall script** — runs `chown` + `xattr -dr com.apple.quarantine` since pkg installs as root
- **Audio buffering** — `connectBuffer` in `TranscriptionCoordinator` captures audio chunks during WebSocket handshake and flushes on `setupComplete`; avoids dropping the first word(s)
- **Transcript accumulation** — Deepgram delivers multiple `is_final=true` segments during recording; `accumulatedTranscript` joins them; all delivered before `onDisconnected`
- **Hotkey toggle mode** — `onKeyDown` → `handleHotkeyPress()`; `onKeyUp` ignored. `pendingStop` flag defers stop if key released during `.connecting`. CGEventTap auto-re-enabled via raw type values `0xFFFFFFFE`/`0xFFFFFFFF` to survive macOS disabling it.
- **isDelivering guard** — prevents double-delivery; `onDisconnected` skips cleanup if `isDelivering=true` (post-processing in flight)
- **Silence detection** — auto-calibrates threshold during `.connecting` phase (5 ambient chunks → baseline × 2.5, floor 0.003); active during `.recording` only
- **Post-processing** — `postProcess()` uses `userMessagePrefix` param: "Reformat" for cleanup/summarize, "Process" for custom so the system prompt is the sole directive
- **Post-processing callback race** — `onTranscriptUpdate` called synchronously from `@MainActor`; do NOT re-wrap in `Task { @MainActor }` or `stopRecording()` races against `accumulatedTranscript`

## Deepgram Streaming API

```
wss://api.deepgram.com/v1/listen?model=nova-3&encoding=linear16&sample_rate=16000&interim_results=true&punctuate=true&language=multi
```

Flow: connect → stream PCM chunks → send `{"type":"CloseStream"}` on hotkey stop → Deepgram flushes, delivers final transcript, closes connection → `onDisconnected` fires → `deliverTranscript()` → post-process (optional) → inject → disconnect.

`language=multi`: detects mixed-language speech. Supports European + some Asian languages. Arabic requires `language=ar` explicitly (not included in `multi`).

## Debug Logs

All `dbg()` calls write to `/tmp/frespr_debug.log`. Watch live with:
```bash
tail -f /tmp/frespr_debug.log
```
Log is cleared on every `bash build.sh` run.

## Running Tests

```bash
swiftc -target arm64-apple-macosx14.0 -sdk $(xcrun --show-sdk-path --sdk macosx) \
  Frespr/App/Debug.swift \
  Frespr/Audio/AudioCaptureEngine.swift \
  Frespr/Coordinator/TranscriptionBackend.swift \
  Frespr/Coordinator/TranscriptionCoordinator.swift \
  Frespr/Deepgram/DeepgramService.swift \
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

## End of Every Task

Always finish each task by running `bash build.sh` so the user can immediately test the result.

## Landing Page (`docs/index.html`)

The landing page highlights the app's key features. Update the `.features` grid in `docs/index.html` when a major new user-facing feature ships. Current highlighted features:

1. **Toggle to record** — press hotkey to start, press again to stop
2. **Deepgram Nova-3** — ~300ms latency, real-time streaming transcription
3. **Post-processing** — cleanup / summarize / custom prompt modes via Gemini
4. **Configurable hotkey** — Right ⌥, Left ⌥, Fn/Globe, Right ⌘, Ctrl+Option
5. **History & re-inject** — last 20 transcriptions in menu bar, click to re-inject
6. **70+ languages** — multi-language detection, mixed-language in same session
7. **Your key, your data** — audio direct to Deepgram; text to Google only if post-processing enabled
8. **Open source** — AGPL-3.0, build with Swift CLI tools, no Xcode

## Known Gotchas

- `#Preview` macro requires Xcode plugins — remove from files before CLI type-checking
- CGEventTap requires Accessibility permission; fails silently if not granted
- CGEventTap can be silently disabled by macOS — re-enable in callback using raw types `0xFFFFFFFE`/`0xFFFFFFFF`
- Right Option keycode is 61; detect via `.flagsChanged` + `.maskAlternate` without other modifier flags
- `SettingsWindowController` must call `NSApp.setActivationPolicy(.regular)` before `makeKeyAndOrderFront` so text fields accept keyboard input; call `.accessory` on `windowWillClose`
- `TranscriptionLog` is in-memory only during a session; persisted to `UserDefaults` as a JSON array
- `NSStackView` alignment = `.leading` means subviews don't fill width — use `pinWidth()` pattern (constrain each arranged subview to `scrollView.contentView.widthAnchor`) for full-width cards
- `controlTextDidEndEditing` does not fire reliably when clicking non-text controls — use a local `NSEvent.addLocalMonitorForEvents` mouse-down monitor to force commit
- Deepgram `sendStreamEnd()` must send `{"type":"CloseStream"}` JSON — a WebSocket ping or close frame does NOT trigger Deepgram to flush and return the final transcript
- `language=multi` does not include Arabic — use `language=ar` for Arabic-only sessions
- tccutil reset in build.sh requires sudo — run once: `echo "sam ALL=(ALL) NOPASSWD: /usr/bin/tccutil reset Accessibility com.frespr.app" | sudo tee /etc/sudoers.d/frespr-tccutil`
