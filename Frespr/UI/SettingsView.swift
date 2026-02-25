import SwiftUI

struct SettingsView: View {
    @State private var permissionManager = PermissionManager.shared
    @State private var micStatus: Bool = false
    @State private var axStatus: Bool = false

    // Local state for the API key field — avoids @Observable binding issues
    // that break paste. Syncs to AppSettings on change.
    @State private var apiKey: String = AppSettings.shared.geminiAPIKey
    @State private var apiKeyVisible = false
    @State private var silenceEnabled: Bool = AppSettings.shared.silenceDetectionEnabled
    @State private var silenceTimeout: Int = AppSettings.shared.silenceTimeoutSeconds

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

            // Silence Detection
            Section {
                Toggle("Auto-stop after silence", isOn: $silenceEnabled)
                    .onChange(of: silenceEnabled) { _, new in
                        AppSettings.shared.silenceDetectionEnabled = new
                    }

                HStack {
                    Text("Stop after")
                    Stepper(value: $silenceTimeout, in: 5...60) {
                        Text("\(silenceTimeout) seconds")
                    }
                    .onChange(of: silenceTimeout) { _, new in
                        AppSettings.shared.silenceTimeoutSeconds = new
                    }
                    .disabled(!silenceEnabled)
                }
            } header: {
                Text("Silence Detection")
            } footer: {
                Text("Automatically stop recording when no speech is detected.")
                    .foregroundStyle(.secondary)
            }

            // Output
            Section {
                Toggle("Copy transcript to clipboard", isOn: Binding(
                    get: { AppSettings.shared.copyToClipboard },
                    set: { AppSettings.shared.copyToClipboard = $0 }
                ))
            } footer: {
                Text("After transcribing, the result is also copied to your clipboard.")
                    .foregroundStyle(.secondary)
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
        .frame(width: 420, height: 640)
        .task {
            await refreshPermissions()
        }
    }

    private func refreshPermissions() async {
        micStatus = permissionManager.microphoneAuthorized
        axStatus = permissionManager.accessibilityAuthorized
    }
}

// MARK: - Permission Row

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
