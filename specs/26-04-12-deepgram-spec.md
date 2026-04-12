# Feature Specification: Deepgram + Gemini Hybrid Backend

**Feature Branch**: `main`
**Created**: 2026-04-10
**Status**: Draft

## Overview

Add Deepgram Nova-3 as an optional primary transcription backend. When the user
has configured both a Deepgram API key and a Gemini API key, Deepgram handles
live transcription (150-300ms latency, no heartbeat workaround needed) and
Gemini REST handles post-processing after hotkey release. When only a Gemini API
key is present, the app behaves exactly as today (Gemini Live for transcription
+ Gemini REST for post-processing). No behavior change for existing users.

---

## User Scenarios & Testing

### User Story 1 — Deepgram mode: fast live transcription (Priority: P1)

A user who has configured both a Deepgram API key and a Gemini API key holds the
hotkey and speaks. Words appear in the overlay within ~300ms, flowing word by word
with no 4-second heartbeat gaps. On release, the transcript is optionally cleaned
up by Gemini REST and injected as usual.

**Why this priority**: This is the core value of the feature — eliminating the lag
and heartbeat gap that makes Gemini Live feel sluggish on long recordings.

**Independent test**: Configure both keys. Hold hotkey, speak for 15+ seconds.
Observe overlay updates arrive continuously without gaps. Release hotkey, observe
final text injected (post-processed if enabled).

**Acceptance Scenarios**:

1. **Given** both Deepgram and Gemini API keys are set, **When** the user holds
   the hotkey and speaks, **Then** the overlay shows interim transcript updates
   within 300ms of each spoken phrase, with no gaps longer than 2 seconds.

2. **Given** both keys are set and post-processing is enabled, **When** the user
   releases the hotkey, **Then** Gemini REST refines the Deepgram transcript and
   the polished text is injected into the focused app.

3. **Given** both keys are set and post-processing is off, **When** the user
   releases the hotkey, **Then** the raw Deepgram transcript is injected directly
   without any Gemini REST call.

4. **Given** both keys are set, **When** the user records for 30+ seconds, **Then**
   the overlay never shows a 4-second gap (no heartbeat bounce needed).

---

### User Story 2 — Gemini-only fallback: zero behavior change (Priority: P1)

A user who has only a Gemini API key (no Deepgram key) uses Frespr exactly as
before. Nothing has changed for them. The Deepgram API key field is visible but
optional in Settings.

**Why this priority**: Backward compatibility. Existing users must not be disrupted.

**Independent test**: Delete the Deepgram key from Settings (or never set one).
Hold hotkey, speak, release. Behavior is identical to v1.4.x (current released version).

**Acceptance Scenarios**:

1. **Given** only the Gemini API key is set (Deepgram field is empty), **When**
   the user holds the hotkey, **Then** the app uses Gemini Live for transcription,
   exactly as in v1.4.x (current released version) including the heartbeat workaround.

2. **Given** only the Gemini key is set, **When** the user opens Settings, **Then**
   the Deepgram API key field is visible, empty, and labelled as optional.

---

### User Story 3 — Settings: add and validate Deepgram key (Priority: P2)

A user opens Settings, pastes a Deepgram API key into the new field, and sees a
confirmation that the key is saved. The key is masked after saving, matching the
Gemini key UX.

**Why this priority**: Required for users to switch to Deepgram mode.

**Independent test**: Open Settings with no Deepgram key. Paste a key. Close
Settings. Reopen Settings. The key appears masked with a checkmark.

**Acceptance Scenarios**:

1. **Given** the Settings window is open, **When** the user pastes a Deepgram key
   and clicks Save, **Then** the key is stored in the Keychain (separate from the
   Gemini key), the field shows a masked value, and a green checkmark appears.

2. **Given** a Deepgram key is saved, **When** the user clicks Edit and clears the
   field and saves, **Then** the Deepgram key is deleted from the Keychain and the
   app falls back to Gemini Live mode.

---

### Edge Cases

- What if the Deepgram WebSocket connection fails mid-recording? `TranscriptionCoordinator`
  calls `deliverTranscript` with `backend.currentPartialTranscript` (matching the Gemini
  `onDisconnected` path), sets `SessionState` to `.error`, and shows the standard error
  overlay string "Transcription disconnected". Do not crash or hang. On disconnect,
  `accumulatedTranscript` holds text accumulated from `is_final: true` events received
  before the disconnect; `deliverTranscript()` drains it as-is.
