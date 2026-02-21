# Frespr Project Context

## Project Overview

Frespr is a native macOS menu bar application designed for voice-to-text transcription leveraging the Gemini Live API. The application listens for a specific global hotkey (Right Option ⌥), records audio while the key is held down, streams it to the Gemini Live API for processing, and then automatically injects the transcribed text into the currently focused application.

**Main Technologies:**
- Swift 6
- macOS Native APIs (`AVAudioEngine`, `CGEventTap`, `NSStatusItem`, `AXUIElement`, SwiftUI, AppKit)
- Gemini Live WebSocket API (`models/gemini-live-2.5-flash-native-audio`)

## Architecture

The project is structured into distinct, focused modules:

*   **App (`Frespr/App/`):** Contains the entry point (`main.swift`) and `AppDelegate.swift`, which wires up all the subsystems and manages the lifecycle of the settings window.
*   **Audio (`Frespr/Audio/`):** `AudioCaptureEngine.swift` manages the `AVAudioEngine` to capture 16kHz Int16 PCM audio chunks.
*   **Coordinator (`Frespr/Coordinator/`):** `GeminiSessionCoordinator.swift` acts as the state machine managing transitions between idle, connecting, recording, and processing states.
*   **Gemini (`Frespr/Gemini/`):** Handles the WebSocket connection (`GeminiLiveService.swift`) and defines the Codable message types for the Gemini protocol (`GeminiProtocol.swift`).
*   **HotKey (`Frespr/HotKey/`):** `GlobalHotKeyMonitor.swift` uses `CGEventTap` to detect the Right Option keypress globally.
*   **TextInjection (`Frespr/TextInjection/`):** `TextInjector.swift` handles inserting the transcribed text into the active app, primarily using Accessibility APIs (`AXUIElement`) with a fallback to the clipboard (Pasteboard + Cmd+V).
*   **UI (`Frespr/UI/`):** Contains SwiftUI views and AppKit window controllers for the overlay (mic indicator/live transcript) and the settings window.
*   **Storage & Permissions (`Frespr/Storage/`, `Frespr/Permissions/`):** Manages user settings (API key, hotkey modes) and necessary system permissions (Microphone, Accessibility).

## Building and Running

The project intentionally avoids using Xcode project files (`.xcodeproj` is present but the primary build mechanism is script-based) and is built entirely from the command line using `swiftc` and `pkgbuild`.

**Build Script (`build.sh`):**

The `build.sh` script is the primary tool for compiling and running the app.

*   **Run Locally (Default):** Compiles, signs, and launches the `.app` bundle directly. It also kills any running instances and clears the debug log.
    ```bash
    ./build.sh
    # or
    ./build.sh run
    ```
    *(Logs can be viewed via `tail -f /tmp/frespr_debug.log`)*

*   **Build Package:** Compiles, signs, and packages the app into a `.pkg` installer for distribution.
    ```bash
    ./build.sh pkg
    ```
    *To install the package: `open Frespr.pkg`*

## Development Conventions

*   **No Xcode Required:** The app is built with `swiftc` from the Command Line Tools.
*   **Concurrency:** Extensive use of Swift 6 concurrency features. `AppDelegate` and `GeminiSessionCoordinator` are marked with `@MainActor`.
*   **Type-checking:** You can type-check the project from the CLI without building:
    ```bash
    swiftc -typecheck -target arm64-apple-macosx14.0 -sdk $(xcrun --show-sdk-path --sdk macosx) Frespr/**/*.swift Frespr/App/*.swift
    ```
*   **App Focus (`LSUIElement`):** The app runs as an accessory (no Dock icon). The Settings window temporarily switches the app activation policy to `.regular` to receive keyboard input, and reverts to `.accessory` when closed.
*   **SwiftUI Previews:** Do not use the `#Preview` macro, as it requires Xcode plugins and will fail CLI type-checking.
*   **Workflow:** Always verify changes by running `./build.sh` to ensure the app compiles and launches correctly.
*   **Gotchas:**
    *   `CGEventTap` (Global Hotkey) silently fails if Accessibility permissions are not granted.
    *   Right Option keycode is 61.
    *   `GeminiLiveError.localizedDescription` returns a `String`, not an optional `String?`.
