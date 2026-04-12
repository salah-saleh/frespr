# Implementation Plan: Deepgram + Gemini Hybrid Backend

**Branch**: `main` | **Date**: 2026-04-10 | **Spec**: specs/main/spec.md

## Summary

Introduce a `TranscriptionBackend` protocol and `DeepgramService`, then refactor
`GeminiSessionCoordinator` into `TranscriptionCoordinator` that selects the backend
based on which API keys are present. `GeminiLiveService` conforms to the same protocol.
Settings gains a Deepgram API key section. No behavior change when only Gemini key is set.

## Technical Context

**Language/Version**: Swift 6 (strict concurrency)
**Primary Dependencies**: Foundation (URLSessionWebSocketTask), AppKit, SwiftUI
**Storage**: Keychain via `KeychainHelper` (no UserDefaults for any API key)
**Testing**: `swiftc` CLI + `Tests/SettingsTests.swift`
**Target Platform**: macOS 14+ arm64
**Project Type**: macOS menu bar app (no Xcode — builds via `build.sh` / `swiftc`)
**Performance Goals**: Deepgram path must show transcript updates within 300ms
**Constraints**: Swift 6 strict concurrency; `@MainActor` throughout; no Xcode

## Constitution Check

No violations. Protocol abstraction is explicit, tested, minimal. KeychainHelper
parameterization is a targeted refactor with zero API surface change for existing callers.

## Project Structure

### Spec artifacts
```
specs/main/
├── spec.md          (feature spec — already written)
├── plan.md          (this file)
├── tasks.md         (to be generated)
└── research.md      (inline — see below)
```

### New source files
```
Frespr/
├── Coordinator/
│   ├── TranscriptionBackend.swift   (new — protocol)
│   └── TranscriptionCoordinator.swift  (renamed from GeminiSessionCoordinator.swift)
└── Deepgram/
    └── DeepgramService.swift        (new)
```

### Modified source files
```
Frespr/
├── Storage/AppSettings.swift        (add deepgramAPIKey; parameterize KeychainHelper)
├── Gemini/GeminiLiveService.swift   (conform to TranscriptionBackend)
├── UI/SettingsWindowController.swift (add Deepgram section + active backend label)
├── App/AppDelegate.swift            (wire TranscriptionCoordinator)
build.sh                             (update file list)
Tests/SettingsTests.swift            (add deepgramAPIKey + backend selection tests)
```

## Key Decisions

### D1: Protocol is `@MainActor`
Both services are `@MainActor`. Annotating the protocol `@MainActor` avoids scattered
`DispatchQueue.main.async` calls and matches Swift 6 isolation semantics. All protocol
callbacks fire on the main actor. `URLSessionWebSocketTask` and `NWConnection` receive
handlers must use `Task { @MainActor [weak self] in ... }` to cross isolation boundaries.

### D2: `KeychainHelper` parameterized via `account` argument
Change all three methods to accept `account: String`. All existing `geminiAPIKey`
callers pass `account: "geminiAPIKey"` explicitly — no silent behavior change.
New `deepgramAPIKey` property on `AppSettings` passes `account: "deepgramAPIKey"`.
The helper remains a `private enum` inside `AppSettings.swift`.

### D3: `connectBuffer` typed as `[Data]`
`startAudioCapture()` stores raw `Data` directly (no base64 conversion). Both backends
receive `Data` via `sendAudioChunk(data:)`. This eliminates the coordinator's knowledge
of any encoding detail — encoding is each service's private concern.

### D4: Gemini-specific wiring via conditional downcast
*Alternative considered: two parallel coordinator classes (one for Gemini, one for Deepgram).
Rejected because the `TranscriptionBackend` protocol pays off when WhisperKit/Voxtral lands
(see TODOS.md) — adding a third backend would require a third coordinator class instead.*

Three behaviors that exist only for `GeminiLiveService` are wired via:
```swift
if let gemini = backend as? GeminiLiveService {
    gemini.onModelTurnComplete = { ... }
}
```
And two timer guards:
```swift
if backend is GeminiLiveService {
    // start heartbeat timer
}
```
This avoids polluting the protocol with Gemini-specific callbacks.

### D5: `GeminiLiveService.onError` widened from `GeminiLiveError` → `Error`
Protocol requires `((Error) -> Void)?`. `TranscriptionCoordinator.setupBackendCallbacks()`
receives an `Error` and calls `error.localizedDescription` to produce the UI string.
No other callers of `geminiService.onError` exist outside the coordinator.

