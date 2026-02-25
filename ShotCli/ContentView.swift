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

struct ContentView: View {
    @State private var screenRecording: PermissionState = .missing
    @State private var accessibility: PermissionState = .missing

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ShotCli Permission Guide")
                .font(.title2.weight(.semibold))

            Text("This app does not provide screenshot UI. Use CLI commands after permissions are granted.")
                .foregroundStyle(.secondary)

            PermissionCard(
                title: "Screen Recording",
                detail: "Required for `shot capture`, `shot displays`, and `shot windows`.",
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
                Text("If ShotCli does not appear in Accessibility list, move ShotCli.app to /Applications and click Request Permission again.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Refresh Status", action: refreshPermissions)
                Spacer()
                Text("CLI-first. GUI is permission onboarding only.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 420)
        .onAppear(perform: refreshPermissions)
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
