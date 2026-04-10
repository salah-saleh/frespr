# STT Backend Alternatives for Frespr

## Architecture constraint

Frespr streams raw 16kHz PCM audio over a bidirectional WebSocket and receives
incremental transcription tokens in real-time as the user speaks. This
"Live API" pattern rules out most models, which only accept complete audio
files via HTTP POST.

---

## The two latency problems (as of v1.5.0)

### Problem 1: ~2-3s inherent transcription lag

Gemini Live takes ~2-3 seconds from receiving audio to delivering the first
transcript segment. This is server-side infrastructure latency — the client
is sending audio on time and nothing client-side can reduce it.

### Problem 2: ~4s gap after each heartbeat bounce

After ~10 seconds of continuous recording (~100 audio chunks), Gemini Live
silently stops sending transcription updates. The workaround is a "heartbeat
bounce" — send `activityEnd` + `activityStart` every 8 seconds to reset the
server's turn window. After each bounce, the server takes ~4 seconds to
resume transcribing. This creates a noticeable gap in the overlay.

This is a confirmed Gemini Live server-side bug (multiple developers report
identical behavior; Google escalated, no fix timeline). It cannot be fixed
client-side.

---

## Options compared

| Provider | Streaming WebSocket | Latency (P50) | Heartbeat needed | Cost | Notes |
|---|---|---|---|---|---|
| **Gemini Live 2.5-flash** (current) | ✓ | ~2-3s | Yes (server bug) | Free tier | Post-processing on same API key |
| **Gemini Live 3.1-flash** | ✓ | Unknown | Likely yes | Free tier | Breaking API changes; not a drop-in |
| **Voxtral Mini Realtime** (on-device) | N/A | ~240ms | No | Free | Open-weight, runs on Metal; C/GGUF/MLX |
| **Voxtral Mini Transcribe API** | ✗ (batch) | ~300ms | No | $0.001/min | Cheaper than Whisper; batch only |
| **Deepgram Nova-3** | ✓ | ~150-300ms | No | $0.0043/min | Purpose-built STT; sub-300ms |
| **AssemblyAI Universal-3** | ✓ | ~150ms | No | $0.012/min | Promptable mid-conversation |
| **WhisperKit** (on-device) | N/A | ~450ms | No | Free | Runs on Apple Neural Engine; no network |
| **OpenAI Realtime API** | ✓ | ~300ms | No | ~$0.06/min | ~10× more expensive; US-only |
| **OpenAI Whisper REST** | ✗ | N/A | N/A | $0.006/min | File-upload only — incompatible with push-to-talk UX |
| **Azure Speech** | ✓ | ~300ms | No | $0.016/min | Enterprise-grade, complex setup |

---

## Detailed analysis

### Gemini Live 3.1-flash-live-preview

The newest Gemini Live model. **Not a drop-in swap.** Key breaking changes:

- **Server events contain multiple parts per message** — audio + transcript
  arrive in the same event. The current decoder maps one JSON blob to one typed
  response; the entire receive loop would need a rewrite.
- **`responseModalities: ["TEXT"]` no longer works** — native audio models only
  support `AUDIO` modality. To get a transcript, you must receive audio *and*
  parse `outputAudioTranscription`, even when you don't want audio.
- **No evidence** the heartbeat freeze bug is fixed — it's infrastructure-level,
  not model-level.

Verdict: High migration cost, no confirmed latency improvement for transcription.

### Deepgram Nova-3

Purpose-built streaming STT. Sub-300ms latency. The entire `GeminiLiveService`
complex manual WebSocket framing could be replaced with ~80 lines using standard
`URLSession.webSocketTask`. No heartbeat workaround needed — no freeze bug.

Tradeoffs:
- No post-processing (no LLM reasoning built in; would need a separate API call)
- Requires a Deepgram API key (~$0.0043/min = ~$0.26/hr)
- Audio goes to Deepgram servers

Best choice if: latency is the top priority and cost-per-use is acceptable.

### Voxtral Mini Realtime (Mistral, open-weight, on-device)

Released February 2026. This is the most interesting new entry. `Voxtral-Mini-4B-Realtime-2602`
is an open-weight 4B-parameter model built specifically for real-time streaming transcription.

