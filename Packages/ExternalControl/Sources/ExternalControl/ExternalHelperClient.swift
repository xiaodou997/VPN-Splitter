// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import ServiceManagement
import Darwin

/// Main-actor client; only Data crosses callbacks. No NSXPCConnection is captured
/// in a detached task. A timeout invalidates the channel, never retries an apply.
@MainActor
public final class ExternalHelperClient {
    private var connection: NSXPCConnection?
    private var pending: (UUID, CheckedContinuation<Data, any Error>)?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    public private(set) var instance: UUID?
    public var onDisconnect: (@MainActor () -> Void)?
    public init() {}
    public var isConnected: Bool { connection != nil && instance != nil }
    public func registrationStatus() -> String {
        guard (try? ExternalControlIdentity.currentTeam(helper: false)) != nil else { return "requiresSignedBuild" }
        switch SMAppService.daemon(plistName: ExternalControlIdentity.plist).status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }
    public func register() throws {
        _ = try ExternalControlIdentity.currentTeam(helper: false)
        // Do not register a development artifact from a writable checkout directory.
        guard Bundle.main.bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().path == "/Applications" else {
            throw ExternalControlError.unavailable
        }
        try SMAppService.daemon(plistName: ExternalControlIdentity.plist).register()
    }
    public func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
    public func unregisterAfterCleanStatus() async throws {
        if !isConnected { _ = try await connect() }
        let response = try await send(.init(.status, instance: instance))
        guard response.result.state == .idle || response.result.state == .closed,
              response.result.owned == 0 else { throw ExternalControlError.recoveryRequired }
        let quiesced = try await send(.init(.quiesce, instance: instance))
        guard quiesced.result.state == .closed, quiesced.result.code == "quiesced" else { throw ExternalControlError.busy }
        close()
        try await SMAppService.daemon(plistName: ExternalControlIdentity.plist).unregister()
    }
    @discardableResult public func connect() async throws -> ExternalControlReply {
        try Task.checkCancellation()
        guard connection == nil else { throw ExternalControlError.busy }
        let team = try ExternalControlIdentity.currentTeam(helper: false)
        guard registrationStatus() == "enabled" else { throw ExternalControlError.unavailable }
        let channel = NSXPCConnection(machServiceName: ExternalControlIdentity.service, options: .privileged)
        channel.setCodeSigningRequirement(try ExternalControlIdentity.requirement(team: team, helper: true))
        channel.remoteObjectInterface = NSXPCInterface(with: ExternalHelperXPC.self)
        let id = UUID(); generation = id
        channel.interruptionHandler = { [weak self] in Task { @MainActor [weak self] in self?.failed(id, error: .disconnected) } }
        channel.invalidationHandler = { [weak self] in Task { @MainActor [weak self] in self?.failed(id, error: .disconnected) } }
        connection = channel; channel.resume()
        do {
            // No rules are sent until an authenticated round trip and kernel root UID check.
            let hello = try await send(.init(.hello))
            guard generation == id, self.connection === channel, !Task.isCancelled,
                  channel.effectiveUserIdentifier == 0, hello.result.state != .refused else { throw ExternalControlError.authentication }
            instance = hello.instance; return hello
        } catch { if generation == id { close() }; throw error }
    }
    public func send(_ request: ExternalControlRequest) async throws -> ExternalControlReply {
        try Task.checkCancellation()
        guard let connection, pending == nil else { throw ExternalControlError.unavailable }
        let data = try request.encoded()
        _ = try ExternalControlRequest.decode(data)
        let id = generation
        let response: Data = try await withCheckedThrowingContinuation { continuation in
            pending = (request.id, continuation)
            deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(25)) } catch { return }
                self?.failed(id, error: .timeout)
            }
            let remote = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                Task { @MainActor [weak self] in self?.failed(id, error: .disconnected) }
            }
            guard let proxy = remote as? ExternalHelperXPC else { failed(id, error: .unavailable); return }
            proxy.request(data) { [weak self] bytes in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == id, self.pending?.0 == request.id else { return }
                    self.deadline?.cancel(); self.deadline = nil
                    let pending = self.pending; self.pending = nil
                    pending?.1.resume(returning: bytes)
                }
            }
        }
        guard generation == id, !Task.isCancelled else { throw ExternalControlError.disconnected }
        do { return try ExternalControlReply.decode(response, request: request) }
        catch { close(); throw ExternalControlError.invalidResponse }
    }
    public func close() {
        generation = UUID(); instance = nil; deadline?.cancel(); deadline = nil
        let waiting = pending; pending = nil
        let channel = connection; connection = nil
        channel?.invalidate(); waiting?.1.resume(throwing: ExternalControlError.disconnected)
    }
    private func failed(_ id: UUID, error: ExternalControlError) {
        guard generation == id else { return }
        let waiting = pending; pending = nil
        close(); waiting?.1.resume(throwing: error); onDisconnect?()
    }
}
#endif
