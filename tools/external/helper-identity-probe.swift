// SPDX-License-Identifier: MIT
// Development-only negative client. Sends exactly one hello, never a rule or mutation.
// Build with the actual ExternalControlIdentity.swift and ExternalControlWire.swift.
import Foundation
import Darwin

@MainActor
private final class IdentityProbe {
    private var channel: NSXPCConnection?
    private var waiting: CheckedContinuation<String, Never>?
    private var deadline: Task<Void, Never>?
    func run(team: String) async throws -> String {
        guard getuid() != 0, geteuid() == getuid() else { return "invalid_test_user" }
        var request = ExternalControlRequest(.hello)
        request.sequence = 1
        let bytes = try request.encoded()
        let connection = NSXPCConnection(machServiceName: ExternalControlIdentity.service, options: .privileged)
        // Authenticate the expected Helper even though this test client has an invalid identity.
        connection.setCodeSigningRequirement(try ExternalControlIdentity.requirement(team: team, helper: true))
        connection.remoteObjectInterface = NSXPCInterface(with: ExternalHelperXPC.self)
        connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.finish("connection_invalidated") } }
        connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.finish("connection_interrupted") } }
        channel = connection
        return await withCheckedContinuation { continuation in
            waiting = continuation
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                self?.finish("timeout_inconclusive")
            }
            connection.resume()
            let remote = connection.remoteObjectProxyWithErrorHandler { @Sendable [weak self] error in
                let value = error as NSError
                let code = value.domain == NSCocoaErrorDomain ? String(value.code) : "other_domain"
                Task { @MainActor in self?.finish("proxy_error_" + code) }
            }
            guard let proxy = remote as? ExternalHelperXPC else { finish("proxy_cast_inconclusive"); return }
            proxy.request(bytes) { @Sendable [weak self] response in
                let result: String
                if let reply = try? ExternalControlReply.decode(response, request: request) {
                    result = reply.result.state == .refused ? "application_refused" : "UNEXPECTED_ACCEPTANCE"
                } else { result = "invalid_reply_inconclusive" }
                Task { @MainActor in self?.finish(result) }
            }
        }
    }
    private func finish(_ result: String) {
        guard let continuation = waiting else { return }
        waiting = nil; deadline?.cancel(); deadline = nil
        channel?.invalidate(); channel = nil
        continuation.resume(returning: result)
    }
}

@main
struct HelperIdentityProbeMain {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 2 else { exit(64) }
        do {
            let result = try await IdentityProbe().run(team: CommandLine.arguments[1])
            print("identity_probe=" + result + "; request=hello_only; route_writes=NONE")
            // A transport error is not by itself proof of a signature rejection.
            print("signature_rejection=REQUIRES_SYSTEM_LOG_AND_VALID_CLIENT_CONTROL")
            if result == "UNEXPECTED_ACCEPTANCE" { exit(1) }
        } catch { print("identity_probe=setup_failed; route_writes=NONE"); exit(2) }
    }
}
