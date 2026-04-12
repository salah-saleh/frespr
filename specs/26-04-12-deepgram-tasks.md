# Tasks: Deepgram + Gemini Hybrid Backend

**Spec**: specs/main/spec.md | **Plan**: specs/main/plan.md

## Format: `[ID] [P?] [Story] Description`
- **[P]**: Can run in parallel
- **[Story]**: Which user story (US1, US2, US3...)
- Include exact file paths

---

## Phase 1: Foundation — KeychainHelper + Protocol ⚠️ Blocks all stories

- [x] T001 [US1] Parameterize `KeychainHelper` in `AppSettings.swift`: change all three methods to accept `account: String` param; update `geminiAPIKey` getter/setter to pass `account: "geminiAPIKey"` explicitly
- [x] T002 [US1] Add `deepgramAPIKey` computed property to `AppSettings.swift` (Keychain-backed, same pattern as `geminiAPIKey`; no `Keys` enum entry — no UserDefaults)
- [x] T003 [P] [US1] Create `Frespr/Coordinator/TranscriptionBackend.swift` — `@MainActor` protocol with `onTranscriptUpdate`, `onError`, `onDisconnected`, `onSetupComplete`, `currentPartialTranscript`, `connect(apiKey:)`, `sendAudioChunk(data:)`, `sendStreamEnd()`, `disconnect()`, `sendActivityStart()`, `sendActivityBounce()`; also define `TranscriptionError` enum here

**Checkpoint**: Foundation ready — US1 (Deepgram) and US3 (Settings) can begin.

---

## Phase 2: Gemini conformance ⚠️ Prerequisite for coordinator rename

- [x] T010 [US2] Conform `GeminiLiveService` to `TranscriptionBackend` (`Frespr/Gemini/GeminiLiveService.swift`): add `TranscriptionBackend` to class declaration
- [x] T011 [US2] Add public `sendAudioChunk(data: Data)` to `GeminiLiveService` that calls existing private `sendAudioChunk(base64: String)` after base64-encoding; rename internal helper to `sendAudioChunkBase64(_:)` if needed for clarity
- [x] T012 [US2] Widen `onError` type in `GeminiLiveService` from `((GeminiLiveError) -> Void)?` → `((Error) -> Void)?`
- [x] T013 [P] [US2] Add `currentPartialTranscript: String` computed property to `GeminiLiveService` — maps to existing `currentTurnTranscript`

**Checkpoint**: `GeminiLiveService` conforms to `TranscriptionBackend`. Verify type-check passes.

---

## Phase 3: DeepgramService (new file) — US1

- [x] T020 [US1] Create `Frespr/Deepgram/DeepgramService.swift`: `@MainActor final class DeepgramService: NSObject, TranscriptionBackend`
- [x] T021 [US1] Implement `connect(apiKey:) async throws` in `DeepgramService` using `URLSessionWebSocketTask` + `CheckedContinuation`; URL: `wss://api.deepgram.com/v1/listen?model=nova-3&encoding=linear16&sample_rate=16000&interim_results=true&punctuate=true`; auth header: `Token \(apiKey)`
- [x] T022 [US1] Implement `URLSessionWebSocketDelegate.urlSession(_:webSocketTask:didOpenWithProtocol:)` — resume continuation only; `startReceiveLoop()` and `onSetupComplete?()` are called in `connect()` after the continuation resolves (NOT inside the delegate callback)
- [x] T023 [US1] Implement `URLSessionTaskDelegate.urlSession(_:task:didCompleteWithError:)` — 401 detection via `HTTPURLResponse.statusCode` + fallback for nil response (throw `DeepgramError.unauthorized`); post-connect error path calls `onError?` + `onDisconnected?`
- [x] T024 [US1] Implement `startReceiveLoop()` — `webSocketTask?.receive` with `Task { @MainActor }` dispatch; re-arm on success; call `onError?`/`onDisconnected?` on failure
- [x] T025 [US1] Implement `handleMessage(_ json: String)` as `internal` (not private — test visibility): decode `DeepgramResponse` (`is_final`, `channel.alternatives[0].transcript`); set `currentPartialTranscript`; fire `onTranscriptUpdate?(text, isFinal)` only if `!text.isEmpty`
- [x] T026 [P] [US1] Implement `sendAudioChunk(data:)`, `disconnect()` (including `session?.finishTasksAndInvalidate()` to break retain cycle), `sendStreamEnd()`, `sendActivityStart()`, `sendActivityBounce()` in `DeepgramService`
- [x] T027 [P] [US1] Define `DeepgramResponse` (private Codable struct), `DeepgramError` enum with `unauthorized` and `connectionFailed(String)` in `DeepgramService.swift`

