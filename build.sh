#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/Frespr"
BUILD="$SCRIPT_DIR/build"
APP="$BUILD/Frespr.app"
PKG="$SCRIPT_DIR/Frespr.pkg"
SDK="$(xcrun --show-sdk-path --sdk macosx)"
TARGET="arm64-apple-macosx14.0"
VERSION="$(cat "$SCRIPT_DIR/VERSION" | tr -d '[:space:]')"

# Usage: ./build.sh [run|pkg]
#   run  — compile, build .app, sign, kill any running instance, launch (default)
#   pkg  — compile, build .app, sign, package as .pkg for distribution
MODE="${1:-run}"

compile() {
  echo "==> Compiling Frespr"
  swiftc \
    -target "$TARGET" \
    -sdk "$SDK" \
    -O \
    -module-name Frespr \
    "$SRC/App/Debug.swift" \
    "$SRC/Storage/AppSettings.swift" \
    "$SRC/Storage/TranscriptionLog.swift" \
    "$SRC/Permissions/PermissionManager.swift" \
    "$SRC/Gemini/GeminiProtocol.swift" \
    "$SRC/Gemini/GeminiLiveService.swift" \
    "$SRC/Gemini/GeminiPostProcessor.swift" \
    "$SRC/Coordinator/TranscriptionBackend.swift" \
    "$SRC/Deepgram/DeepgramService.swift" \
    "$SRC/Audio/AudioCaptureEngine.swift" \
    "$SRC/Audio/AudioFeedback.swift" \
    "$SRC/TextInjection/TextInjector.swift" \
    "$SRC/HotKey/HotKeyOption.swift" \
    "$SRC/HotKey/GlobalHotKeyMonitor.swift" \
    "$SRC/Updater/UpdateChecker.swift" \
    "$SRC/MenuBar/MenuBarController.swift" \
    "$SRC/UI/OverlayView.swift" \
    "$SRC/UI/OverlayWindow.swift" \
    "$SRC/UI/SettingsView.swift" \
    "$SRC/UI/SettingsWindowController.swift" \
    "$SRC/Coordinator/TranscriptionCoordinator.swift" \
    "$SRC/App/AppDelegate.swift" \
    "$SRC/App/main.swift" \
    -o "$BUILD/Frespr"
}

bundle() {
  echo "==> Building .app bundle"
  mkdir -p "$APP/Contents/MacOS"
  mkdir -p "$APP/Contents/Resources"
  cp "$BUILD/Frespr"   "$APP/Contents/MacOS/Frespr"
  cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
  sed -i '' "s/FRESPR_VERSION/$VERSION/g" "$APP/Contents/Info.plist"
  cp "$SRC/Frespr.entitlements" "$APP/Contents/Resources/" 2>/dev/null || true
  # App icon + menu bar icons
  cp "$SRC/Assets/Frespr.icns"              "$APP/Contents/Resources/Frespr.icns"
  cp "$SRC/Assets/menubar.png"              "$APP/Contents/Resources/menubar.png"
  cp "$SRC/Assets/menubar@2x.png"           "$APP/Contents/Resources/menubar@2x.png"
  cp "$SRC/Assets/menubar-recording.png"    "$APP/Contents/Resources/menubar-recording.png"
  cp "$SRC/Assets/menubar-recording@2x.png" "$APP/Contents/Resources/menubar-recording@2x.png"
  cp "$SRC/Assets/menubar-processing.png"   "$APP/Contents/Resources/menubar-processing.png"
  cp "$SRC/Assets/menubar-processing@2x.png" "$APP/Contents/Resources/menubar-processing@2x.png"

  echo "==> Ad-hoc signing"
  codesign --force --deep --sign - "$APP"
  codesign --verify --deep --strict "$APP" && echo "    OK"
}

# ── run mode ──────────────────────────────────────────────────────────────────
if [ "$MODE" = "run" ]; then
  rm -rf "$BUILD"
  mkdir -p "$BUILD"
  compile
  bundle

  # Kill any existing instance
  pkill -x Frespr 2>/dev/null || true
  sleep 0.3

  # NOTE: tccutil reset Accessibility intentionally removed from dev builds.
  # It triggered a keychain password prompt on every build. Ad-hoc re-signing
  # does technically invalidate the TCC grant, but macOS re-prompts automatically
  # if the hotkey stops working — no need to force-reset every build.

  # Clear the debug log so next tail -f starts fresh
  > /tmp/frespr_debug.log

  echo ""
  echo "✓ Launching $APP"
  echo "  (logs → tail -f /tmp/frespr_debug.log)"
  open "$APP"
  exit 0
fi

# ── pkg mode ──────────────────────────────────────────────────────────────────
if [ "$MODE" = "pkg" ]; then
  rm -rf "$BUILD"
  mkdir -p "$BUILD"
  compile
  bundle

  echo "==> Packaging"
  PAYLOAD="$BUILD/payload"
  mkdir -p "$PAYLOAD"
  ditto "$APP" "$PAYLOAD/Frespr.app"

  SCRIPTS="$BUILD/scripts"
  mkdir -p "$SCRIPTS"
  cat > "$SCRIPTS/postinstall" << 'POSTINSTALL'
#!/bin/bash
CURRENT_USER=$(stat -f '%Su' /dev/console)
chown -R "$CURRENT_USER:staff" /Applications/Frespr.app
xattr -dr com.apple.quarantine /Applications/Frespr.app 2>/dev/null || true
exit 0
POSTINSTALL
  chmod +x "$SCRIPTS/postinstall"

  # Generate component plist and pin the install location so pkgbuild doesn't
  # mark the bundle as relocatable. Without this, a fresh install (no existing
  # /Applications/Frespr.app to "upgrade") silently skips placing the files.
  COMPONENT_PLIST="$BUILD/components.plist"
  pkgbuild --analyze --root "$PAYLOAD" "$COMPONENT_PLIST"
  /usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$COMPONENT_PLIST"

  pkgbuild \
    --root "$PAYLOAD" \
    --component-plist "$COMPONENT_PLIST" \
    --scripts "$SCRIPTS" \
    --install-location /Applications \
    --identifier com.frespr.app \
    --version "$VERSION" \
    "$PKG"

  echo ""
  echo "✓ Built: $PKG"
  echo "  open '$PKG'"
  exit 0
fi

echo "Usage: $0 [run|pkg]"
exit 1
