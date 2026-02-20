# LLM Alternatives for Frespr

## Architecture constraint

Frespr streams raw PCM audio over a bidirectional WebSocket and receives
incremental transcription tokens in real-time as the user speaks. This
"Live API" pattern rules out most models, which only accept complete audio
files via HTTP POST.

## Options compared

| Provider | Realtime WebSocket | Transcription quality | Cost | Notes |
|---|---|---|---|---|
| **Gemini Live** (current) | ✓ Native | Very good | Free tier available | Only free option; fits existing architecture exactly |
| **OpenAI Realtime API** | ✓ | Very good | ~10× more expensive | WebSocket-based but US-only, expensive |
| **Deepgram Nova-3** | ✓ | Excellent | $0.0043 / min | Transcription-only, no LLM reasoning; very low latency |
| **AssemblyAI Universal** | ✓ | Good | $0.012 / min | Streaming transcription, simple API |
| **OpenAI Whisper** | ✗ | Excellent | $0.006 / min | File-upload only — requires recording whole session first, incompatible with push-to-talk UX |
| **Azure Speech** | ✓ | Very good | $0.016 / min | Enterprise-grade, complex setup |

## Recommendation

**Keep Gemini Live.** Reasons:

1. **Free tier** — no billing setup required for personal use.
2. **Architecture fit** — the existing raw NWConnection WebSocket implementation
   works perfectly; switching would require a full rewrite of `GeminiLiveService`.
3. **Quality** — transcription quality is good enough for voice-to-text dictation,
   especially with the sentence-case normalization applied client-side.
4. **Post-processing** — Gemini's standard REST API can be used (same API key)
   for optional cleanup/summarization after transcription, adding value without
   extra credentials.

## When to reconsider

- If transcription accuracy becomes a recurring problem → try **Deepgram Nova-3**
  (best-in-class accuracy, purpose-built for transcription, ~$0.26/hr).
- If cost is no concern and latency matters most → **OpenAI Realtime API**.
- If you want offline/on-device → **Apple's built-in SFSpeechRecognizer** (free,
  private, but lower accuracy and no punctuation).