**Checkpoint**: `DeepgramService` compiles and conforms to protocol. Type-check passes.

---

## Phase 4: Coordinator Rename + Refactor — US1 + US2

- [x] T030 [US1] Rename `Frespr/Coordinator/GeminiSessionCoordinator.swift` → `Frespr/Coordinator/TranscriptionCoordinator.swift`; rename class `GeminiSessionCoordinator` → `TranscriptionCoordinator`
- [x] T031 [US1] Replace `private let geminiService = GeminiLiveService()` with `private var backend: (any TranscriptionBackend)?` in `TranscriptionCoordinator`
- [x] T032 [US1] Change `connectBuffer: [String]` → `connectBuffer: [Data]` in `TranscriptionCoordinator`; update `startAudioCapture()` to store raw `Data` directly (remove `data.base64EncodedString()`); update buffer flush to call `backend?.sendAudioChunk(data: chunk)`
- [x] T033 [US1] Remove `setupGeminiCallbacks()` call from `init()`; rename to `setupBackendCallbacks()` and update to wire `backend?.onError`, `backend?.onDisconnected`, `backend?.onSetupComplete`, `backend?.onTranscriptUpdate`
- [x] T034 [US1] In `startRecording()`: add backend selection logic — `if !deepgramKey.isEmpty { backend = DeepgramService() } else { backend = GeminiLiveService() }`; call `setupBackendCallbacks()` after assignment
- [x] T035 [US1] Guard heartbeat timer start and `onModelTurnComplete` wiring behind `if backend is GeminiLiveService { ... }` conditional downcasts
- [x] T036 [US1] In `stopRecording()`: change `geminiService.currentTurnTranscript` → `backend?.currentPartialTranscript ?? ""`
- [x] T037 [US1] In `connectWithRetry()`: change `try await geminiService.connect(apiKey:)` → `try await backend!.connect(apiKey:)`; change fallback throw to `TranscriptionError.connectionFailed("Max retries exceeded")`; add guard to not retry on `DeepgramError.unauthorized` (throw immediately)
- [x] T038 [US2] In `cleanup()`: call `backend?.disconnect()` instead of `geminiService.disconnect()`

- [x] T039 [US1] In `TranscriptionCoordinator.deliverTranscript()`: add guard before calling `GeminiPostProcessor` — if `postProcessingMode != .off && settings.geminiAPIKey.isEmpty`, show overlay string `"Post-processing requires a Gemini API key."` and inject raw transcript immediately (skip post-processing); translation failure path remains silent (existing behavior, no change)

**Checkpoint**: Coordinator compiles. No references to `GeminiSessionCoordinator` or `geminiService` remain.

---

## Phase 5: Wire AppDelegate + Build — US1 + US2

- [x] T040 [US1] In `Frespr/App/AppDelegate.swift`: change `let coordinator = GeminiSessionCoordinator()` → `let coordinator = TranscriptionCoordinator()`
- [x] T041 [US1] In `build.sh`: replace `Frespr/Coordinator/GeminiSessionCoordinator.swift` with `Frespr/Coordinator/TranscriptionCoordinator.swift`; add `Frespr/Coordinator/TranscriptionBackend.swift`; add `Frespr/Deepgram/DeepgramService.swift`

**Checkpoint**: Run `bash build.sh` — must compile and launch without errors.

---

## Phase 6: Settings UI — US3 🎯 Parallel once Phase 1 done

*Can start after T001-T002 (Phase 1) complete — no dependency on Phases 2-5.*

