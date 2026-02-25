import Foundation
import Combine
import SwiftUI

private enum ShotCommandInstallLocation: CaseIterable {
    case userLocal
    case usrLocal

    var label: String {
        switch self {
        case .userLocal:
            return "~/.local/bin/shot"
        case .usrLocal:
            return "/usr/local/bin/shot"
        }
    }

    var linkPath: String {
        switch self {
        case .userLocal:
            return (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin/shot")
        case .usrLocal:
            return "/usr/local/bin/shot"
        }
    }

    var directoryPath: String {
        (linkPath as NSString).deletingLastPathComponent
    }
}

private enum ShotCommandLinkState {
    case missing
    case installed
    case pointsToOther(String)
    case occupiedByFile
    case brokenSymlink(String)
    case inaccessible(String)

    var description: String {
        switch self {
        case .missing:
            return "Not installed"
        case .installed:
            return "Installed"
        case .pointsToOther(let path):
            return "Points to another target: \(path)"
        case .occupiedByFile:
            return "Occupied by a regular file"
        case .brokenSymlink(let path):
            return "Broken symlink -> \(path)"
        case .inaccessible(let reason):
            return "Check failed: \(reason)"
        }
    }
}

private struct ShotCommandInspection {
    let targetPath: String
    let shellCommandPath: String?
    let shellCommandResolvesToTarget: Bool
    let states: [ShotCommandInstallLocation: ShotCommandLinkState]
}

private enum ShotCommandInstallError: Error {
    case targetMissing
    case cannotCreateDirectory(String)
    case linkPathOccupiedByFile(String)
    case insufficientPermissions(String)
    case authorizationCancelled
    case ioFailure(String)

    var message: String {
        switch self {
        case .targetMissing:
            return "Cannot locate executable in app bundle (Contents/MacOS/shot)."
        case .cannotCreateDirectory(let path):
            return "Cannot create directory: \(path)"
        case .linkPathOccupiedByFile(let path):
            return "\(path) already exists as a regular file. Remove it manually first."
        case .insufficientPermissions(let path):
            return "Insufficient permission to modify \(path)."
        case .authorizationCancelled:
            return "Administrator authentication was cancelled."
        case .ioFailure(let reason):
            return reason
        }
    }
}

final class ShotCommandInstallerModel: ObservableObject {
    @Published private(set) var statusTitle = "Checking..."
    @Published private(set) var statusSymbol = "hourglass"
    @Published private(set) var statusColor: Color = .secondary

    @Published private(set) var userLocalStatus = "Checking..."
    @Published private(set) var usrLocalStatus = "Checking..."
    @Published private(set) var shellLookupStatus = "Checking..."

    @Published private(set) var guidance = ""
    @Published private(set) var feedback = ""
    @Published private(set) var feedbackColor: Color = .secondary

    @Published private(set) var isWorking = false

    func refresh() {
        runBackgroundTask { inspection in
            self.applyInspection(inspection)
            self.feedback = ""
        } onError: { error in
            self.statusTitle = "CLI Install Check Failed"
            self.statusSymbol = "xmark.octagon.fill"
            self.statusColor = .red
            self.guidance = error.message
            self.feedback = ""
            self.userLocalStatus = "Unknown"
            self.usrLocalStatus = "Unknown"
            self.shellLookupStatus = "Unknown"
        }
    }

    func installToUserLocal() {
        performInstall(to: .userLocal)
    }

    func installToUsrLocal() {
        performInstall(to: .usrLocal)
    }

