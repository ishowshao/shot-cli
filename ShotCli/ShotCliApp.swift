import SwiftUI

@main
struct ShotCliApp: App {
    init() {
        let rawArgs = Array(CommandLine.arguments.dropFirst())
        let args = rawArgs.filter { !$0.hasPrefix("-psn_") }

        if let relayIndex = args.firstIndex(of: ShotCLIRequestRelay.command) {
            let relayArgs = Array(args[relayIndex...])
            let exitCode = ShotCLIRequestRelay.handle(arguments: relayArgs)
            fflush(stdout)
            fflush(stderr)
            Darwin.exit(exitCode)
        }

        if let first = args.first {
            let cliCommands: Set<String> = [
                "help",
                "--help",
                "-h",
                "version",
                "doctor",
                "displays",
                "windows",
                "capture"
            ]

            if cliCommands.contains(first) {
                let exitCode = ShotCLIEntrypoint.run(arguments: args)
                fflush(stdout)
                fflush(stderr)
                Darwin.exit(exitCode)
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
