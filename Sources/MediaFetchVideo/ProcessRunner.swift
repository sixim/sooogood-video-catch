import Foundation

/// Runs a short-lived tool to completion and captures both streams without
/// risking a full-pipe deadlock. Synchronous; call off the main actor.
enum ProcessRunner {
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String]) -> (status: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() } catch { return (-1, Data(), Data(error.localizedDescription.utf8)) }
        var errorData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errorData = errors.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        return (process.terminationStatus, data, errorData)
    }
}
