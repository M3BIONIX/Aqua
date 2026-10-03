import Foundation

public struct AquaError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

public struct CommandResult: Sendable {
    public let status: Int32
    /// stdout, plus stderr unless `separateErrors` was requested.
    public let output: String
    /// stderr when `separateErrors` was requested, otherwise empty.
    public let errors: String
}

/// Thin wrapper around `Process` for short commands (wait for exit) and long-lived
/// ones (Steam, games) that keep running after Aqua returns.
public enum Shell {
    /// Runs a command to completion, streaming each output line to `onLine`.
    @discardableResult
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        timeout: TimeInterval? = nil,
        allowedStatus: Set<Int32>? = [0],
        log: URL? = nil,
        separateErrors: Bool = false,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> CommandResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        let pipe = Pipe()
        let errorPipe = separateErrors ? Pipe() : pipe
        process.standardOutput = pipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector(log: log, onLine: onLine)
        let errorCollector = separateErrors ? OutputCollector(log: log, onLine: onLine) : collector
        for (handle, sink) in Set([ObjectIdentifier(pipe), ObjectIdentifier(errorPipe)]).count == 2
            ? [(pipe.fileHandleForReading, collector), (errorPipe.fileHandleForReading, errorCollector)]
            : [(pipe.fileHandleForReading, collector)] {
            handle.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { sink.append(data) }
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                if let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                        if process.isRunning { collector.timedOut = true; process.terminate() }
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        // Drain whatever is left after exit.
        for (readHandle, sink) in [(pipe.fileHandleForReading, collector), (errorPipe.fileHandleForReading, errorCollector)] {
            readHandle.readabilityHandler = nil
            let rest = readHandle.readDataToEndOfFile()
            if !rest.isEmpty { sink.append(rest) }
        }
        collector.finish()
        if separateErrors { errorCollector.finish() }

        let output = collector.text
        let errors = separateErrors ? errorCollector.text : ""
        if collector.timedOut {
            throw AquaError("\(executable.lastPathComponent) timed out.\n\((output + errors).suffix(1500))")
        }
        if let allowedStatus, !allowedStatus.contains(process.terminationStatus) {
            throw AquaError("\(executable.lastPathComponent) \(arguments.first ?? "") failed (exit \(process.terminationStatus)).\n\((errors + output).suffix(1500))")
        }
        return CommandResult(status: process.terminationStatus, output: output, errors: errors)
    }

    /// Starts a long-running process with output going to `log`. Returns immediately.
    @discardableResult
    public static func spawn(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String],
        workingDirectory: URL? = nil,
        log: URL
    ) throws -> Process {
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in try? handle.close() }
        try process.run()
        return process
    }
}

/// Collects process output, splitting it into lines for live progress.
/// legendary redraws progress with `\r`, so both `\r` and `\n` end a line.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = ""
    private let logHandle: FileHandle?
    private let onLine: (@Sendable (String) -> Void)?
    var timedOut = false

    init(log: URL?, onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
        if let log {
            try? FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: log.path) { FileManager.default.createFile(atPath: log.path, contents: nil) }
            logHandle = try? FileHandle(forWritingTo: log)
            _ = try? logHandle?.seekToEnd()
        } else {
            logHandle = nil
        }
    }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(chunk)
        try? logHandle?.write(contentsOf: chunk)
        guard let onLine else { return }
        pending += String(decoding: chunk, as: UTF8.self)
        var lines = pending.components(separatedBy: CharacterSet(charactersIn: "\r\n"))
        pending = lines.removeLast()
        for line in lines where !line.isEmpty { onLine(line) }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { onLine?(pending); pending = "" }
        try? logHandle?.close()
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