    func uninstallManagedLinks() {
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let targetPath = (try? Self.resolveTargetPath()) ?? ""
            var removedAny = false
            var blocked: String?

            for location in ShotCommandInstallLocation.allCases {
                let linkPath = location.linkPath
                if let symlinkDestination = try? FileManager.default.destinationOfSymbolicLink(atPath: linkPath) {
                    let resolved = URL(fileURLWithPath: linkPath).resolvingSymlinksInPath().path
                    let looksLikeManaged = resolved == targetPath || resolved.hasSuffix("/Contents/MacOS/shot") || resolved.hasSuffix("/Contents/MacOS/ShotCli")
                    if looksLikeManaged {
                        do {
                            try FileManager.default.removeItem(atPath: linkPath)
                            removedAny = true
                        } catch {
                            switch location {
                            case .userLocal:
                                blocked = "Failed to remove \(linkPath): \(error.localizedDescription)"
                            case .usrLocal:
                                do {
                                    try Self.removeSymlinkWithAdminPrivileges(linkPath: linkPath)
                                    removedAny = true
                                } catch {
                                    let message = (error as? ShotCommandInstallError)?.message ?? error.localizedDescription
                                    blocked = "Failed to remove \(linkPath): \(message)"
                                }
                            }
                        }
                    } else {
                        _ = symlinkDestination
                    }
                }
            }

            let inspectionResult = Result { try Self.inspect() }
            DispatchQueue.main.async {
                self.isWorking = false
                switch inspectionResult {
                case .success(let inspection):
                    self.applyInspection(inspection)
                case .failure(let error):
                    self.statusTitle = "CLI Install Check Failed"
                    self.statusSymbol = "xmark.octagon.fill"
                    self.statusColor = .red
                    self.guidance = (error as? ShotCommandInstallError)?.message ?? error.localizedDescription
                }

                if let blocked {
                    self.feedback = blocked
                    self.feedbackColor = .red
                } else if removedAny {
                    self.feedback = "Removed managed shot symlink(s)."
                    self.feedbackColor = .secondary
                } else {
                    self.feedback = "No managed shot symlink found to remove."
                    self.feedbackColor = .secondary
                }
            }
        }
    }