- What if the Gemini key is missing but a Deepgram key is present? Deepgram can
  handle transcription, but post-processing requires a Gemini key. In this case:
  transcribe via Deepgram, skip post-processing (regardless of setting), inject
  raw transcript. Show a warning in the overlay each time the condition is triggered:
  "Post-processing requires a Gemini API key." (Note: translation failure in this case
  is silent — the existing `guard !apiKey.isEmpty` returns rawText without a warning.
  The two behaviors are intentionally asymmetric: post-processing is an explicit user
  setting the user knows they enabled; translation has the same silent guard.)
- What if both keys are set but Deepgram returns an auth error (401)? Show an error
  in the overlay ("Deepgram key invalid — check Settings"), do not fall back silently
  to Gemini Live (user should know which key is broken).
- What happens during a network timeout on the Deepgram WebSocket? Apply the same
  4-second fallback polling logic currently used for Gemini Live: inject whatever
  partial transcript was received via `backend.currentPartialTranscript`.

---

## Requirements

### Functional Requirements

- **FR-001**: When `deepgramAPIKey` is non-empty, the app MUST use `DeepgramService`
  for live transcription instead of `GeminiLiveService`.
- **FR-002**: When `deepgramAPIKey` is empty, the app MUST behave identically to
  v1.4.x (current released version) (Gemini Live transcription + Gemini REST post-processing).
- **FR-003**: Post-processing via `GeminiPostProcessor` MUST work unchanged
  regardless of which transcription backend is active.
- **FR-004**: `AppSettings` MUST store the Deepgram API key in the Keychain under
  a separate account key (`deepgramAPIKey`), not the same entry as the Gemini key.
  `deepgramAPIKey` MUST never be stored in `UserDefaults`. `KeychainHelper` MUST be
  parameterized (accept an `account` argument) rather than hardcoded to `geminiAPIKey`.
- **FR-005**: `SettingsWindowController` MUST add a "Deepgram API Key" section directly
  below the "Gemini API Key" section, with the same edit/save/mask/checkmark UX. The
  section is labelled "Deepgram API Key (optional — enables fast mode)". When both keys
  are set, a label "(Fast mode active — Deepgram Nova-3)" MUST appear below the Deepgram
  field to confirm which backend is in use.
- **FR-006**: `GeminiSessionCoordinator.swift` MUST be renamed to
  `TranscriptionCoordinator.swift` (same directory, git rename preserves history).
  `TranscriptionCoordinator` selects the active backend once at the start of each
  `startRecording()` call based on `AppSettings.shared.deepgramAPIKey.isEmpty`; a
  key change mid-session does not affect the current recording. `cleanup()` MUST call
  `backend.disconnect()` (not `geminiService.disconnect()`). `connectWithRetry`'s
  last-error fallback MUST NOT throw a `GeminiLiveError` — it must use a generic
  `Error` (e.g. a new `TranscriptionError.connectionFailed(String)` case). Auth errors
  (401 from Deepgram or auth failure from Gemini) MUST NOT be retried; `connectWithRetry`
  applies only to transient connection failures.
- **FR-007**: A `TranscriptionBackend` protocol (new file
  `Frespr/Coordinator/TranscriptionBackend.swift`) MUST define the interface both
  services conform to:
  ```swift
  @MainActor
  protocol TranscriptionBackend: AnyObject {
      var onTranscriptUpdate: ((String, Bool) -> Void)? { get set }
      var onError: ((Error) -> Void)? { get set }   // widened from GeminiLiveError → Error
      var onDisconnected: (() -> Void)? { get set }
      var onSetupComplete: (() -> Void)? { get set }
      var currentPartialTranscript: String { get }
      func connect(apiKey: String) async throws
      func sendAudioChunk(data: Data)   // raw PCM bytes — NOT base64
      func sendStreamEnd()
      func disconnect()
      func sendActivityStart()          // no-op in DeepgramService
      func sendActivityBounce()         // no-op in DeepgramService
  }
  ```
  Both `DeepgramService` and `GeminiLiveService` MUST be `@MainActor` classes conforming
  to this protocol. `URLSessionWebSocketTask` and `NWConnection` callbacks must be
  explicitly dispatched to `MainActor` in each service's receive loop.
  `GeminiLiveService.onError` MUST be widened from `((GeminiLiveError) -> Void)?` to
  `((Error) -> Void)?` to satisfy protocol conformance. All call sites casting the error
  back to `GeminiLiveError` must be updated accordingly (there is one: in
  `TranscriptionCoordinator.setupBackendCallbacks()`). Note: `TranscriptionBackend.onError`
  (protocol-level, `((Error) -> Void)?`) is distinct from `TranscriptionCoordinator.onError`
  (UI-level, `((String) -> Void)?`). The coordinator converts the `Error` to a localized
  string in `setupBackendCallbacks()` before calling its own outbound `onError`.
