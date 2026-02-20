import SwiftUI

struct SettingsView: View {
    @State private var permissionManager = PermissionManager.shared
    @State private var micStatus: Bool = false
    @State private var axStatus: Bool = false

    // Local state for the API key field — avoids @Observable binding issues
    // that break paste. Syncs to AppSettings on change.
    @State private var apiKey: String = AppSettings.shared.geminiAPIKey
    @State private var apiKeyVisible = false

    @State private var hotkeyMode: HotkeyMode = AppSettings.shared.hotkeyMode
    @State private var showOverlay: Bool = AppSettings.shared.showOverlay

    var body: some View {
        Form {
            // API Key
            Section {
                HStack {
                    TextField("Paste your API key here", text: $apiKey)
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .opacity(apiKeyVisible || apiKey.isEmpty ? 1 : 0.3)
                        .onChange(of: apiKey) { _, new in
                            AppSettings.shared.geminiAPIKey = new
                        }

                    if !apiKey.isEmpty {
                        Button {
                            apiKeyVisible.toggle()
                        } label: {
                            Image(systemName: apiKeyVisible ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Link("Get a free key at Google AI Studio →",
                     destination: URL(string: "https://aistudio.google.com/app/apikey")!)
                    .font(.caption)
            } header: {
                Text("Gemini API Key")
            } footer: {
                if apiKey.isEmpty {
                    Text("Required to use Frespr.")
                        .foregroundStyle(.red)
                }
            }

            // Hotkey Mode
            Section {
                Picker("Mode", selection: $hotkeyMode) {
                    ForEach(HotkeyMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: hotkeyMode) { _, new in
                    AppSettings.shared.hotkeyMode = new
                }

                Text("Hotkey: Right Option (⌥)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Hotkey")
            }

            // Overlay
            Section {
                Toggle("Show overlay while recording", isOn: $showOverlay)
                    .onChange(of: showOverlay) { _, new in
                        AppSettings.shared.showOverlay = new
                    }
            } header: {
                Text("Overlay")
            }

            // Permissions
            Section {
                PermissionRow(
                    label: "Microphone",
                    granted: micStatus,
                    onGrant: {
                        Task {
                            _ = await permissionManager.requestMicrophoneAccess()
                            await refreshPermissions()
                        }
                    }
                )
                PermissionRow(
                    label: "Accessibility (text injection)",
                    granted: axStatus,
                    onGrant: {
                        permissionManager.requestAccessibilityAccess()
                        Task { await refreshPermissions() }
                    }
                )
            } header: {
                Text("Permissions")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 420)
        .task {
            await refreshPermissions()
        }
    }

    private func refreshPermissions() async {
        micStatus = permissionManager.microphoneAuthorized
        axStatus = permissionManager.accessibilityAuthorized
    }
}

private struct PermissionRow: View {
    let label: String
    let granted: Bool
    let onGrant: () -> Void

    var body: some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(label)
            Spacer()
            if !granted {
                Button("Grant", action: onGrant)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }
}
