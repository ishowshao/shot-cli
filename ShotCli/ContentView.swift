import AppKit
import ApplicationServices
import SwiftUI

private enum PermissionState {
    case granted
    case missing

    var label: String {
        switch self {
        case .granted:
            return "Granted"
        case .missing:
            return "Missing"
        }
    }

    var color: Color {
        switch self {
        case .granted:
            return .green
        case .missing:
            return .orange
        }
    }
}

private struct PermissionCard: View {
    let title: String
    let detail: String
    let state: PermissionState
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Label(state.label, systemImage: state == .granted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(state.color)
                    .font(.subheadline)
            }

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Request Permission", action: onRequest)
                Button("Open System Settings", action: onOpenSettings)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct CLICommandCard: View {
    @ObservedObject var installer: ShotCommandInstallerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CLI Command (`shot`)")
                    .font(.headline)
                Spacer()
                Label(installer.statusTitle, systemImage: installer.statusSymbol)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(installer.statusColor)
                    .font(.subheadline)
            }

            Text("Install a shell command so you can run `shot` directly in Terminal.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button("Install to ~/.local/bin", action: installer.installToUserLocal)
                    .disabled(installer.isWorking)
                Button("Install to /usr/local/bin", action: installer.installToUsrLocal)
                    .disabled(installer.isWorking)
                    .help("Requires administrator authentication.")
                Button("Uninstall", action: installer.uninstallManagedLinks)
                    .disabled(installer.isWorking)
                Button("Refresh", action: installer.refresh)
                    .disabled(installer.isWorking)
            }

            if installer.isWorking {
                ProgressView()
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("~/.local/bin/shot: \(installer.userLocalStatus)")
                Text("/usr/local/bin/shot: \(installer.usrLocalStatus)")
                Text("Shell lookup: \(installer.shellLookupStatus)")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            if !installer.guidance.isEmpty {
                Text(installer.guidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !installer.feedback.isEmpty {
                Text(installer.feedback)
                    .font(.footnote)
                    .foregroundStyle(installer.feedbackColor)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct ContentView: View {
    @State private var screenRecording: PermissionState = .missing
    @State private var accessibility: PermissionState = .missing
    @StateObject private var commandInstaller = ShotCommandInstallerModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ShotCli Permission Guide")
                .font(.title2.weight(.semibold))

            Text("This app does not provide screenshot UI. Use CLI commands after permissions are granted.")
                .foregroundStyle(.secondary)

            CLICommandCard(installer: commandInstaller)

            PermissionCard(
                title: "Screen Recording",
                detail: "Required for `shot capture` and `shot windows`. You can request it here, then enable it in System Settings.",
                state: screenRecording,
                onRequest: requestScreenRecordingPermission,
                onOpenSettings: { openPrivacySettings(anchor: "Privacy_ScreenCapture") }
            )

            PermissionCard(
                title: "Accessibility",
                detail: "Optional. Helps with frontmost app/window related behaviors.",
                state: accessibility,
                onRequest: requestAccessibilityPermission,
                onOpenSettings: { openPrivacySettings(anchor: "Privacy_Accessibility") }
            )

            VStack(alignment: .leading, spacing: 6) {
                Text("Quick Check")
                    .font(.headline)
                Text("Run `shot doctor --pretty` in terminal for script-friendly health checks.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("For CLI workflows, grant Screen Recording to your terminal host app (Terminal/iTerm) in System Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("If ShotCli does not appear in Accessibility list, move ShotCli.app to /Applications and click Request Permission again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Refresh Status") {
                    refreshPermissions()
                    commandInstaller.refresh()
                }
                Spacer()
                Text("CLI-first. GUI handles command install and permission onboarding.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 760, minHeight: 640)
        .onAppear {
            refreshPermissions()
            commandInstaller.refresh()
        }
    }

    private func refreshPermissions() {
        screenRecording = CGPreflightScreenCaptureAccess() ? .granted : .missing
        accessibility = AXIsProcessTrusted() ? .granted : .missing
    }

    private func requestScreenRecordingPermission() {
        _ = CGRequestScreenCaptureAccess()
        refreshPermissions()
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        // macOS may not re-show the prompt after the first denial; always guide users to settings.
        openPrivacySettings(anchor: "Privacy_Accessibility")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            refreshPermissions()
        }
    }

    private func openPrivacySettings(anchor: String) {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(anchor)",
            "x-apple.systempreferences:com.apple.preference.security",
            "x-apple.systempreferences:"
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}

#Preview {
    ContentView()
}
