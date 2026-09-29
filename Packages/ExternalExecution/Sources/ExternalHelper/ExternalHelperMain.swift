// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import Darwin
import SystemConfiguration
import ExternalControl
import CExternalRoute

// Presence is a recovery latch, never ownership. Do not create, read payloads,
// unlink or adopt old records on startup; unsafe paths are conservatively blocked.
private func pendingRecovery() -> Bool {
    let path = "/private/var/run/io.github.xiaodou997.VPNSplitter.ExternalLease"
    let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if fd < 0 { return errno != ENOENT }
    defer { close(fd) }
    var directory = stat(), marker = stat()
    guard fstat(fd, &directory) == 0, directory.st_uid == 0,
          directory.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR), directory.st_mode & 0o777 == 0o700 else { return true }
    if fstatat(fd, "active", &marker, AT_SYMLINK_NOFOLLOW) == 0 { return true }
    return errno != ENOENT
}

private func consoleAllows(_ uid: UInt32) -> Bool {
    var current: uid_t = 0
    var group: gid_t = 0
    guard SCDynamicStoreCopyConsoleUser(nil, &current, &group) != nil else { return false }
    return uid != 0 && current == uid
}

/// Immutable endpoint except for a lock-protected one-in-flight counter. Peer UID
/// is taken from NSXPCConnection by the listener, not from the request payload.
private final class ExternalHelperEndpoint: NSObject, ExternalHelperXPC, @unchecked Sendable {
    let peer: ExternalControlPeer
    let service: ExternalControlService
    private let lock = NSLock()
    private var inFlight = false
    init(peer: ExternalControlPeer, service: ExternalControlService) { self.peer = peer; self.service = service }
    func request(_ data: Data, reply: @escaping @Sendable (Data) -> Void) {
        guard let request = try? ExternalControlRequest.decode(data) else { reply(Data()); return }
        // Revocation is visible even while the actor is inside a bounded native call.
        if request.action == .stop, request.instance == service.instance { peer.cancellation.cancel() }
        lock.lock()
        let accepted = !inFlight
        if accepted { inFlight = true }
        lock.unlock()
        guard accepted else { reply(Data()); return }
        Task { [self] in
            let response = await service.handle(request, peer: peer)
            finished()
            reply(response.encoded())
        }
    }
    private func finished() { lock.lock(); inFlight = false; lock.unlock() }
}

/// NSXPC callbacks may run concurrently. The lock protects only the bounded
/// connection table. The actual route/session objects live solely on the actor.
private final class ExternalHelperListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [UUID: (NSXPCConnection, ExternalControlPeer, Double)] = [:]
    let service: ExternalControlService
    let requirement: String
    init(service: ExternalControlService, requirement: String) { self.service = service; self.requirement = requirement }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection channel: NSXPCConnection) -> Bool {
        let uid = channel.effectiveUserIdentifier
        guard consoleAllows(uid) else { return false }
        let peer = ExternalControlPeer(uid: uid)
        lock.lock()
        guard connections.count < 8 else { lock.unlock(); return false }
        connections[peer.id] = (channel, peer, er_continuous_seconds()); lock.unlock()
        channel.setCodeSigningRequirement(requirement)
        channel.exportedInterface = NSXPCInterface(with: ExternalHelperXPC.self)
        channel.exportedObject = ExternalHelperEndpoint(peer: peer, service: service)
        channel.interruptionHandler = { [weak self] in self?.close(peer) }
        channel.invalidationHandler = { [weak self] in self?.close(peer) }
        channel.resume(); return true
    }
    func close(_ peer: ExternalControlPeer) {
        peer.cancellation.cancel()
        lock.lock(); let old = connections.removeValue(forKey: peer.id); lock.unlock()
        old?.0.invalidate()
        Task { await service.disconnect(peer) }
    }
    func expireChannels() {
        let now = er_continuous_seconds()
        lock.lock(); let values = Array(connections.values); lock.unlock()
        for (_, peer, made) in values where now < made || now - made >= 120 { close(peer) }
    }
    func revokeAll() {
        lock.lock(); let values = Array(connections.values); lock.unlock()
        for (_, peer, _) in values { close(peer) }
    }
}

@main struct ExternalHelperMain {
    static func main() {
        do {
            guard CommandLine.arguments.count == 1 else { exit(64) }
            let team = try ExternalControlIdentity.currentTeam(helper: true)
            #if EXTERNAL_HELPER_ROUTE_TRIAL
            let enabled = true
            #else
            let enabled = false
            #endif
            let service = ExternalControlService(allowApply: enabled, initialRecovery: pendingRecovery(), now: { er_continuous_seconds() },
                authorize: { consoleAllows($0) }, factory: { try ExternalHelperLease(rules: $0, cancellation: $1) })
            let requirement = try ExternalControlIdentity.requirement(team: team, helper: false)
            let delegate = ExternalHelperListener(service: service, requirement: requirement)
            let listener = NSXPCListener(machServiceName: ExternalControlIdentity.service)
            listener.setConnectionCodeSigningRequirement(requirement)
            listener.delegate = delegate; listener.resume()
            // One sequential service-owned monitor. GUI heartbeats do not renew 60s.
            let monitor = Task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { break }
                    delegate.expireChannels()
                    await service.tick()
                }
            }
            signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN)
            let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
            let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
            let stop: @Sendable () -> Void = {
                delegate.revokeAll(); monitor.cancel()
                Task { await service.shutdown(); exit(0) }
            }
            term.setEventHandler(handler: stop); interrupt.setEventHandler(handler: stop)
            term.resume(); interrupt.resume()
            withExtendedLifetime((delegate, listener, term, interrupt, monitor)) { dispatchMain() }
        } catch { print("External Helper refused identity/startup; no session started."); exit(77) }
    }
}
#else
import Foundation
@main struct ExternalHelperUnsupported { static func main() { print("External Helper requires signed macOS 26+; no networking performed.") } }
#endif