- **FR-008**: `DeepgramService` MUST connect to
  `wss://api.deepgram.com/v1/listen?model=nova-3&encoding=linear16&sample_rate=16000&interim_results=true&punctuate=true`
  using `URLSessionWebSocketTask` (safe for `api.deepgram.com` — Deepgram supports HTTP/1.1
  upgrade correctly, unlike Gemini which requires raw `NWConnection`), and call
  `URLSessionWebSocketTask.send(.data(rawPCM))` — no manual frame encoding needed,
  `URLSessionWebSocketTask` handles WebSocket framing automatically.
  Deepgram JSON responses follow this schema:
  `{ "channel": { "alternatives": [{ "transcript": "..." }] }, "is_final": true }`.
  Each response with `is_final: false` is a **full replacement** transcript for the current
  utterance (not an incremental chunk). `onTranscriptUpdate` must emit the full replacement
  text with `isFinal: false`. Only `is_final: true` events are appended to
  `accumulatedTranscript` in the coordinator. Map `is_final` to the `Bool` parameter of
  `onTranscriptUpdate(text:isFinal:)`. Note: Deepgram also emits `speech_final: true` at
  end-of-utterance; this is NOT used for `accumulatedTranscript` appends — use `is_final`
  only, which fires more frequently and gives finer-grained confirmed text during long
  recordings. Noise annotation stripping in `normalizeTranscription()` is safe (Deepgram
  does not emit `[noise]` tokens); the ALL-CAPS guard is also safe (Deepgram returns
  properly-cased text so the guard never fires). The receive loop MUST dispatch to
  `MainActor` using `Task { @MainActor [weak self] in ... }` consistent with `GeminiLiveService`.
- **FR-009**: `DeepgramService` MUST detect HTTP 401 during WebSocket upgrade (invalid
  API key) and throw `DeepgramError.unauthorized`, which `TranscriptionCoordinator` maps
  to the user-visible error "Deepgram key invalid — check Settings". It MUST NOT fall
  back silently to Gemini Live. Detection mechanism: implement
  `URLSessionTaskDelegate.urlSession(_:task:didCompleteWithError:)`. When the error is
  non-nil and `(task.response as? HTTPURLResponse)?.statusCode == 401`, throw
  `DeepgramError.unauthorized`. If `task.response` is nil at that point (TLS/network
  failure before HTTP response), treat as `DeepgramError.connectionFailed` — not
  unauthorized. This distinction prevents spurious auth-error UI on network drops.
- **FR-010**: `GeminiLiveService` MUST be updated to conform to `TranscriptionBackend`.
  Its `sendAudioChunk` method signature changes from `(base64: String)` to `(data: Data)`;
  it encodes to base64 internally before passing to the existing text-frame pipeline.
  `sendActivityStart()` and `sendActivityBounce()` are already implemented and map directly
  to the protocol. `onError` MUST be widened to `((Error) -> Void)?` (see FR-007).
- **FR-011**: The overlay update path (interim transcript → `OverlayView`) MUST
  work identically for both backends — same `onTranscriptUpdate` callback contract.
- **FR-012**: All three Gemini-specific coordinator behaviors MUST be guarded on
  `backend is GeminiLiveService`: (1) the heartbeat timer (started in `onSetupComplete`),
  (2) the `heartbeatBounceInFlight` flag (reset + checked in heartbeat logic), and
  (3) the `onModelTurnComplete` callback wiring (used to re-send `activityStart` after
  the model finishes its audio response). For `DeepgramService`, `onModelTurnComplete`
  does not exist — this callback is wired only when `backend is GeminiLiveService` via
  a conditional downcast: `(backend as? GeminiLiveService)?.onModelTurnComplete = { ... }`.
- **FR-013**: `TranscriptionCoordinator` connectBuffer MUST be typed as `[Data]` (not
  `[String]`), storing raw PCM chunks captured during WebSocket handshake. Both
  backends receive `sendAudioChunk(data:)` — no base64 conversion in the coordinator.
  `startAudioCapture()` in `TranscriptionCoordinator` MUST store raw `Data` directly
  into `connectBuffer` (and forward raw `Data` to `backend.sendAudioChunk(data:)`)
  instead of converting to base64 before buffering. The `connectBuffer` flush loop in
  `onSetupComplete` MUST call `backend.sendAudioChunk(data:)` — not the old
  `geminiService.sendAudioChunk(base64:)` form.