Key facts:
- **240ms configurable minimum latency** (configurable up to 2.4s to trade accuracy for speed)
- **natively streaming architecture** with a causal audio encoder — tokens come out word-by-word as you speak, not in chunks after silence
- **Open weights, Apache 2.0** — run it locally, forever free
- **Apple Silicon support** via Metal (`make mps` in voxtral.c — "fastest" option)
- On M3 Max: encoder for 3.6s audio takes ~284ms; decoder ~31ms/step — runs ~2.5x faster than real-time
- **Live microphone input** built into voxtral.c (`--from-mic` flag, macOS)
- Community GGUF and MLX ports already exist for easy macOS deployment
- 13 languages including English, Spanish, French, German, Japanese, Mandarin, Arabic, Hindi

Tradeoffs vs WhisperKit:
- Smaller (4B vs Whisper Large v3 Turbo) — accuracy may be slightly lower on noisy audio
- Less mature macOS tooling than WhisperKit (no polished Swift package yet)
- C/GGUF integration requires more glue code than WhisperKit's Swift API

Frespr integration path: wrap `voxtral.c` or a GGUF runtime in a Swift `Process` and communicate
over stdin/stdout, similar to how some apps wrap `whisper.cpp`. Not a Swift-native package (yet),
but the streaming token API maps directly to Frespr's overlay update pattern.

**This is the most compelling on-device option right now** — faster minimum latency than WhisperKit,
open weights, and the causal encoder means words appear as you speak, not after a pause.

Best choice if: you want on-device with the lowest perceived latency and don't mind a C integration.

### WhisperKit (on-device)

Runs Whisper Large v3 Turbo natively on the Apple Neural Engine. No network,
no API key, no privacy concerns.

- **0.45s mean latency** for hypothesis (interim) text
- **1.7s for confirmed** (finalized) text — comparable to Gemini Live's best case
- 2.2% WER — best-in-class accuracy
- Works offline
- Swift package — integrates directly into macOS apps
- macOS 14+ required (already Frespr's minimum)
- ~200-300MB model download on first run

Published at ICML 2025 by Argmax; Apple contributed to the project. It's
production-ready.

Best choice if: offline capability, zero cost, or privacy are priorities.

---

## Current recommendation

**Stay on Gemini Live 2.5-flash for now.** Reasons:

1. **Free tier** — no billing setup required for personal use.
2. **Architecture fit** — the existing implementation works; switching requires
   significant effort.
3. **Post-processing** — same API key powers the optional cleanup/summarize
   step, adding value without extra credentials.

The current workarounds (serial send queue, heartbeat bounce, polling fallback)
bring the Gemini Live experience as close to optimal as possible given the
server-side constraints.

## When to migrate

| Priority | Migrate to |
|---|---|
| Eliminate the ~2-3s lag and 4s heartbeat gap, cloud | **Deepgram Nova-3** |
| Offline / free / lowest latency on-device | **Voxtral Mini Realtime** |
| Offline / polished Swift integration / best accuracy | **WhisperKit** |
| Best of both worlds | Settings toggle: Gemini Live / Deepgram / On-device |
| Cost is no concern, latency matters most | OpenAI Realtime API |

---

## References

- [Gemini Live API capabilities guide](https://ai.google.dev/gemini-api/docs/live-api/capabilities)
- [Gemini 3.1 Flash Live — breaking changes](https://blog.laozhang.ai/en/posts/gemini-3-1-flash-live-api)
- [Gemini Live high latency forum thread](https://discuss.ai.google.dev/t/gemini-live-api-models-high-latency/108989)
- [Deepgram Nova-3 streaming docs](https://developers.deepgram.com/docs/live-streaming-audio)
- [AssemblyAI Universal-3 (~150ms latency)](https://www.assemblyai.com/blog/best-api-models-for-real-time-speech-recognition-and-transcription)
- [WhisperKit paper (ICML 2025)](https://arxiv.org/abs/2507.10860)
- [WhisperKit GitHub](https://github.com/argmaxinc/WhisperKit)
- [Voxtral announcement (Mistral)](https://mistral.ai/news/voxtral)
- [Voxtral Mini 4B Realtime on Hugging Face](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602)
- [voxtral.c — pure C inference with Apple Silicon Metal support](https://github.com/antirez/voxtral.c)
- [Voxtral Transcribe 2 (VentureBeat)](https://venturebeat.com/technology/mistral-drops-voxtral-transcribe-2-an-open-source-speech-model-that-runs-on)
