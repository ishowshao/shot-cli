import SwiftUI

@main
struct ShotCliApp: App {
    init() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let first = args.first else { return }

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
        guard cliCommands.contains(first) else { return }

        let exitCode = ShotCLI().run(arguments: args)
        fflush(stdout)
        fflush(stderr)
        Darwin.exit(exitCode)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
