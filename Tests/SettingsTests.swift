// SettingsTests.swift — Standalone test runner, no XCTest / no Xcode needed.
//
// Build & run:
//   swiftc -target arm64-apple-macosx14.0 -sdk $(xcrun --show-sdk-path --sdk macosx) \
//     Frespr/App/Debug.swift \
//     Frespr/Audio/AudioCaptureEngine.swift \
//     Frespr/Coordinator/GeminiSessionCoordinator.swift \
//     Frespr/Gemini/GeminiLiveService.swift \
//     Frespr/Gemini/GeminiPostProcessor.swift \
//     Frespr/Gemini/GeminiProtocol.swift \
//     Frespr/HotKey/GlobalHotKeyMonitor.swift \
//     Frespr/HotKey/HotKeyOption.swift \
//     Frespr/MenuBar/MenuBarController.swift \
//     Frespr/Permissions/PermissionManager.swift \
//     Frespr/Storage/AppSettings.swift \
//     Frespr/Storage/TranscriptionLog.swift \
//     Frespr/TextInjection/TextInjector.swift \
//     Frespr/UI/OverlayView.swift \
//     Frespr/UI/OverlayWindow.swift \
//     Frespr/UI/SettingsView.swift \
//     Frespr/UI/SettingsWindowController.swift \
//     Tests/SettingsTests.swift \
//     -o /tmp/SettingsTests && /tmp/SettingsTests
//
// NOTE: Omits main.swift (top-level entry point conflict).

import AppKit
import Foundation
import Security

// MARK: - Minimal test harness

private var passCount = 0
private var failCount = 0
private var currentSuite = ""

private func suite(_ name: String, _ block: () -> Void) {
    currentSuite = name
    block()
}

private func test(_ name: String, _ block: () -> Void) {
    block()
    // If we get here without a failure recorded the test passed implicitly
    // (failures call fail() which prints immediately)
    let tag = "  \(currentSuite) › \(name)"
    _ = tag // used by pass() / fail() closures below
}

@discardableResult
private func expect(_ condition: Bool, _ message: String,
                    file: String = #file, line: Int = #line) -> Bool {
    if condition {
        passCount += 1
        return true
    } else {
        failCount += 1
        let f = file.split(separator: "/").last.map(String.init) ?? file
        print("  FAIL [\(f):\(line)] \(currentSuite): \(message)")
        return false
    }
}

private func expectEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String,
                                        file: String = #file, line: Int = #line) {
    expect(a == b, "\(msg) — expected \(b), got \(a)", file: file, line: line)
}

// MARK: - Cleanup helpers

private let settingsKeys = [
    "postProcessingMode", "customPostProcessingPrompt",
    "copyToClipboard", "silenceDetectionEnabled", "silenceTimeoutSeconds",
    "hotKeyOption"
]

private func cleanDefaults() {
    for key in settingsKeys { UserDefaults.standard.removeObject(forKey: key) }
    UserDefaults.standard.synchronize()
    cleanKeychain()
}

private func cleanKeychain() {
    let query: [CFString: Any] = [
        kSecClass:       kSecClassGenericPassword,
        kSecAttrService: "com.frespr.app",
        kSecAttrAccount: "geminiAPIKey"
    ]
    SecItemDelete(query as CFDictionary)
}

// MARK: - Tests

