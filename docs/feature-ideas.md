# Frespr Feature Ideas

Potential features to implement in future sessions.

---

## 1. Streaming Injection 
Inject words live as they arrive from the Gemini Live API, rather than waiting until the hotkey is released. Configurable: "Classic" (inject full transcript after release) vs "Streaming" (inject words live while speaking). Post-processing is automatically disabled in streaming mode.

## 2. Custom Hotkey
Allow the user to configure any key or key combination as the hotkey, instead of being fixed to Right Option. Could use a key-capture text field in Settings (press the keys you want → captured).

## 3. App-specific Profiles
Save different settings (post-processing mode, injection mode, custom prompt) per application. Detects frontmost app via `NSWorkspace.shared.frontmostApplication`. For example: "In Slack: casual tone, no punctuation. In Xcode: preserve code identifiers. In Mail: formal tone."

## 4. History / Session Log
Keep a local log of transcriptions (timestamp, text, app). Accessible from the menu bar as a dropdown showing the last 10–20 entries. One-click to re-inject any past entry. Persisted to disk, clearable.

## 5. Silence Detection / Auto-Stop
Automatically stop recording after N seconds of silence (configurable). Useful in toggle mode so you don't accidentally leave recording running.

## 6. Multiple Languages / Locale
Pass a language hint to the Gemini Live API so transcription is optimized for the user's language. Could be a simple dropdown in Settings.

## 7. Keyboard Shortcut to Re-inject Last Transcript
A second hotkey (e.g., Right Option + ⌘V) that re-injects the most recently transcribed text without recording again. Handy when injection fails or focus was in the wrong window.

## 8. Dictation Commands
Recognize spoken phrases like "new paragraph", "period", "delete that", "select all", "undo" and map them to keyboard actions mid-dictation.

## 9. Templates / Snippets
Define voice-triggered snippets. Say "insert signature" → injects your email signature. Say "date today" → injects the current date. Stored in settings with trigger phrase + output text.

## 10. Output Formatting Modes
Beyond cleanup/summarize: "bullet points", "email reply", "Slack message", "code comment". Quick-switch from the menu bar or a floating picker.

## 11. Local Whisper Fallback
When offline or Gemini is down, fall back to on-device transcription via whisper.cpp (runs on Apple Silicon). Could use the Core ML Whisper models Apple ships.

## 12. Audio Buffering During Connect
Capture audio immediately on hotkey press while the WebSocket is still connecting. Replay buffered audio once connected so the first word(s) are never lost.

## 13. Usage Stats
Words dictated today/week/month, time saved estimate, most-used apps. A small "Today" widget in the menu popover.

## 14. iCloud / Keychain Sync
Store the Gemini API key in the system Keychain (more secure than UserDefaults) and optionally sync API key, post-processing settings, and snippets across Macs via `NSUbiquitousKeyValueStore`.
