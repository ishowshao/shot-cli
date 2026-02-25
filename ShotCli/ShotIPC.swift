import Darwin
import Foundation

private enum LegacyXPCArtifacts {
    private static let serviceName = "com.shshaoxia.ShotCli.CLIService"

    static func cleanupIfPresent() {
        guard FileManager.default.fileExists(atPath: legacyPlistURL.path) else {
            return
        }

        let service = "gui/\(getuid())/\(serviceName)"
        _ = runLaunchctl(arguments: ["bootout", service])
        _ = runLaunchctl(arguments: ["remove", serviceName])
        try? FileManager.default.removeItem(at: legacyPlistURL)
    }

    private static var legacyPlistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(serviceName).plist", isDirectory: false)
    }

    @discardableResult
    private static func runLaunchctl(arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}

enum ShotCLIEntrypoint {
    static func run(arguments: [String]) -> Int32 {
        LegacyXPCArtifacts.cleanupIfPresent()
        return ShotCLI().run(arguments: arguments)
    }
}
