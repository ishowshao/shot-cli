import Darwin
import Foundation

private enum ShotIPCPaths {
    static var rootDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("ShotCli/ipc", isDirectory: true)
    }

    static var requestsDirectory: URL {
        rootDirectory.appendingPathComponent("requests", isDirectory: true)
    }

    static var responsesDirectory: URL {
        rootDirectory.appendingPathComponent("responses", isDirectory: true)
    }

    static func requestURL(id: String) -> URL {
        requestsDirectory.appendingPathComponent("\(id).json", isDirectory: false)
    }

    static func responseURL(id: String) -> URL {
        responsesDirectory.appendingPathComponent("\(id).json", isDirectory: false)
    }
}

private struct ShotCLIStdIOCaptureResult {
    let exitCode: Int
    let stdout: Data
    let stderr: Data
}

private enum ShotCLIStdIOCapture {
    static func run(arguments: [String]) -> ShotCLIStdIOCaptureResult {
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

private enum ShotCLIRequestRelayCodec {
    static func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: ShotIPCPaths.requestsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ShotIPCPaths.responsesDirectory, withIntermediateDirectories: true)
    }

    static func writeRequest(id: String, arguments: [String]) throws {
        let requestJSON: [String: Any] = [
            "arguments": arguments,
            "createdAt": ISO8601DateFormatter().string(from: Date())
        ]
        let data = try JSONSerialization.data(withJSONObject: requestJSON, options: [])
        try data.write(to: ShotIPCPaths.requestURL(id: id), options: .atomic)
    }

    static func loadRequestArguments(id: String) throws -> [String] {
        let data = try Data(contentsOf: ShotIPCPaths.requestURL(id: id))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arguments = json["arguments"] as? [String]
        else {
            throw NSError(domain: "ShotCli", code: Int(ShotExitCode.invalidArguments.rawValue))
        }
        return arguments
    }

    static func writeResponse(id: String, result: ShotCLIStdIOCaptureResult) throws {
        let responseJSON: [String: Any] = [
            "exitCode": result.exitCode,
            "stdoutBase64": result.stdout.base64EncodedString(),
            "stderrBase64": result.stderr.base64EncodedString()
        ]
        let data = try JSONSerialization.data(withJSONObject: responseJSON, options: [])
        try data.write(to: ShotIPCPaths.responseURL(id: id), options: .atomic)
    }

    static func loadResponse(id: String) throws -> ShotCLIServiceClientResult {
        let data = try Data(contentsOf: ShotIPCPaths.responseURL(id: id))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exitCode = json["exitCode"] as? Int
        else {
            throw NSError(domain: "ShotCli", code: Int(ShotExitCode.captureFailed.rawValue))
        }

        let stdout = Data(base64Encoded: (json["stdoutBase64"] as? String) ?? "") ?? Data()
        let stderr = Data(base64Encoded: (json["stderrBase64"] as? String) ?? "") ?? Data()

        return ShotCLIServiceClientResult(exitCode: Int32(exitCode), stdout: stdout, stderr: stderr)
    }
}

enum ShotCLIRequestRelay {
    static let command = "__shotcli_handle_request"

    static func handle(arguments: [String]) -> Int32 {
        guard arguments.count >= 2 else {
            return ShotExitCode.invalidArguments.rawValue
        }

        let requestID = arguments[1]

        do {
            let requestArguments = try ShotCLIRequestRelayCodec.loadRequestArguments(id: requestID)
            let result = ShotCLIStdIOCapture.run(arguments: requestArguments)
            try ShotCLIRequestRelayCodec.writeResponse(id: requestID, result: result)
            return ShotExitCode.ok.rawValue
        } catch {
            let payload = ShotCLIStdIOCaptureResult(
                exitCode: Int(ShotExitCode.serviceUnavailable.rawValue),
                stdout: Data(),
                stderr: Data("{\"ok\":false,\"error\":{\"code\":10,\"name\":\"ERR_SERVICE_UNAVAILABLE\",\"message\":\"Failed to process relayed CLI request.\"}}\n".utf8)
            )
            try? ShotCLIRequestRelayCodec.writeResponse(id: requestID, result: payload)
            return ShotExitCode.serviceUnavailable.rawValue
        }
    }
}

struct ShotCLIServiceClientResult {
    let exitCode: Int32
    let stdout: Data
    let stderr: Data
}

private enum ShotCLIServiceClientError: Error {
    case unavailable(String)
}

final class ShotCLIServiceClient {
    func run(arguments: [String]) throws -> ShotCLIServiceClientResult {
        try ShotCLIRequestRelayCodec.prepareDirectories()

        let requestID = UUID().uuidString.lowercased()
        let requestURL = ShotIPCPaths.requestURL(id: requestID)
        let responseURL = ShotIPCPaths.responseURL(id: requestID)

        defer {
            try? FileManager.default.removeItem(at: requestURL)
            try? FileManager.default.removeItem(at: responseURL)
        }

        try ShotCLIRequestRelayCodec.writeRequest(id: requestID, arguments: arguments)
        try launchRelayWorker(requestID: requestID)

        guard FileManager.default.fileExists(atPath: responseURL.path) else {
            throw ShotCLIServiceClientError.unavailable("Relay worker completed but no response file was generated.")
        }
        return try ShotCLIRequestRelayCodec.loadResponse(id: requestID)
    }

    private func launchRelayWorker(requestID: String) throws {
        let bundlePath = Bundle.main.bundleURL.path
        guard FileManager.default.fileExists(atPath: bundlePath) else {
            throw ShotCLIServiceClientError.unavailable("ShotCli.app bundle path not found.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-W", "-n", "-a", bundlePath, "--args", ShotCLIRequestRelay.command, requestID]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ShotCLIServiceClientError.unavailable("Failed to launch relay worker app instance.")
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