- **FR-014**: The 4-second polling fallback in `stopRecording()` MUST use
  `backend.currentPartialTranscript` (protocol property) instead of
  `geminiService.currentTurnTranscript` (Gemini-specific). `GeminiLiveService` maps
  `currentPartialTranscript` to its existing `currentTurnTranscript`. `DeepgramService`
  returns the last interim transcript received (or empty string).
- **FR-015** (no new code required): If only a Deepgram key is set (no Gemini key)
  and translation is enabled, translation silently returns raw text unchanged. The
  existing `guard !apiKey.isEmpty else { return rawText }` in `translate()` already
  handles this. This requirement documents existing behavior that must not be broken;
  no implementation work is needed.

### Key Entities

- **`TranscriptionBackend`**: New protocol file `Frespr/Coordinator/TranscriptionBackend.swift`.
  Defines the interface all transcription services conform to. Enables backend-agnostic
  coordinator logic and trivially extensible to future backends (WhisperKit, Voxtral).
- **`DeepgramService`**: New file `Frespr/Deepgram/DeepgramService.swift`. Owns
  the Deepgram WebSocket connection lifecycle. Conforms to `TranscriptionBackend`.
  Sends binary PCM frames. Parses Deepgram JSON responses. Implements `sendActivityStart()`
  and `sendActivityBounce()` as no-ops.
- **`TranscriptionCoordinator`**: Replaces `GeminiSessionCoordinator` (file rename).
  Routes to `DeepgramService` or `GeminiLiveService` based on which API keys are present.
  Owns the same state machine (idle → connecting → recording → processing). Heartbeat
  timer only started when `backend is GeminiLiveService`.
- **`AppSettings.deepgramAPIKey`**: New property on `AppSettings`, backed by a
  separate Keychain entry via parameterized `KeychainHelper`. Empty string = Gemini Live mode.

### Files changed

| File | Change |
|---|---|
| `Frespr/Storage/AppSettings.swift` | Add `deepgramAPIKey` Keychain property; parameterize `KeychainHelper` |
| `Frespr/UI/SettingsWindowController.swift` | Add Deepgram API key section + active backend label |
| `Frespr/Coordinator/GeminiSessionCoordinator.swift` | Rename to `TranscriptionCoordinator.swift`; refactor to use `TranscriptionBackend` protocol |
| `Frespr/Coordinator/TranscriptionBackend.swift` | New protocol file |
| `Frespr/Deepgram/DeepgramService.swift` | New file |
| `Frespr/Gemini/GeminiLiveService.swift` | Conform to `TranscriptionBackend`; change `sendAudioChunk` to accept `Data` |
| `Frespr/App/AppDelegate.swift` | Wire `TranscriptionCoordinator` instead of `GeminiSessionCoordinator` |
| `build.sh` | Remove `Frespr/Coordinator/GeminiSessionCoordinator.swift`; add `Frespr/Coordinator/TranscriptionCoordinator.swift`, `Frespr/Coordinator/TranscriptionBackend.swift`, `Frespr/Deepgram/DeepgramService.swift` |
| `Tests/SettingsTests.swift` | Add `deepgramAPIKey` round-trip test + backend selection tests |

---

## Success Criteria

- **SC-001**: With both keys set, recording for 20 seconds shows no overlay gap
  longer than 2 seconds.
- **SC-002**: With only a Gemini key, behavior is byte-for-byte identical to v1.4.x (current released version)
  (verified by running existing test suite with no changes).
- **SC-003**: Deepgram API key is stored in Keychain, not UserDefaults (verified
  by inspecting `UserDefaults.standard` after save — key must not appear there).
- **SC-004**: Removing the Deepgram key and restarting falls back to Gemini Live
  without requiring any other settings change.
- **SC-005**: All existing tests pass.

---

## GSTACK REVIEW REPORT

| Review | Trigger | Why | Runs | Status | Findings |
|--------|---------|-----|------|--------|----------|
| CEO Review | `/plan-ceo-review` | Scope & strategy | 2 | CLEAR | 3 proposals, 1 accepted, 1 deferred; spec improved from 5/10 → 8/10 via 2-round adversarial review |
| Codex Review | `/codex review` | Independent 2nd opinion | 0 | — | — |
| Eng Review | `/plan-eng-review` | Architecture & tests (required) | 0 | — | Run after plan.md is written |
| Design Review | `/plan-design-review` | UI/UX gaps | 0 | — | Run after plan.md is written |
| DX Review | `/plan-devex-review` | Developer experience gaps | 0 | — | — |

**VERDICT:** CEO CLEARED — run `/plan-eng-review` after Step 7 (plan.md).
