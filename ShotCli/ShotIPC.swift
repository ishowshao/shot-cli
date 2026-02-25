import Foundation

private enum ShotCLILegacyLaunchAgent {
    static func cleanupIfPresent() {
        guard FileManager.default.fileExists(atPath: legacyPlistURL.path) else {
            return
        }

        let service = "gui/\(getuid())/\(ShotCLIXPCConstants.serviceName)"
        _ = runLaunchctl(arguments: ["bootout", service])
        _ = runLaunchctl(arguments: ["remove", ShotCLIXPCConstants.serviceName])
        try? FileManager.default.removeItem(at: legacyPlistURL)
    }

    private static var legacyPlistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(ShotCLIXPCConstants.serviceName).plist", isDirectory: false)
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

struct ShotCLIServiceClientResult {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

enum ShotCLIServiceClientError: Error {
    case unavailable(String)
}

final class ShotCLIServiceClient {
    private let runTimeoutSeconds: TimeInterval = 20

    func run(arguments: [String]) throws -> ShotCLIServiceClientResult {
        ShotCLILegacyLaunchAgent.cleanupIfPresent()
        try waitForServiceReady(timeout: 5)
        return try runViaXPCService(arguments: arguments, timeout: runTimeoutSeconds)
    }

    private func waitForServiceReady(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        while Date() < deadline {
            do {
                if try pingViaXPCService(timeout: 1) {
                    return
                }
            } catch {
                lastError = error
            }

            Thread.sleep(forTimeInterval: 0.15)
        }

        throw ShotCLIServiceClientError.unavailable("XPC service did not become ready in time. \(lastError?.localizedDescription ?? "")")
    }

    private func pingViaXPCService(timeout: TimeInterval) throws -> Bool {
        let connection = NSXPCConnection(serviceName: ShotCLIXPCConstants.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: ShotCLIXPCProtocol.self)

        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var reply: Bool?
        var replyError: Error?

        func finishWithError(_ error: Error) {
            resultLock.lock()
            defer { resultLock.unlock() }
            guard reply == nil, replyError == nil else { return }
            replyError = error
            semaphore.signal()
        }

        connection.interruptionHandler = {
            finishWithError(ShotCLIServiceClientError.unavailable("XPC connection interrupted."))
        }
        connection.invalidationHandler = {
            finishWithError(ShotCLIServiceClientError.unavailable("XPC connection invalidated."))
        }

        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finishWithError(ShotCLIServiceClientError.unavailable("XPC call failed: \(error.localizedDescription)"))
        }) as? ShotCLIXPCProtocol else {
            connection.invalidate()
            throw ShotCLIServiceClientError.unavailable("Failed to create XPC proxy.")
        }

        proxy.ping { ok in
            resultLock.lock()
            defer { resultLock.unlock() }
            guard reply == nil, replyError == nil else { return }
            reply = ok
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        connection.invalidate()

        if waitResult == .timedOut {
            throw ShotCLIServiceClientError.unavailable("Timed out waiting for XPC ping response.")
        }
        if let value = reply {
            return value
        }

        throw replyError ?? ShotCLIServiceClientError.unavailable("XPC ping finished without a response.")
    }

    private func runViaXPCService(arguments: [String], timeout: TimeInterval) throws -> ShotCLIServiceClientResult {
        let connection = NSXPCConnection(serviceName: ShotCLIXPCConstants.serviceName)
        connection.remoteObjectInterface = NSXPCInterface(with: ShotCLIXPCProtocol.self)

        let semaphore = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var replyResult: ShotCLIServiceClientResult?
        var replyError: Error?

        func finishWithError(_ error: Error) {
            resultLock.lock()
            defer { resultLock.unlock() }
            guard replyResult == nil, replyError == nil else { return }
            replyError = error
            semaphore.signal()
        }

        connection.interruptionHandler = {
            finishWithError(ShotCLIServiceClientError.unavailable("XPC connection interrupted."))
        }
        connection.invalidationHandler = {
            finishWithError(ShotCLIServiceClientError.unavailable("XPC connection invalidated."))
        }

        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
            finishWithError(ShotCLIServiceClientError.unavailable("XPC call failed: \(error.localizedDescription)"))
        }) as? ShotCLIXPCProtocol else {
            connection.invalidate()
            throw ShotCLIServiceClientError.unavailable("Failed to create XPC proxy.")
        }

        proxy.runCommand(arguments: arguments) { exitCode, stdout, stderr in
            resultLock.lock()
            defer { resultLock.unlock() }
            guard replyResult == nil, replyError == nil else { return }
            replyResult = ShotCLIServiceClientResult(exitCode: exitCode, stdout: stdout, stderr: stderr)
            semaphore.signal()
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)
        connection.invalidate()

        if waitResult == .timedOut {
            throw ShotCLIServiceClientError.unavailable("Timed out waiting for XPC response.")
        }
        if let result = replyResult {
            return result
        }

        throw replyError ?? ShotCLIServiceClientError.unavailable("XPC request finished without a response.")
    }
}

enum ShotCLIEntrypoint {
    private static let remoteCommands: Set<String> = ["doctor", "displays", "windows", "capture"]

    static func run(arguments: [String]) -> Int32 {
        guard let first = arguments.first, remoteCommands.contains(first) else {
            return ShotCLI().run(arguments: arguments)
        }

        do {
            let result = try ShotCLIServiceClient().run(arguments: arguments)
            if !result.stdout.isEmpty {
                FileHandle.standardOutput.write(result.stdout)
            }
            if !result.stderr.isEmpty {
                FileHandle.standardError.write(result.stderr)
            }
            return result.exitCode
        } catch {
            emitServiceUnavailable(error: error, pretty: arguments.contains("--pretty"))
            return ShotExitCode.serviceUnavailable.rawValue
        }
    }

    private static func emitServiceUnavailable(error: Error, pretty: Bool) {
        let message: String
        if let clientError = error as? ShotCLIServiceClientError {
            switch clientError {
            case .unavailable(let reason):
                message = reason
            }
        } else {
            message = error.localizedDescription
        }

        let payload: [String: Any] = [
            "ok": false,
            "error": [
                "code": Int(ShotExitCode.serviceUnavailable.rawValue),
                "name": "ERR_SERVICE_UNAVAILABLE",
                "message": "ShotCli service unavailable: \(message)",
                "hint": "Use the binary inside ShotCli.app (or the installed shot symlink) and retry."
            ]
        ]

        let options: JSONSerialization.WritingOptions = pretty ? [.prettyPrinted] : []
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: options) {
            FileHandle.standardError.write(data)
            FileHandle.standardError.write(Data("\n".utf8))
        } else {
            FileHandle.standardError.write(Data("{\"ok\":false,\"error\":{\"code\":10,\"name\":\"ERR_SERVICE_UNAVAILABLE\",\"message\":\"ShotCli service unavailable.\"}}\n".utf8))
        }
    }
}