    private func performInstall(to location: ShotCommandInstallLocation) {
        isWorking = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let targetPath = try Self.resolveTargetPath()
                try Self.installSymlink(targetPath: targetPath, to: location)

                let inspection = try Self.inspect()
                DispatchQueue.main.async {
                    self.isWorking = false
                    self.applyInspection(inspection)
                    self.feedback = "Installed: \(location.label)"
                    self.feedbackColor = .secondary
                }
            } catch {
                let message = (error as? ShotCommandInstallError)?.message ?? error.localizedDescription
                let recovery: String
                switch location {
                case .userLocal:
                    recovery = ""
                case .usrLocal:
                    let targetPath = (try? Self.resolveTargetPath()) ?? "<ShotCli path>/Contents/MacOS/shot"
                    recovery = "\nRetry and approve the administrator prompt. If needed, run in Terminal:\n" +
                        "sudo mkdir -p /usr/local/bin && sudo ln -sfn \"\(targetPath)\" /usr/local/bin/shot"
                }

                let inspectionResult = Result { try Self.inspect() }
                DispatchQueue.main.async {
                    self.isWorking = false
                    if case .success(let inspection) = inspectionResult {
                        self.applyInspection(inspection)
                    }
                    self.feedback = "Install failed: \(message)\(recovery)"
                    self.feedbackColor = .red
                }
            }
        }
    }

    private func runBackgroundTask(
        _ onSuccess: @escaping (ShotCommandInspection) -> Void,
        onError: @escaping (ShotCommandInstallError) -> Void
    ) {
        isWorking = true
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let inspection = try Self.inspect()
                DispatchQueue.main.async {
                    self.isWorking = false
                    onSuccess(inspection)
                }
            } catch let error as ShotCommandInstallError {
                DispatchQueue.main.async {
                    self.isWorking = false
                    onError(error)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isWorking = false
                    onError(.ioFailure(error.localizedDescription))
                }
            }
        }
    }

    private func applyInspection(_ inspection: ShotCommandInspection) {
        userLocalStatus = inspection.states[.userLocal]?.description ?? "Unknown"
        usrLocalStatus = inspection.states[.usrLocal]?.description ?? "Unknown"

        if let shellPath = inspection.shellCommandPath {
            shellLookupStatus = "\(shellPath)"
        } else {
            shellLookupStatus = "Not found in login shell PATH"
        }

        if inspection.shellCommandResolvesToTarget {
            statusTitle = "shot command ready"
            statusSymbol = "checkmark.seal.fill"
            statusColor = .green
            guidance = "Your login shell resolves `shot` to this ShotCli app."
            return
        }

        let anyManagedInstalled = inspection.states.values.contains { state in
            if case .installed = state {
                return true
            }
            return false
        }

        if anyManagedInstalled {
            statusTitle = "Installed but not active"
            statusSymbol = "exclamationmark.triangle.fill"
            statusColor = .orange
            if let shellPath = inspection.shellCommandPath {
                guidance = "Another `shot` command is first in PATH: \(shellPath)"
            } else {
                guidance = "Add ~/.local/bin to PATH or reopen terminal, then run `shot version`."
            }
            return
        }

        statusTitle = "shot command not installed"
        statusSymbol = "minus.circle.fill"
        statusColor = .orange
        guidance = "Install to ~/.local/bin for no-admin setup."
    }

    private static func inspect() throws -> ShotCommandInspection {
        let targetPath = try resolveTargetPath()

        var states: [ShotCommandInstallLocation: ShotCommandLinkState] = [:]
        for location in ShotCommandInstallLocation.allCases {
            states[location] = inspectLinkState(at: location.linkPath, expectedTargetPath: targetPath)
        }

        let shellPath = loginShellCommandPath()
        let shellResolvesToTarget: Bool
        if let shellPath {
            let resolved = URL(fileURLWithPath: shellPath).resolvingSymlinksInPath().path
            shellResolvesToTarget = resolved == targetPath
        } else {
            shellResolvesToTarget = false
        }

        return ShotCommandInspection(
            targetPath: targetPath,
            shellCommandPath: shellPath,
            shellCommandResolvesToTarget: shellResolvesToTarget,
            states: states
        )
    }

    private static func resolveTargetPath() throws -> String {
        let appBundleURL = Bundle.main.bundleURL
        let macOSDirectory = appBundleURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let candidates = [
            macOSDirectory.appendingPathComponent("shot", isDirectory: false).path,
            macOSDirectory.appendingPathComponent("ShotCli", isDirectory: false).path
        ]

        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate).resolvingSymlinksInPath().path
            }
        }

        throw ShotCommandInstallError.targetMissing
    }

    private static func inspectLinkState(at linkPath: String, expectedTargetPath: String) -> ShotCommandLinkState {
        let fileManager = FileManager.default

        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: linkPath) {
            let resolved = URL(fileURLWithPath: linkPath).resolvingSymlinksInPath().path
            if resolved == expectedTargetPath {
                return .installed
            }
            if fileManager.fileExists(atPath: resolved) {
                return .pointsToOther(resolved)
            }
            return .brokenSymlink(destination)
        }

        if fileManager.fileExists(atPath: linkPath) {
            return .occupiedByFile
        }

        return .missing
    }

    private static func installSymlink(targetPath: String, to location: ShotCommandInstallLocation) throws {
        let fileManager = FileManager.default
        let dirPath = location.directoryPath
        let linkPath = location.linkPath

        if fileManager.fileExists(atPath: linkPath), (try? fileManager.destinationOfSymbolicLink(atPath: linkPath)) == nil {
            throw ShotCommandInstallError.linkPathOccupiedByFile(linkPath)
        }

        switch location {
        case .usrLocal:
            try installSymlinkWithAdminPrivileges(targetPath: targetPath, linkPath: linkPath, directoryPath: dirPath)
            return
        case .userLocal:
            break
        }

        do {
            try fileManager.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        } catch {
            throw ShotCommandInstallError.cannotCreateDirectory(dirPath)
        }

        if !fileManager.isWritableFile(atPath: dirPath) {
            throw ShotCommandInstallError.insufficientPermissions(dirPath)
        }

        if let _ = try? fileManager.destinationOfSymbolicLink(atPath: linkPath) {
            do {
                try fileManager.removeItem(atPath: linkPath)
            } catch {
                throw ShotCommandInstallError.ioFailure("Cannot replace existing symlink at \(linkPath): \(error.localizedDescription)")
            }
        } else if fileManager.fileExists(atPath: linkPath) {
            throw ShotCommandInstallError.linkPathOccupiedByFile(linkPath)
        }

        do {
            try fileManager.createSymbolicLink(atPath: linkPath, withDestinationPath: targetPath)
        } catch {
            throw ShotCommandInstallError.ioFailure("Failed to create symlink \(linkPath) -> \(targetPath): \(error.localizedDescription)")
        }
    }

    private static func installSymlinkWithAdminPrivileges(targetPath: String, linkPath: String, directoryPath: String) throws {
        let commandScript =
            "set cmd to \"/bin/mkdir -p \" & quoted form of dirPath & " +
            "\" && if [ -e \" & quoted form of linkPath & \" ] && [ ! -L \" & quoted form of linkPath & \" ]; then exit 73; fi\" & " +
            "\" && /bin/rm -f \" & quoted form of linkPath & \" && /bin/ln -s \" & quoted form of targetPath & \" \" & quoted form of linkPath"

        let result = runOsaScriptWithAdminPrivileges(
            scriptLines: [
                "on run argv",
                "set targetPath to item 1 of argv",
                "set linkPath to item 2 of argv",
                "set dirPath to item 3 of argv",
                commandScript,
                "do shell script cmd with administrator privileges",
                "end run"
            ],
            arguments: [targetPath, linkPath, directoryPath]
        )

        if result.status == 0 {
            return
        }

        let lower = result.message.lowercased()
        if lower.contains("error number -128") || lower.contains("user canceled") || lower.contains("cancelled") {
            throw ShotCommandInstallError.authorizationCancelled
        }
        if lower.contains("error number 73") || lower.contains("status 73") {
            throw ShotCommandInstallError.linkPathOccupiedByFile(linkPath)
        }
        if lower.contains("not authorized") || lower.contains("permission denied") {
            throw ShotCommandInstallError.insufficientPermissions(linkPath)
        }

        let details = result.message.isEmpty ? "unknown error" : result.message
        throw ShotCommandInstallError.ioFailure("Privileged install failed: \(details)")
    }

    private static func removeSymlinkWithAdminPrivileges(linkPath: String) throws {
        let result = runOsaScriptWithAdminPrivileges(
            scriptLines: [
                "on run argv",
                "set linkPath to item 1 of argv",
                "set cmd to \"if [ -L \" & quoted form of linkPath & \" ]; then /bin/rm -f \" & quoted form of linkPath & \"; fi\"",
                "do shell script cmd with administrator privileges",
                "end run"
            ],
            arguments: [linkPath]
        )

        if result.status == 0 {
            return
        }

        let lower = result.message.lowercased()
        if lower.contains("error number -128") || lower.contains("user canceled") || lower.contains("cancelled") {
            throw ShotCommandInstallError.authorizationCancelled
        }

        let details = result.message.isEmpty ? "unknown error" : result.message
        throw ShotCommandInstallError.ioFailure("Privileged uninstall failed: \(details)")
    }

    private static func runOsaScriptWithAdminPrivileges(scriptLines: [String], arguments: [String]) -> (status: Int32, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")

        var processArgs: [String] = []
        for line in scriptLines {
            processArgs.append("-e")
            processArgs.append(line)
        }
        processArgs.append(contentsOf: arguments)
        process.arguments = processArgs

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription)
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: stdoutData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let combined: String
        if !stderrText.isEmpty && !stdoutText.isEmpty {
            combined = "\(stderrText)\n\(stdoutText)"
        } else if !stderrText.isEmpty {
            combined = stderrText
        } else {
            combined = stdoutText
        }

        return (process.terminationStatus, combined)
    }

    private static func loginShellCommandPath() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v shot || true"]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}
