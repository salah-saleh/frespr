# Frespr — Deferred Work

## On-device transcription backend (WhisperKit or Voxtral)

**What:** Add a third transcription backend that runs entirely on-device — no network,
no API key, no cost. The `TranscriptionBackend` protocol introduced in v1.6 makes this
a clean addition.

**Why:** The three-backend story (Gemini Live / Deepgram cloud / On-device) gives every
user an optimal choice. On-device is the only option with zero latency to network, zero
cost, and full privacy. Users who refuse to send audio to any cloud service currently
have no option; this closes that gap.

**Pros:**
- Eliminates the need for any API key for basic transcription
- Full privacy (audio never leaves the device)
- Works offline (airplane mode, conferences, low-signal environments)
- ~450ms latency with WhisperKit (vs ~2-3s Gemini Live)
- Voxtral Mini Realtime: ~240ms word-by-word streaming on Apple Silicon

**Cons:**
- ~800MB model download on first use (WhisperKit) or ~2-3GB (Voxtral GGUF Q4)
- Model must be downloaded before first use — needs explicit user opt-in UX
- Voxtral requires C/process integration (no polished Swift package yet as of April 2026)
- WhisperKit is chunk-based (~1s bursts) vs streaming token-by-token

**Context:** The `TranscriptionBackend` protocol from v1.6 (see `specs/main/spec.md`) is
the right foundation. Both WhisperKit and Voxtral need to conform to this protocol with
`connect(apiKey:)` as a no-op (or accepting a model path), `sendAudioChunk(data:)` feeding
the local model, and `onTranscriptUpdate` firing as the model produces tokens.
WhisperKit has a Swift package (`argmaxinc/WhisperKit`, macOS 14+). Voxtral requires
wrapping `voxtral.c` in a Swift `Process` and communicating over stdin/stdout.
See `docs/llm-alternatives.md` for full comparison.

**UX requirement:** Show an explicit "Download model (800MB)" prompt on first use rather
than downloading silently mid-session. Users must opt in knowingly.

**Effort:** L (human: ~1-2 weeks) / CC+gstack: ~1-2 hours
**Priority:** P2 — good for v1.7; not blocking v1.6
**Depends on:** v1.6 shipping with `TranscriptionBackend` protocol in place