### D6: `TranscriptionError` enum for coordinator-level errors
```swift
enum TranscriptionError: LocalizedError {
    case connectionFailed(String)
    var errorDescription: String? {
        switch self { case .connectionFailed(let msg): return msg }
    }
}
```
`connectWithRetry` throws `TranscriptionError.connectionFailed("Max retries exceeded")`
instead of `GeminiLiveError.connectionFailed(...)`. Auth errors (`DeepgramError.unauthorized`)
are thrown immediately from `connect(apiKey:)` and propagate to `startRecording()`'s catch
block — they bypass the retry loop.

### D7: `DeepgramService` 401 detection
Implement `URLSessionTaskDelegate` on `DeepgramService`. In
`urlSession(_:task:didCompleteWithError:)`: if `(task.response as? HTTPURLResponse)?.statusCode == 401`,
call the stored `continuation.resume(throwing: DeepgramError.unauthorized)`. If `task.response`
is nil, call `continuation.resume(throwing: DeepgramError.connectionFailed("Network error"))`.
`connect(apiKey:)` is `async throws` — use a `CheckedContinuation` to bridge the delegate callback.

### D8: Deepgram `is_final` accumulation (replacement, not append)
Interim results (`is_final: false`) are full-replacement transcripts for the current utterance.
The coordinator's `onTranscriptUpdate` handler treats them identically to Gemini's interim
updates — shows `accumulatedTranscript + " " + interimText` in overlay. Only `is_final: true`
events append to `accumulatedTranscript`.

## Risks / Unknowns