- [x] T050 [P] [US3] Add instance variables to `SettingsWindowController.swift`: `dgKeyField` (`NSTextField`), `dgKeyStatus` (`NSImageView`), `dgKeyEditBtn` (`NSButton`), `dgKeyIsEditing: Bool = false`, `dgBackendLabel` (`NSTextField(labelWithString:)` with 11pt secondary color)
- [x] T051 [US3] Add Deepgram section to the NSStackView in `SettingsWindowController.swift` using existing layout helpers: `sectionHeader("Deepgram API Key (optional — fast mode)")`, `row(keyRow)`, `row(dgBackendLabel)`, `row(linkBtn)`, `divider()` — insert immediately after the existing Gemini section
- [x] T052 [US3] Implement `setDGKeyEditing(_ editing: Bool)` helper in `SettingsWindowController` — mirrors `setAPIKeyEditing(_:)` exactly: toggle field editability, show/hide raw vs masked text, update button title
- [x] T053 [US3] Implement `updateDGKeyStatus(key: String)` helper — mirrors `updateAPIKeyStatus(key:)`: green `checkmark.circle.fill` when non-empty, dashed circle (`.tertiaryLabelColor`) when empty; use `accessibilityDescription: "key set"` / `"no key"` (NOT nil — do not copy `apiKeyStatus` nil shortcut)
- [x] T054 [US3] Implement `dgKeyEditPressed()` / `dgKeySavePressed()` actions in `SettingsWindowController`: save → `AppSettings.shared.deepgramAPIKey = key`; clear → `AppSettings.shared.deepgramAPIKey = ""`; re-evaluate `dgBackendLabel.isHidden` after each save/clear
- [x] T055 [US3] Wire `dgKeyField.target = self; dgKeyField.action = #selector(dgKeySavePressed)` so Return key triggers save
- [x] T056 [US3] Update `loadValues()` in `SettingsWindowController` to initialize Deepgram section state: `setDGKeyEditing(deepgramKey.isEmpty)` + `updateDGKeyStatus(key: deepgramKey)` + set `dgBackendLabel.isHidden`
- [x] T057 [US3] Update `apiKeyEditPressed()` / `apiKeySavePressed()` (Gemini section) to also re-evaluate `dgBackendLabel.isHidden` — so backend label updates reactively when Gemini key changes
- [x] T058 [P] [US3] Add "Get a free key at Deepgram →" link button pointing to `https://console.deepgram.com/signup` (mirrors existing Google AI Studio link pattern)

**Checkpoint**: Settings window shows Deepgram section. State matrix works correctly for all 6 states.

---

## Phase 7: Tests 🎯 Final

- [x] T060 [US1] Update build comment header in `Tests/SettingsTests.swift` to include `Frespr/Coordinator/TranscriptionBackend.swift`, `Frespr/Deepgram/DeepgramService.swift`; replace `GeminiSessionCoordinator.swift` with `TranscriptionCoordinator.swift`
- [x] T061 [P] [US1] Update `cleanKeychain()` in `SettingsTests.swift` to also delete `deepgramAPIKey` from Keychain (prevents test state bleed)
- [x] T062 [P] [US3] Add `deepgramAPIKey` round-trip test: write → read → verify non-empty → set `""` → verify empty
- [x] T063 [P] [US3] Add `deepgramAPIKey` delete-on-empty test: set `""` → confirm `KeychainHelper.read(account: "deepgramAPIKey")` returns nil
- [x] T064 [P] [US1] Add backend selection test: `deepgramKey = ""`, `geminiKey = "abc"` → `backend` is `GeminiLiveService`
- [x] T065 [P] [US1] Add backend selection test: `deepgramKey = "dg_xxx"` → `backend` is `DeepgramService`
- [x] T066 [P] [US1] Add backend selection test: both keys empty → `startRecording()` returns without crash, state stays `.idle`
- [x] T067 [P] [US1] Add `DeepgramService.handleMessage` test: `is_final: false` → `onTranscriptUpdate?(text, false)` fired
- [x] T068 [P] [US1] Add `DeepgramService.handleMessage` test: `is_final: true` → `onTranscriptUpdate?(text, true)` fired
- [x] T069 [P] [US1] Add `DeepgramService.handleMessage` test: empty transcript → no callback fired
- [x] T070 [P] [US1] Add `DeepgramService.handleMessage` test: malformed JSON → no crash
- [x] T071 [P] [US1] Add connectBuffer regression test: audio chunk sent during `.connecting` state → `connectBuffer.count == 1`, element is raw `Data` (not base64 string — verify `connectBuffer[0]` equals the original `Data`)
- [x] T072 [US1] Run full test suite: `swiftc` compile + `/tmp/SettingsTests` — all tests must pass; verify SC-002: run with `deepgramAPIKey` cleared and confirm behavior is identical to pre-change Gemini path (existing tests must all still pass, no regressions)

**Checkpoint**: All tests green. `bash build.sh` succeeds.
