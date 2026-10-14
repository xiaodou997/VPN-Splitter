// SPDX-License-Identifier: MIT
import Foundation

/// One byte-stream side of a relayed TCP flow. Implementations must be
/// cancellation-safe: after `close()` every pending and future read fails or
/// returns EOF. No payload may be logged or persisted by implementations.
public protocol ExternalFlowPipe: Sendable {
    /// Returns nil on clean EOF.
    func readChunk(maxBytes: Int) async throws -> Data?
    func writeChunk(_ data: Data) async throws
    /// Best-effort half-close of the write direction; the read side stays open.
    func closeWrite() async
    func close() async
}

public enum ExternalFlowRelayOutcome: String, Sendable, Equatable {
    case completed, failed, cancelled
}

public struct ExternalFlowRelayLimits: Sendable, Equatable {
    public var maxConcurrent: Int
    public var chunkBytes: Int
    public var idleTimeout: TimeInterval
    public static let `default` = Self(maxConcurrent: 64, chunkBytes: 65_536, idleTimeout: 75)
    public init(maxConcurrent: Int, chunkBytes: Int, idleTimeout: TimeInterval) {
        self.maxConcurrent = maxConcurrent
        self.chunkBytes = chunkBytes
        self.idleTimeout = idleTimeout
    }
}

/// Bidirectional byte copy between two pipes. On any read/write error or idle
/// timeout both sides are closed; on one side's EOF the other side's write is
/// half-closed. The relay finishes only when both directions end (or an
/// error/cancel/timeout closes everything first).
public actor ExternalFlowRelay {
    private let local: any ExternalFlowPipe
    private let remote: any ExternalFlowPipe
    private let limits: ExternalFlowRelayLimits
    private var lastActivity: ContinuousClock.Instant
    private var cancelRequested = false

    public init(local: any ExternalFlowPipe, remote: any ExternalFlowPipe,
                limits: ExternalFlowRelayLimits = .default) {
        self.local = local
        self.remote = remote
        self.limits = limits
        self.lastActivity = .now
    }

    private enum StageResult: Sendable {
        case direction(Bool)
        case watchdog(Bool)
    }

    public func run() async -> ExternalFlowRelayOutcome {
        let healthy = await withTaskGroup(of: StageResult.self, returning: Bool.self) { group in
            group.addTask { await .direction(self.copy(from: self.local, to: self.remote)) }
            group.addTask { await .direction(self.copy(from: self.remote, to: self.local)) }
            group.addTask { await .watchdog(self.watchdog()) }
            var healthy = true
            var directions = 0
            for await result in group {
                switch result {
                case .direction(let directionHealthy):
                    directions += 1
                    if !directionHealthy { healthy = false }
                    if directions == 2 || !healthy { group.cancelAll() }
                case .watchdog(let watchdogHealthy):
                    if !watchdogHealthy { healthy = false; group.cancelAll() }
                }
            }
            return healthy
        }
        await local.close()
        await remote.close()
        if cancelRequested { return .cancelled }
        return healthy ? .completed : .failed
    }

    /// Unblocks in-flight reads by closing both pipes; `run()` then returns
    /// `.cancelled`. Safe to call more than once.
    public func cancel() {
        guard !cancelRequested else { return }
        cancelRequested = true
        Task { await local.close(); await remote.close() }
    }

    private func noteActivity() { lastActivity = .now }

    /// true = direction ended cleanly (EOF), false = error, cancel or timeout.
    private func copy(from source: any ExternalFlowPipe, to sink: any ExternalFlowPipe) async -> Bool {
        do {
            while true {
                try Task.checkCancellation()
                if cancelRequested { return false }
                guard let chunk = try await source.readChunk(maxBytes: limits.chunkBytes) else {
                    await sink.closeWrite()
                    return true
                }
                noteActivity()
                try Task.checkCancellation()
                try await sink.writeChunk(chunk)
                noteActivity()
            }
        } catch {
            return false
        }
    }

    /// true = cancelled as part of normal teardown; false = idle timeout fired.
    private func watchdog() async -> Bool {
        let interval = max(0.05, min(5, limits.idleTimeout / 2))
        while !Task.isCancelled && !cancelRequested {
            try? await Task.sleep(for: .seconds(interval))
            if Task.isCancelled || cancelRequested { return true }
            if ContinuousClock.now - lastActivity >= .seconds(limits.idleTimeout) { return false }
        }
        return true
    }
}

/// Bounded registry: at most `limits.maxConcurrent` live relays; excess refused.
public actor ExternalFlowRelayRegistry {
    public enum AdmitError: String, Error, Sendable { case limitReached }
    private let limits: ExternalFlowRelayLimits
    private var active = 0
    public init(limits: ExternalFlowRelayLimits = .default) { self.limits = limits }

    public func admit() throws {
        guard active < limits.maxConcurrent else { throw AdmitError.limitReached }
        active += 1
    }
    public func release() { active = max(0, active - 1) }
    public var activeCount: Int { active }
}