- **URLSessionWebSocketTask 401 detection**: `task.response` may be `nil` when a WebSocket
  upgrade fails with 401 (Apple's URLSession does not guarantee it is populated). Implement
  a secondary detection path: after the `didOpenWithProtocol` fires and the continuation
  resumes, set a flag `didOpen = true`. If `didCompleteWithError` fires with `connectContinuation`
  still set AND `didOpen` is false AND `task.response` is nil, treat it as a potential auth
  failure and surface `DeepgramError.unauthorized`. Also check the `error` domain — a 401
  often surfaces as `NSURLErrorDomain` with code `-1005` or similar. Add to the Risks section
  that this detection may be imperfect; the error message for both cases should suggest
  "check your API key in Settings" so the user is guided regardless of which error fires.
- **Deepgram response schema may vary**: The JSON schema documented in FR-008 is the standard
  streaming response. Some Deepgram features add extra fields; `Codable` struct with
  `CodingKeys` will safely ignore unknown fields.
- **Swift 6 strict concurrency + URLSession delegate**: The delegate must be `nonisolated` and
  dispatch back to `@MainActor` via `Task { @MainActor [weak self] in ... }`. Already handled
  in the sketches above.
- **Post-processing requires Gemini key**: `GeminiPostProcessor` and translation always use
  `settings.geminiAPIKey`. If only a Deepgram key is set (no Gemini key), post-processing
  is skipped and the overlay shows `"Post-processing requires a Gemini API key."` before
  injecting raw transcript (spec edge case, lines 106-113). Translation failure is silent
  (existing `guard !apiKey.isEmpty` behavior — intentionally asymmetric per spec). The
  post-processing mode buttons remain visible in Settings — they take effect once a Gemini
  key is added.

---

## Architecture Diagrams

### System Architecture (after this change)

```
┌─────────────────────────────────────────────────────────────┐
│                      AppDelegate                            │
│  (owns TranscriptionCoordinator, MenuBarController, etc.)   │
└──────────────────────┬──────────────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────────────┐
│               TranscriptionCoordinator                      │
│  @MainActor                                                 │
│                                                             │
│  backend: any TranscriptionBackend  ◄── set at session start│
│    ├── GeminiLiveService   (when deepgramAPIKey is empty)   │
│    └── DeepgramService     (when deepgramAPIKey is set)     │
│                                                             │
│  audioEngine: AudioCaptureEngine  (16kHz PCM → Data)       │
│  connectBuffer: [Data]                                      │
│  accumulatedTranscript: String                              │
│  state: SessionState                                        │
│  heartbeatTimer (Gemini path only)                          │
└──────────┬──────────────────────┬───────────────────────────┘
           │ onTranscriptUpdate   │ post-processing
           ▼                      ▼
      OverlayView          GeminiPostProcessor
                              (REST, unchanged)
```

### Data Flow: Audio → Transcript

```
AudioCaptureEngine
  │  onAudioChunk: Data  (16kHz PCM, raw)
  ▼
TranscriptionCoordinator.startAudioCapture()
  ├── state == .connecting → connectBuffer.append(data)
  └── state == .recording  → backend.sendAudioChunk(data: data)

backend.sendAudioChunk(data:)
  ├── GeminiLiveService: data.base64EncodedString() → JSON text frame → NWConnection
  └── DeepgramService:   URLSessionWebSocketTask.send(.data(data))

backend.onTranscriptUpdate(text, isFinal)
  ├── isFinal: true  → normalizeTranscription(text) → accumulatedTranscript += ...
  └── isFinal: false → show accumulatedTranscript + interim in overlay
```

### State Machine: TranscriptionCoordinator

```
        startRecording()
             │
          .idle ─────────────────────────────────────────────┐
             │                                               │
      mic check + api key check                      cleanup()
             │                                               │
         .connecting                                         │
             │ onSetupComplete                               │
         .recording ──────── stopRecording() ──── .processing
             │                                         │
          onError()                              deliverTranscript()
             │                                         │
         .error(_) ────────── cleanup() ──────────  .idle
```

### KeychainHelper Parameterization

```
// BEFORE:
KeychainHelper.read()          → account = "geminiAPIKey" (hardcoded)
KeychainHelper.write(value)    → account = "geminiAPIKey" (hardcoded)
KeychainHelper.delete()        → account = "geminiAPIKey" (hardcoded)

// AFTER:
KeychainHelper.read(account:)
KeychainHelper.write(_ value:, account:)
KeychainHelper.delete(account:)

AppSettings.geminiAPIKey:   get { KeychainHelper.read(account: "geminiAPIKey") }
AppSettings.deepgramAPIKey: get { KeychainHelper.read(account: "deepgramAPIKey") }
```

---

## Step-by-Step Implementation Order

The changes form a dependency chain. Implement in this order to avoid compile errors
at each step:

1. **`AppSettings.swift`** — parameterize `KeychainHelper`; add `deepgramAPIKey`
2. **`TranscriptionBackend.swift`** — new protocol file
3. **`GeminiLiveService.swift`** — conform to `TranscriptionBackend`; widen `onError`
4. **`DeepgramService.swift`** — new service
5. **`GeminiSessionCoordinator.swift` → `TranscriptionCoordinator.swift`** — rename + refactor
6. **`AppDelegate.swift`** — wire `TranscriptionCoordinator`
7. **`SettingsWindowController.swift`** — add Deepgram section + active backend label
8. **`build.sh`** — update file list
9. **`Tests/SettingsTests.swift`** — add new tests

---

## Implementation Notes Per File

### 1. `AppSettings.swift`

Change `KeychainHelper` from hardcoded `account = "geminiAPIKey"` to:
```swift
static func read(account: String) -> String? { ... }
static func write(_ value: String, account: String) { ... }
static func delete(account: String) { ... }
```

Update `geminiAPIKey` property:
```swift
var geminiAPIKey: String {
    get { KeychainHelper.read(account: "geminiAPIKey") ?? "" }
    set { KeychainHelper.write(newValue, account: "geminiAPIKey") }
}
```

Add `deepgramAPIKey` property (mirrors `geminiAPIKey`):
```swift
var deepgramAPIKey: String {
    get { KeychainHelper.read(account: "deepgramAPIKey") ?? "" }
    set {
        if newValue.isEmpty {
            KeychainHelper.delete(account: "deepgramAPIKey")
        } else {
            KeychainHelper.write(newValue, account: "deepgramAPIKey")
        }
    }
}
```

The `Keys` enum does NOT get a `deepgramAPIKey` entry — that would imply UserDefaults.
No UserDefaults migration needed (new key, no legacy data).

### 2. `TranscriptionBackend.swift` (new)

```swift
import Foundation

@MainActor
protocol TranscriptionBackend: AnyObject {
    var onTranscriptUpdate: ((String, Bool) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    var onDisconnected: (() -> Void)? { get set }
    var onSetupComplete: (() -> Void)? { get set }
    var currentPartialTranscript: String { get }
    func connect(apiKey: String) async throws
    func sendAudioChunk(data: Data)
    func sendStreamEnd()
    func disconnect()
    func sendActivityStart()
    func sendActivityBounce()
}

enum TranscriptionError: LocalizedError {
    case connectionFailed(String)
    var errorDescription: String? {
        switch self { case .connectionFailed(let msg): return msg }
    }
}
```

### 3. `GeminiLiveService.swift`

Changes needed:
- Add `conformance to TranscriptionBackend` on the class declaration
- Change `sendAudioChunk(base64: String)` → `sendAudioChunk(data: Data)`:
  ```swift
  func sendAudioChunk(data: Data) {
      sendAudioChunk(base64: data.base64EncodedString())
  }
  ```
  (keep the existing `private func sendAudioChunk(base64: String)` as internal impl)
- Change `onError: ((GeminiLiveError) -> Void)?` → `onError: ((Error) -> Void)?`
- Add `currentPartialTranscript: String` property (maps to `currentTurnTranscript`)

### 4. `DeepgramService.swift` (new)

```swift
import Foundation

@MainActor
final class DeepgramService: NSObject, TranscriptionBackend {
    var onTranscriptUpdate: ((String, Bool) -> Void)?
    var onError: ((Error) -> Void)?
    var onDisconnected: (() -> Void)?
    var onSetupComplete: (() -> Void)?
    private(set) var currentPartialTranscript: String = ""

    private var webSocketTask: URLSessionWebSocketTask?
    private var session: URLSession?
    private var connectContinuation: CheckedContinuation<Void, Error>?

    func connect(apiKey: String) async throws {
        let urlString = "wss://api.deepgram.com/v1/listen?model=nova-3&encoding=linear16&sample_rate=16000&interim_results=true&punctuate=true"
        var request = URLRequest(url: URL(string: urlString)!)
        request.setValue("Token \(apiKey)", forHTTPHeaderField: "Authorization")

        let config = URLSessionConfiguration.default
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        webSocketTask = session!.webSocketTask(with: request)

        try await withCheckedThrowingContinuation { [weak self] continuation in
            self?.connectContinuation = continuation
            self?.webSocketTask?.resume()
        }
        // Connection established — start receive loop
        startReceiveLoop()
        onSetupComplete?()
    }

    func sendAudioChunk(data: Data) {
        webSocketTask?.send(.data(data)) { _ in }
    }

    func sendStreamEnd() {
        // Deepgram closes cleanly on WebSocket close
    }

    func disconnect() {
        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        session?.finishTasksAndInvalidate()  // breaks URLSession retain cycle (session retains delegate)
        session = nil
    }

    func sendActivityStart() {}   // no-op
    func sendActivityBounce() {}  // no-op

    private func startReceiveLoop() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .success(let message):
                    if case .string(let text) = message {
                        self.handleMessage(text)
                    }
                    self.startReceiveLoop()  // re-arm
                case .failure(let error):
                    self.onError?(error)
                    self.onDisconnected?()
                }
            }
        }
    }

    private func handleMessage(_ json: String) {
        // Parse: { "channel": { "alternatives": [{ "transcript": "..." }] }, "is_final": true }
        guard let data = json.data(using: .utf8),
              let response = try? JSONDecoder().decode(DeepgramResponse.self, from: data),
              let text = response.channel.alternatives.first?.transcript,
              !text.isEmpty else { return }
        currentPartialTranscript = text
        onTranscriptUpdate?(text, response.isFinal)
    }
}

extension DeepgramService: URLSessionWebSocketDelegate, URLSessionTaskDelegate {
    nonisolated func urlSession(_ session: URLSession,
                                webSocketTask: URLSessionWebSocketTask,
                                didOpenWithProtocol protocol: String?) {
        Task { @MainActor [weak self] in
            self?.connectContinuation?.resume()
            self?.connectContinuation = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession,
                                task: URLSessionTask,
                                didCompleteWithError error: Error?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let continuation = self.connectContinuation {
                // Still in connect phase — WebSocket upgrade failed
                self.connectContinuation = nil
                if let httpResponse = task.response as? HTTPURLResponse,
                   httpResponse.statusCode == 401 {
                    continuation.resume(throwing: DeepgramError.unauthorized)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(throwing: DeepgramError.connectionFailed("WebSocket upgrade failed"))
                }
            } else if let error {
                // Post-connect disconnect
                self.onError?(error)
                self.onDisconnected?()
            }
        }
    }
}

// MARK: - Codable types

private struct DeepgramResponse: Codable {
    let channel: Channel
    let isFinal: Bool

    enum CodingKeys: String, CodingKey {
        case channel
        case isFinal = "is_final"
    }

    struct Channel: Codable {
        let alternatives: [Alternative]
    }

    struct Alternative: Codable {
        let transcript: String
    }
}

enum DeepgramError: LocalizedError {
    case unauthorized
    case connectionFailed(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized: return "Deepgram key invalid — check Settings"
        case .connectionFailed(let msg): return msg
        }
    }
}
```

### 5. `TranscriptionCoordinator.swift` (renamed from `GeminiSessionCoordinator.swift`)

Key changes from the existing coordinator:
- Replace `private let geminiService = GeminiLiveService()` with `private var backend: (any TranscriptionBackend)?`
- Change `connectBuffer: [String]` → `connectBuffer: [Data]`
- **Remove `setupGeminiCallbacks()` call from `init()`** — the new `init()` has no callback
  wiring at all. All backend setup happens in `startRecording()` after the backend is assigned.
- In `startRecording()`: select backend based on `settings.deepgramAPIKey.isEmpty`, wire callbacks, store as `backend`
- In `startAudioCapture()`: remove `data.base64EncodedString()` — store and forward `data` directly
- In `onSetupComplete` block: guard heartbeat timer + `onModelTurnComplete` wiring behind `backend is GeminiLiveService`
- In `stopRecording()`: change `geminiService.currentTurnTranscript` → `backend?.currentPartialTranscript ?? ""`
- In `connectWithRetry`: change `try await geminiService.connect(apiKey:)` → `try await backend!.connect(apiKey:)`; change fallback throw to `TranscriptionError.connectionFailed(...)`, do not retry on `DeepgramError.unauthorized`
- In `cleanup()`: call `backend?.disconnect()` instead of `geminiService.disconnect()`
- Rename `setupGeminiCallbacks()` → `setupBackendCallbacks()`; wire `backend?.onError`, `onDisconnected`, `onSetupComplete`, `onTranscriptUpdate`

API key selection logic in `startRecording()`:
```swift
let deepgramKey = settings.deepgramAPIKey
let geminiKey = settings.geminiAPIKey

if !deepgramKey.isEmpty {
    backend = DeepgramService()
    setupBackendCallbacks()
    // ... connectWithRetry using deepgramKey
} else {
    guard !geminiKey.isEmpty else { /* show "API key not configured" error */ return }
    backend = GeminiLiveService()
    setupBackendCallbacks()
    // ... connectWithRetry using geminiKey
}
```

### 6. `AppDelegate.swift`

Change `let coordinator = GeminiSessionCoordinator()` to `let coordinator = TranscriptionCoordinator()`.
No other changes needed — the public API surface is unchanged.

### 7. `SettingsWindowController.swift`

#### Information hierarchy

Settings window section order after this change:

```
[Gemini API Key]                                  ← existing, unchanged
  [masked field] [checkmark] [Edit/Save]
  "Get a free key at Google AI Studio →"
────────────────────────────────────────────
[Deepgram API Key (optional — fast mode)]        ← NEW section
  [masked field] [checkmark] [Edit/Save]
  "(Fast mode active — Deepgram Nova-3)"          ← only when both keys set
  "Get a free key at Deepgram →"
────────────────────────────────────────────
[Silence Detection]                               ← existing, shifted down
...
```

User reads the Deepgram section top-to-bottom: header → field row → backend status → link.

**User journey:**
- *First open (no Deepgram key)*: User sees the new section. Header "Deepgram API Key (optional — fast mode)" communicates that it is optional and hints at the benefit. Field is editable with placeholder "Paste your API key here". They can ignore it entirely — no disruption to existing flow.
- *Saving a key for the first time*: User pastes key, clicks Save. Status icon flips from dashed circle to green checkmark. If they already have a Gemini key, the backend label "(Fast mode active — Deepgram Nova-3)" appears immediately. This is the payoff moment — they have done the work and the app acknowledges it with a concrete label.
- *Clearing the key*: User clicks Edit, clears the field, clicks Save. Status reverts to dashed circle, backend label disappears. Back to Gemini-only mode.

#### Interaction states

The Deepgram key section mirrors the Gemini key section exactly. Full state matrix:

```
STATE                 | FIELD                          | BUTTON | STATUS ICON      | BACKEND LABEL
----------------------|--------------------------------|--------|------------------|----------------------------
No key stored         | empty, editable (placeholder)  | Save   | dashed circle    | hidden
No key, typing        | editable, text visible         | Save   | dashed circle    | hidden
Save (empty → empty)  | unchanged                      | Save   | dashed circle    | hidden
Save (value set)      | masked (••••••xxxx)            | Edit   | green checkmark  | shown only if geminiKey set
Edit mode (key saved) | raw key visible, editable      | Save   | green checkmark  | (per above)
Save (key cleared)    | empty, editable                | Save   | dashed circle    | hidden
```

On `loadValues()`:
- If `deepgramAPIKey.isEmpty`: field is empty + editable, button = "Save", status = dashed circle, backend label hidden
- If `deepgramAPIKey` not empty: field = masked, button = "Edit", status = green checkmark, backend label per geminiKey state
- If only Deepgram key is set (Gemini field empty): Deepgram green checkmark is shown, Gemini dashed circle is shown, backend label is hidden. No warning or additional UI is needed — transcription works fine in this state (FR-003). The implementer should NOT add a warning or badge for this case.

Active backend label visibility rule (re-evaluated on every save/clear of either key):
```swift
dgBackendLabel.isHidden = AppSettings.shared.deepgramAPIKey.isEmpty
                       || AppSettings.shared.geminiAPIKey.isEmpty
```
Call this check inside `dgKeyEditPressed()` (after saving/clearing Deepgram key) and also
inside `apiKeyEditPressed()` (after saving/clearing Gemini key) so the label updates
reactively when either key changes.

#### Implementation

Add a new "Deepgram API Key (optional — fast mode)" section directly below
the existing Gemini API key section. The implementation follows the exact same pattern:
- `NSTextField` (masked, edit/save/clear cycle) via `setDGKeyEditing(_:)` and `updateDGKeyStatus(key:)` helpers
- Save button with keychain write via `AppSettings.shared.deepgramAPIKey = key`
- Green checkmark (`checkmark.circle.fill`, `.systemGreen`) when key is non-empty; dashed circle (`.tertiaryLabelColor`) when empty
- Active backend label `"(Fast mode active — Deepgram Nova-3)"` — hidden/shown per rule above
- "Get a free key at Deepgram →" link (href: `https://console.deepgram.com/signup`)

New instance variables (parallel to existing Gemini vars):
```swift
private let dgKeyField     = NSTextField()
private let dgKeyStatus    = NSImageView()
private let dgKeyEditBtn   = NSButton()
private var dgKeyIsEditing = false
private let dgBackendLabel = NSTextField(labelWithString: "(Fast mode active — Deepgram Nova-3)")
// dgBackendLabel styling: .systemFont(ofSize: 11), .secondaryLabelColor (matches hotKeyNote pattern)
```

Use the existing layout helpers — do NOT hand-roll the layout:
```swift
stack.addArrangedSubview(row(sectionHeader("Deepgram API Key (optional — fast mode)"), top: p))
stack.addArrangedSubview(row(keyRow))          // keyRow = NSStackView([dgKeyField, dgKeyStatus, dgKeyEditBtn])
stack.addArrangedSubview(row(dgBackendLabel))  // hidden/shown per rule
stack.addArrangedSubview(row(linkBtn))
stack.addArrangedSubview(divider())
```
This matches the Gemini section structure exactly and inherits the dark-bg + padding design system automatically.

**Keyboard & accessibility:**
- `dgKeyField.target = self; dgKeyField.action = #selector(dgKeySavePressed)` — Return key triggers save (same as apiKeyField)
- Tab order flows naturally via NSStackView insertion order — no explicit `nextKeyView` needed
- `dgKeyStatus` NSImage symbols: pass `accessibilityDescription: "key set"` (non-empty state) and `"no key"` (empty state), not `nil`. This matches VoiceOver expectations. (Note: existing `apiKeyStatus` uses `nil` — do not copy that shortcut.)
- No responsive behavior needed: window is fixed 440px wide on macOS

**Post-processing note**: Post-processing (cleanup / summarize / custom prompt) requires
a Gemini API key regardless of which transcription backend is active. If only a Deepgram
key is set, transcription works, but post-processing is skipped and the overlay shows
`"Post-processing requires a Gemini API key."` before injecting the raw transcript.
Translation (Gemini key missing) continues to fail silently — that asymmetry is
intentional per the spec. The mode selector in Settings should remain visible
(not hidden) — it takes effect as soon as a Gemini key is added.

The warning overlay path in `TranscriptionCoordinator.deliverTranscript()`:
```swift
if postProcessingMode != .off && settings.geminiAPIKey.isEmpty {
    showOverlayStatus("Post-processing requires a Gemini API key.")
    // then inject rawTranscript immediately
}
```

### 8. `build.sh`

In the `SOURCES` array, replace:
- `Frespr/Coordinator/GeminiSessionCoordinator.swift` → `Frespr/Coordinator/TranscriptionCoordinator.swift`

Add:
- `Frespr/Coordinator/TranscriptionBackend.swift`
- `Frespr/Deepgram/DeepgramService.swift`

### 9. `Tests/SettingsTests.swift`

**Update the build comment header** (lines 1-23) to include new source files:
- Add `Frespr/Coordinator/TranscriptionBackend.swift`
- Add `Frespr/Deepgram/DeepgramService.swift`
- Replace `Frespr/Coordinator/GeminiSessionCoordinator.swift` with `Frespr/Coordinator/TranscriptionCoordinator.swift`

**Update `cleanKeychain()`** to also delete `deepgramAPIKey` from Keychain (prevents test state bleed).

Add the following tests:
1. `deepgramAPIKey` round-trip: write → read → verify non-empty → set to `""` → verify empty
2. `deepgramAPIKey` delete-on-empty: set `""` → confirm `KeychainHelper.read(account: "deepgramAPIKey")` returns nil
3. Backend selection: `deepgramKey = ""`, `geminiKey = "abc"` → `backend` is `GeminiLiveService`
4. Backend selection: `deepgramKey = "dg_xxx"` → `backend` is `DeepgramService`
5. Backend selection: both empty → `startRecording()` returns without crash, state stays `.idle`
6. `DeepgramService.handleMessage` with `is_final:false` → `onTranscriptUpdate?(text, false)` fired
7. `DeepgramService.handleMessage` with `is_final:true` → `onTranscriptUpdate?(text, true)` fired
8. `DeepgramService.handleMessage` with empty `transcript` → no callback fired
9. `DeepgramService.handleMessage` with malformed JSON → no crash

For tests 6-9: `handleMessage` must be `internal` (not `private`) to be callable from the test file.

**Regression test for connectBuffer type change:**
10. Audio chunk sent during `.connecting` state → `connectBuffer.count == 1`, element is raw `Data`
    (verify it is NOT a base64-encoded string — i.e., `connectBuffer[0]` equals the original `Data`)

---

## NOT in scope

- On-device backend (WhisperKit / Voxtral) — deferred to TODOS.md
- Latency pill in overlay — skipped
- Deepgram language selection — Deepgram auto-detects language; Gemini Live's language
  handling is unchanged
- Settings "Test key" button for Deepgram — not in spec; key is validated at connect time
- Fallback from Deepgram to Gemini if Deepgram fails — not in spec; `DeepgramError.unauthorized`
  shows an error and requires the user to fix their key
- User-selectable backend preference — backend is always Deepgram when key is set; no toggle needed

## What already exists

- `KeychainHelper` — exists in `AppSettings.swift`, just needs parameterization (no rebuild)
- `GeminiSessionCoordinator` — 90% of `TranscriptionCoordinator`; git rename + edits
- `SettingsWindowController` Gemini key section — exact pattern to copy for Deepgram section
- `GeminiLiveService` — existing, just needs `TranscriptionBackend` conformance + `onError` widening

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 2 | CLEAR | 3 proposals, 1 accepted, 1 deferred |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | — | — |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 2 | CLEAR (PLAN) | 6 issues, 0 critical gaps |
| Design Review | `/plan-design-review` | UI/UX gaps | 2 | CLEAR (FULL) | score: 5/10 → 9/10, 7 decisions |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

**VERDICT:** CEO + ENG + DESIGN CLEARED — ready to implement.
