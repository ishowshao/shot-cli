import Foundation

enum ShotCLIXPCConstants {
    static let serviceName = "com.shshaoxia.ShotCli.CLIService"
}

@objc protocol ShotCLIXPCProtocol {
    func ping(withReply reply: @escaping (Bool) -> Void)
    func runCommand(arguments: [String], withReply reply: @escaping (Int32, Data, Data) -> Void)
}
