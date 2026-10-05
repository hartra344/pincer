#if DEBUG && os(macOS)
import Foundation
import Darwin

package func runUnitAbortEvidenceFixture(script: URL) async throws -> (Int32, String) {
    try await withCheckedThrowingContinuation { completion in
        DispatchQueue.global(qos: .utility).async { @Sendable in
            do {
                let process = Process(), pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = ["python3", script.path]
                process.standardOutput = pipe; process.standardError = pipe
                try process.run()
                func stopped(after seconds: Double) -> Bool {
                    let deadline = ContinuousClock.now + .seconds(seconds)
                    while process.isRunning && ContinuousClock.now < deadline { Thread.sleep(forTimeInterval: 0.01) }
                    return !process.isRunning
                }
                if !stopped(after: 20) {
                    if process.isRunning {
                        guard kill(process.processIdentifier, SIGTERM) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM) }
                    }
                    if !stopped(after: 3) {
                        if process.isRunning {
                            guard kill(process.processIdentifier, SIGKILL) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM) }
                        }
                        guard stopped(after: 3) else { throw CocoaError(.executableRuntimeMismatch) }
                    }
                }
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                completion.resume(returning: (process.terminationStatus, String(decoding: data.prefix(16_384), as: UTF8.self)))
            } catch { completion.resume(throwing: error) }
        }
    }
}
#endif
