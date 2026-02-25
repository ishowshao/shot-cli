import Darwin
import Foundation

private struct ShotCLIStdIOCaptureResult {
    let exitCode: Int32
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
            let exitCode = ShotCLI().run(arguments: arguments)
            return ShotCLIStdIOCaptureResult(exitCode: exitCode, stdout: Data(), stderr: Data())
        }

        dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        let exitCode = ShotCLI().run(arguments: arguments)

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

final class ShotCLIXPCService: NSObject, ShotCLIXPCProtocol {
    func ping(withReply reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func runCommand(arguments: [String], withReply reply: @escaping (Int32, Data, Data) -> Void) {
        let result = ShotCLIStdIOCapture.run(arguments: arguments)
        reply(result.exitCode, result.stdout, result.stderr)
    }
}

final class ShotCLIXPCDelegate: NSObject, NSXPCListenerDelegate {
    private let service = ShotCLIXPCService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: ShotCLIXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

let delegate = ShotCLIXPCDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
dispatchMain()
