import Darwin
import Foundation

private enum ShotCLIXPCConfig {
    static let machServiceName = "com.shshaoxia.ShotCli.CLIService"
    static let launchAgentLabel = "com.shshaoxia.ShotCli.CLIService"
}

enum ShotCLIXPCLaunchAgent {
    static let serviceCommand = "__shotcli_xpc_service"

    static func ensureLoaded(serviceExecutablePath: String) throws {
        try writeLaunchAgentPlist(serviceExecutablePath: serviceExecutablePath)

        let domain = launchDomain
        let service = "\(domain)/\(ShotCLIXPCConfig.launchAgentLabel)"

        let printResult = try runLaunchctl(arguments: ["print", service], allowFailure: true)
        if printResult.status != 0 {
            _ = try runLaunchctl(arguments: ["bootstrap", domain, launchAgentPlistURL.path], allowFailure: false)
        } else {
            let expectedProgramLine = "program = \(serviceExecutablePath)"
            if !printResult.stdout.contains(expectedProgramLine) {
                _ = try runLaunchctl(arguments: ["bootout", service], allowFailure: true)
                _ = try runLaunchctl(arguments: ["bootstrap", domain, launchAgentPlistURL.path], allowFailure: false)
            }
        }

        _ = try runLaunchctl(arguments: ["kickstart", service], allowFailure: false)
    }

    static var launchDomain: String {
        "gui/\(getuid())"
    }

    private static var launchAgentPlistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(ShotCLIXPCConfig.launchAgentLabel).plist", isDirectory: false)
    }

    private static func writeLaunchAgentPlist(serviceExecutablePath: String) throws {
        let launchAgentsDirectory = launchAgentPlistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "Label": ShotCLIXPCConfig.launchAgentLabel,
            "ProgramArguments": [serviceExecutablePath, serviceCommand],
            "MachServices": [ShotCLIXPCConfig.machServiceName: true],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive"
        ]

        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: launchAgentPlistURL, options: .atomic)
    }

    @discardableResult
    private static func runLaunchctl(arguments: [String], allowFailure: Bool) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutText = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrText = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if !allowFailure && process.terminationStatus != 0 {
            let suffix = stderrText.isEmpty ? "" : " \(stderrText)"
            throw ShotCLIServiceClientError.unavailable("launchctl \(arguments.joined(separator: " ")) failed.\(suffix)")
        }

        return (process.terminationStatus, stdoutText, stderrText)
    }
}

private struct ShotCLIStdIOCaptureResult {
    let exitCode: Int
    let stdout: Data
    let stderr: Data
}

private enum ShotCLIStdIOCapture {
    private static let lock = NSLock()

    static func run(arguments: [String]) -> ShotCLIStdIOCaptureResult {
        lock.lock()
        defer { lock.unlock() }

        fflush(stdout)
        fflush(stderr)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdoutBackup = dup(STDOUT_FILENO)
        let stderrBackup = dup(STDERR_FILENO)

        guard stdoutBackup >= 0, stderrBackup >= 0 else {
            let exitCode = Int(ShotCLI().run(arguments: arguments))
            return ShotCLIStdIOCaptureResult(exitCode: exitCode, stdout: Data(), stderr: Data())
        }

        dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        let exitCode = Int(ShotCLI().run(arguments: arguments))

        fflush(stdout)
        fflush(stderr)

        // Restore stdio before reading pipe output; otherwise EOF never arrives.
        dup2(stdoutBackup, STDOUT_FILENO)
        dup2(stderrBackup, STDERR_FILENO)
        close(stdoutBackup)
        close(stderrBackup)

        stdoutPipe.fileHandleForWriting.closeFile()
        stderrPipe.fileHandleForWriting.closeFile()

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return ShotCLIStdIOCaptureResult(exitCode: exitCode, stdout: outData, stderr: errData)
    }
}

@objc protocol ShotCLIXPCProtocol {
    func ping(withReply reply: @escaping (Bool) -> Void)
    func runCommand(arguments: [String], withReply reply: @escaping (Int32, Data, Data) -> Void)
}

final class ShotCLIXPCService: NSObject, ShotCLIXPCProtocol {
    func ping(withReply reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func runCommand(arguments: [String], withReply reply: @escaping (Int32, Data, Data) -> Void) {
        let result = ShotCLIStdIOCapture.run(arguments: arguments)
        reply(Int32(result.exitCode), result.stdout, result.stderr)
    }
}

final class ShotCLIXPCServer: NSObject, NSXPCListenerDelegate {
    static let shared = ShotCLIXPCServer()

    private let stateQueue = DispatchQueue(label: "com.shshaoxia.ShotCli.xpc.server")
    private let service = ShotCLIXPCService()
    private var listener: NSXPCListener?

    func startIfNeeded() {
        stateQueue.sync {
            guard listener == nil else { return }

            let newListener = NSXPCListener(machServiceName: ShotCLIXPCConfig.machServiceName)
            newListener.delegate = self
            newListener.resume()
            listener = newListener
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ShotCLIXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
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
        let executablePath = try resolveServiceExecutablePath()

        do {
            try ShotCLIXPCLaunchAgent.ensureLoaded(serviceExecutablePath: executablePath)
            try waitForServiceReady(timeout: 5)
            return try runViaMachService(arguments: arguments, timeout: runTimeoutSeconds)
        } catch {
            try launchShotCliApp()
            try ShotCLIXPCLaunchAgent.ensureLoaded(serviceExecutablePath: executablePath)
            try waitForServiceReady(timeout: 8)
            return try runViaMachService(arguments: arguments, timeout: runTimeoutSeconds)
        }
    }

    private func resolveServiceExecutablePath() throws -> String {
        guard let executableURL = Bundle.main.executableURL else {
            throw ShotCLIServiceClientError.unavailable("Unable to resolve ShotCli executable path.")
        }
        return executableURL.resolvingSymlinksInPath().path
    }

    private func waitForServiceReady(timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        while Date() < deadline {
            do {
                if try pingViaMachService(timeout: 1) {
                    return
                }
            } catch {
                lastError = error
            }

            Thread.sleep(forTimeInterval: 0.15)
        }

        throw ShotCLIServiceClientError.unavailable("XPC service did not become ready in time. \(lastError?.localizedDescription ?? "")")
    }

    private func pingViaMachService(timeout: TimeInterval) throws -> Bool {
        let connection = NSXPCConnection(machServiceName: ShotCLIXPCConfig.machServiceName, options: [])
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

    private func runViaMachService(arguments: [String], timeout: TimeInterval) throws -> ShotCLIServiceClientResult {
        let connection = NSXPCConnection(machServiceName: ShotCLIXPCConfig.machServiceName, options: [])
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

    private func launchShotCliApp() throws {
        let bundlePath = Bundle.main.bundleURL.path
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            throw ShotCLIServiceClientError.unavailable("ShotCli.app bundle path not found.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-g", "-a", bundlePath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ShotCLIServiceClientError.unavailable("Failed to launch ShotCli.app.")
        }
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
                "hint": "Open ShotCli.app and keep it running, then retry."
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
