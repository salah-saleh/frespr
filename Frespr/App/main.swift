import AppKit

// Entry point — pure AppDelegate lifecycle, no @main SwiftUI App
// main.swift runs on MainActor implicitly as the program entry point
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