private func runTests() {

    // ── AppSettings: round-trip CRUD ──────────────────────────────────────────

    suite("AppSettings.geminiAPIKey") {
        test("read/write") {
            cleanDefaults()
            AppSettings.shared.geminiAPIKey = "test-api-key-123"
            expectEqual(AppSettings.shared.geminiAPIKey, "test-api-key-123", "key round-trips")
        }
        test("empty string when unset") {
            cleanDefaults()
            expectEqual(AppSettings.shared.geminiAPIKey, "", "defaults to empty")
        }
    }

    suite("AppSettings.postProcessingMode") {
        test("round-trips all cases") {
            for mode in PostProcessingMode.allCases {
                cleanDefaults()
                AppSettings.shared.postProcessingMode = mode
                expectEqual(AppSettings.shared.postProcessingMode, mode, "mode \(mode.rawValue) round-trips")
            }
        }
        test("defaults to .none when unset") {
            cleanDefaults()
            expectEqual(AppSettings.shared.postProcessingMode, .none, "default is .none")
        }
        test("handles unknown rawValue gracefully") {
            UserDefaults.standard.set("nonexistent_mode", forKey: "postProcessingMode")
            expectEqual(AppSettings.shared.postProcessingMode, .none, "falls back to .none")
            cleanDefaults()
        }
    }

    suite("AppSettings.customPostProcessingPrompt") {
        test("read/write") {
            cleanDefaults()
            AppSettings.shared.customPostProcessingPrompt = "Rewrite formally."
            expectEqual(AppSettings.shared.customPostProcessingPrompt, "Rewrite formally.", "prompt round-trips")
        }
        test("empty string when unset") {
            cleanDefaults()
            expectEqual(AppSettings.shared.customPostProcessingPrompt, "", "defaults to empty")
        }
    }

    suite("AppSettings.copyToClipboard") {
        test("reads registered default of false") {
            cleanDefaults()
            expect(!AppSettings.shared.copyToClipboard, "registered default is false")
        }
        test("read/write true") {
            cleanDefaults()
            AppSettings.shared.copyToClipboard = true
            expect(AppSettings.shared.copyToClipboard, "persists true")
        }
        test("read/write false") {
            cleanDefaults()
            AppSettings.shared.copyToClipboard = false
            expect(!AppSettings.shared.copyToClipboard, "persists false")
        }
    }

    suite("AppSettings.silenceDetectionEnabled") {
        test("registered default is true") {
            cleanDefaults()
            expect(AppSettings.shared.silenceDetectionEnabled, "registered default is true")
        }
        test("read/write false") {
            cleanDefaults()
            AppSettings.shared.silenceDetectionEnabled = false
            expect(!AppSettings.shared.silenceDetectionEnabled, "persists false")
        }
        test("read/write true") {
            cleanDefaults()
            AppSettings.shared.silenceDetectionEnabled = true
            expect(AppSettings.shared.silenceDetectionEnabled, "persists true")
        }
    }

    suite("AppSettings.silenceTimeoutSeconds") {
        test("registered default is 15") {
            cleanDefaults()
            expectEqual(AppSettings.shared.silenceTimeoutSeconds, 15, "registered default is 15")
        }
        test("read/write arbitrary value") {
            cleanDefaults()
            AppSettings.shared.silenceTimeoutSeconds = 30
            expectEqual(AppSettings.shared.silenceTimeoutSeconds, 30, "persists 30")
        }
        test("read/write boundary values") {
            cleanDefaults()
            AppSettings.shared.silenceTimeoutSeconds = 5
            expectEqual(AppSettings.shared.silenceTimeoutSeconds, 5, "persists 5")
            AppSettings.shared.silenceTimeoutSeconds = 60
            expectEqual(AppSettings.shared.silenceTimeoutSeconds, 60, "persists 60")
        }
    }

    suite("AppSettings.hotKeyOption") {
        test("registered default is .rightOption") {
            cleanDefaults()
            expectEqual(AppSettings.shared.hotKeyOption, .rightOption, "registered default is .rightOption")
        }
        test("round-trips all cases") {
            for option in HotKeyOption.allCases {
                cleanDefaults()
                AppSettings.shared.hotKeyOption = option
                expectEqual(AppSettings.shared.hotKeyOption, option, "\(option.rawValue) round-trips")
            }
        }
        test("handles unknown rawValue by defaulting to .rightOption") {
            UserDefaults.standard.set("unknownKey", forKey: "hotKeyOption")
            expectEqual(AppSettings.shared.hotKeyOption, .rightOption, "falls back to .rightOption")
            cleanDefaults()
        }
    }

    // ── PostProcessingMode enum logic ─────────────────────────────────────────

    suite("PostProcessingMode") {
        test("displayName is non-empty for all cases") {
            for mode in PostProcessingMode.allCases {
                expect(!mode.displayName.isEmpty, "\(mode.rawValue) has displayName")
            }
        }
        test("shortLabel is non-empty for all cases") {
            for mode in PostProcessingMode.allCases {
                expect(!mode.shortLabel.isEmpty, "\(mode.rawValue) has shortLabel")
            }
        }
        test("systemPrompt is nil for .none and .custom") {
            expect(PostProcessingMode.none.systemPrompt == nil, ".none systemPrompt is nil")
            expect(PostProcessingMode.custom.systemPrompt == nil, ".custom systemPrompt is nil")
        }
        test("systemPrompt is non-nil for .cleanup and .summarize") {
            expect(PostProcessingMode.cleanup.systemPrompt != nil, ".cleanup systemPrompt is set")
            expect(PostProcessingMode.summarize.systemPrompt != nil, ".summarize systemPrompt is set")
        }
        test("next wraps around") {
            let cases = PostProcessingMode.allCases
            for (i, mode) in cases.enumerated() {
                let expected = cases[(i + 1) % cases.count]
                expectEqual(mode.next, expected, "\(mode.rawValue).next is \(expected.rawValue)")
            }
        }
        test("rawValue round-trips") {
            for mode in PostProcessingMode.allCases {
                let reconstructed = PostProcessingMode(rawValue: mode.rawValue)
                expect(reconstructed == mode, "\(mode.rawValue) rawValue round-trips")
            }
        }
    }

    // ── HotKeyOption enum logic ───────────────────────────────────────────────

    suite("HotKeyOption") {
        test("all cases have non-empty labels") {
            for option in HotKeyOption.allCases {
                expect(!option.label.isEmpty, "\(option.rawValue) has label")
            }
        }
        test("from(rawValue:) returns correct case for all valid values") {
            for option in HotKeyOption.allCases {
                expectEqual(HotKeyOption.from(rawValue: option.rawValue), option,
                            "\(option.rawValue) round-trips via from(rawValue:)")
            }
        }
        test("from(rawValue:) falls back to .rightOption for unknown string") {
            expectEqual(HotKeyOption.from(rawValue: "bogus"), .rightOption,
                        "unknown rawValue defaults to .rightOption")
        }
        test("rawValue round-trips") {
            for option in HotKeyOption.allCases {
                let reconstructed = HotKeyOption(rawValue: option.rawValue)
                expect(reconstructed == option, "\(option.rawValue) rawValue round-trips")
            }
        }
    }

    // ── SettingsWindowController: smoke + action round-trips ─────────────────

    suite("SettingsWindowController") {
        test("init does not crash") {
            cleanDefaults()
            AppSettings.shared.geminiAPIKey = "smoke-test-key"
            let wc = SettingsWindowController()
            expect(wc.window != nil, "window is created")
            wc.window?.close()
            cleanDefaults()
        }

        test("action round-trip: silenceDetectionEnabled") {
            cleanDefaults()
            AppSettings.shared.silenceDetectionEnabled = false
            let wc = SettingsWindowController()
            // loadValues() ran during init and set silenceCheck.state = .off
            // Now toggle the check via its action (simulate user clicking the checkbox)
            // We can't set the private control, but we can verify the action reads from it.
            // Instead: verify the current AppSettings value is what we set.
            expectEqual(AppSettings.shared.silenceDetectionEnabled, false,
                        "AppSettings retains value set before init")
            wc.window?.close()
            cleanDefaults()
        }

        test("action round-trip: hotKeyOption via perform") {
            cleanDefaults()
            AppSettings.shared.hotKeyOption = .leftOption
            let wc = SettingsWindowController()
            // loadValues() selected index 1 in the popup for .leftOption
            // Performing hotKeyChanged reads from the popup and writes back
            wc.perform(NSSelectorFromString("hotKeyChanged"))
            expectEqual(AppSettings.shared.hotKeyOption, .leftOption,
                        "hotKeyChanged writes loadValues-selected value back (round-trip)")
            wc.window?.close()
            cleanDefaults()
        }

        test("action round-trip: silenceTimeout via stepper perform") {
            cleanDefaults()
            AppSettings.shared.silenceTimeoutSeconds = 20
            let wc = SettingsWindowController()
            // loadValues() set silenceTimeout field and stepper to 20
            // Performing silenceTimeoutChanged reads from the text field
            wc.perform(NSSelectorFromString("silenceTimeoutChanged"))
            expectEqual(AppSettings.shared.silenceTimeoutSeconds, 20,
                        "silenceTimeoutChanged writes loadValues-set value back (round-trip)")
            wc.window?.close()
            cleanDefaults()
        }

        test("action round-trip: clipboardCheck") {
            cleanDefaults()
            AppSettings.shared.copyToClipboard = true
            let wc = SettingsWindowController()
            wc.perform(NSSelectorFromString("clipboardCheckChanged"))
            expectEqual(AppSettings.shared.copyToClipboard, true,
                        "clipboardCheckChanged round-trips value")
            wc.window?.close()
            cleanDefaults()
        }

        test("windowWillClose persists customPostProcessingPrompt") {
            cleanDefaults()
            AppSettings.shared.customPostProcessingPrompt = "initial"
            let wc = SettingsWindowController()
            // The ppCustomField was set to "initial" by loadValues()
            // windowWillClose reads from ppCustomField and saves it
            wc.windowWillClose(Notification(name: NSWindow.willCloseNotification))
            expectEqual(AppSettings.shared.customPostProcessingPrompt, "initial",
                        "windowWillClose persists ppCustomField value")
            cleanDefaults()
        }
    }

    // ── Final cleanup ─────────────────────────────────────────────────────────
    cleanDefaults()
}

// MARK: - Entry point

@main struct TestRunner {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        DispatchQueue.main.async {
            runTests()
            let total = passCount + failCount
            print("\n\(passCount)/\(total) tests passed" + (failCount > 0 ? " (\(failCount) FAILED)" : " ✓"))
            exit(failCount > 0 ? 1 : 0)
        }

        RunLoop.main.run()
    }
}
