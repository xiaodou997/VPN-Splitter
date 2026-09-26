// SPDX-License-Identifier: MIT
#if os(macOS)
@preconcurrency import Foundation
import Security
import Darwin

// Only bounded NSData and fixed error codes cross XPC. No arbitrary object graph,
// file path, shell command, Keychain lookup method, or serialized listener endpoint.
@objc protocol ManagedCredentialXPC {
    func hello(reply: @escaping @Sendable (Data?, String?) -> Void)
    func stage(_ envelope: Data, reply: @escaping @Sendable (Data?, String?) -> Void)
}

@available(macOS 26.0, *)
struct ManagedNativeIdentity: Sendable {
    let peers: ManagedPeerRequirement
    let group: String
    var service: String { group + ".credentials" }

    static func current(provider: Bool) throws -> Self {
        let bundle = Bundle.main
        guard let app = bundle.object(forInfoDictionaryKey: "VPNManagedAppIdentifier") as? String,
              let ext = bundle.object(forInfoDictionaryKey: "VPNManagedProviderIdentifier") as? String,
              let team = bundle.object(forInfoDictionaryKey: "VPNManagedTeamIdentifier") as? String,
              let group = bundle.object(forInfoDictionaryKey: "VPNManagedAppGroup") as? String,
              let service = bundle.object(forInfoDictionaryKey: "VPNManagedMachService") as? String,
              service == group + ".credentials", group.hasSuffix("." + app + ".managed"),
              group.utf8.count <= 240,
              group.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 }),
              bundle.bundleIdentifier == (provider ? ext : app),
              provider ? (getuid() == 0 && geteuid() == 0) : (getuid() > 0 && geteuid() == getuid()),
              bundle.bundleURL.pathExtension == (provider ? "systemextension" : "app") else {
            throw ManagedTransferError.invalidIdentity
        }
        let peers = try ManagedPeerRequirement(appID: app, providerID: ext, teamID: team)
        // Validate syntax before passing to NSXPC setters (malformed strings raise ObjC exceptions).
        for role in [false, true] { _ = try requirement(peers.requirement(provider: role)) }
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(rawValue: 0), &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), try requirement(peers.requirement(provider: provider))) == errSecSuccess else {
            throw ManagedTransferError.invalidIdentity
        }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode else { throw ManagedTransferError.invalidIdentity }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let signing = info as? [String: Any],
              let entitlements = signing[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String],
              groups.contains(group) else { throw ManagedTransferError.invalidIdentity }
        return Self(peers: peers, group: group)
    }
    private static func requirement(_ text: String) throws -> SecRequirement {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, SecCSFlags(rawValue: 0), &requirement) == errSecSuccess,
              let requirement else { throw ManagedTransferError.invalidIdentity }
        return requirement
    }
}

// Lock protects only liveness across Foundation callbacks. No secrets are stored here.
private final class ManagedXPCLiveness: @unchecked Sendable {
    private let lock = NSLock()
    private var live = true
    func isLive() -> Bool { lock.lock(); defer { lock.unlock() }; return live }
    func close() { lock.lock(); live = false; lock.unlock() }
}

private final class ManagedXPCExport: NSObject, ManagedCredentialXPC, @unchecked Sendable {
    let id: UUID
    let uid: UInt32
    let broker: ManagedDeliveryBroker
    let alive: ManagedXPCLiveness
    init(id: UUID, uid: UInt32, broker: ManagedDeliveryBroker, alive: ManagedXPCLiveness) {
        self.id = id; self.uid = uid; self.broker = broker; self.alive = alive
    }
    func hello(reply: @escaping @Sendable (Data?, String?) -> Void) {
        Task { @MainActor in
            guard alive.isLive() else { reply(nil, ManagedTransferError.connectionClosed.rawValue); return }
            do {
                let challenge = try broker.open(connection: id, kernelUID: uid, isLive: { [alive] in alive.isLive() })
                reply(try challenge.encoded(), nil)
            } catch { reply(nil, Self.code(error)) }
        }
    }
    func stage(_ envelope: Data, reply: @escaping @Sendable (Data?, String?) -> Void) {
        // Foundation has already decoded NSData, but avoid parsing/retaining oversized payloads.
        guard envelope.count <= ManagedDeliveryEnvelope.maximumBytes else {
            alive.close(); reply(nil, ManagedTransferError.invalidMessage.rawValue); return
        }
        Task { @MainActor in
            guard alive.isLive() else { broker.close(id); reply(nil, ManagedTransferError.connectionClosed.rawValue); return }
            do {
                try broker.stage(envelope, connection: id)
                guard alive.isLive() else { broker.close(id); throw ManagedTransferError.connectionClosed }
                reply(Data("staged-v1".utf8), nil)
            } catch { broker.close(id); reply(nil, Self.code(error)) }
        }
    }
    private static func code(_ error: Error) -> String {
        (error as? ManagedTransferError ?? .unavailable).rawValue
    }
}

@available(macOS 26.0, *)
private final class ManagedXPCListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let broker: ManagedDeliveryBroker
    let identity: ManagedNativeIdentity
    let listener: NSXPCListener
    private let lock = NSLock()
    private var connections: [UUID: NSXPCConnection] = [:]

    init(identity: ManagedNativeIdentity, broker: ManagedDeliveryBroker) {
        self.identity = identity; self.broker = broker
        listener = NSXPCListener(machServiceName: identity.service)
        super.init()
        // This is the actual platform peer gate, BEFORE listening/accepting messages.
        listener.setConnectionCodeSigningRequirement(identity.peers.requirement(provider: false))
        listener.delegate = self
    }
    func start() { listener.resume() }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let uid = connection.effectiveUserIdentifier // Kernel-supplied, not a PID lookup or wire field.
        guard uid > 0 else { return false }
        let id = UUID()
        lock.lock()
        guard connections.count < 8 else { lock.unlock(); return false }
        connections[id] = connection
        lock.unlock()
        let alive = ManagedXPCLiveness()
        // The listener applies its requirement; do not set it twice on this connection.
        connection.exportedInterface = NSXPCInterface(with: ManagedCredentialXPC.self)
        connection.exportedObject = ManagedXPCExport(id: id, uid: uid, broker: broker, alive: alive)
        let closed: @Sendable () -> Void = { [weak self, broker] in
            alive.close()
            self?.remove(id)
            Task { @MainActor in broker.close(id) }
        }
        connection.invalidationHandler = closed
        connection.interruptionHandler = { [weak connection] in closed(); connection?.invalidate() }
        connection.resume()
        // Also bound clients that connect but never send hello. No permanent secret inbox.
        Task { @MainActor [weak connection] in
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            // Only an already consumed, explicit run is promoted beyond staging expiry.
            // The kernel connection remains the revocation source; no timer renews it.
            if !broker.hasActiveConnection(id) { alive.close(); broker.close(id); connection?.invalidate() }
        }
        return true
    }
    func end(_ id: UUID) {
        lock.lock(); let connection = connections.removeValue(forKey: id); lock.unlock()
        connection?.invalidate()
    }
    private func remove(_ id: UUID) { lock.lock(); connections.removeValue(forKey: id); lock.unlock() }
}

/// Installed by the system-extension executable, not by LocalDev or a compile probe.
/// No Keychain factory is used in this root process and no file fallback exists.
@available(macOS 26.0, *)
@MainActor
public final class ManagedExtensionRuntime {
    public private(set) static var shared: ManagedExtensionRuntime?
    private let broker = ManagedDeliveryBroker()
    private var listener: ManagedXPCListener?
    private init() {}
    public static func install() throws {
        guard shared == nil else { return }
        let identity = try ManagedNativeIdentity.current(provider: true)
        let runtime = ManagedExtensionRuntime()
        let listener = ManagedXPCListener(identity: identity, broker: runtime.broker)
        runtime.listener = listener
        shared = runtime
        listener.start()
        Task { @MainActor [weak runtime] in
            while let runtime {
                runtime.broker.purge()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }
    public func consume(_ launch: CheckedManagedLaunch, ownerUID: UInt32) throws -> ManagedReceivedConfiguration {
        let received = try broker.consume(launch, ownerUID: ownerUID)
        if received.purpose == .run, Bundle.main.object(forInfoDictionaryKey: "VPNPacketFlowRuntime") as? Bool != true {
            received.authorization?.invalidate(); finishRun(launch.request.attemptID)
            throw ManagedTransferError.unavailable
        }
        return received
    }
    public func finishRun(_ attempt: UUID) {
        if let id = broker.endRun(attempt) { listener?.end(id) }
    }
    public func discard() { broker.discard() }
}

/// Exactly one awaited reply with an independent monotonic deadline. A timer delivered
/// late cannot turn a late reply into success. No cancellation of an OS write is implied.
@MainActor
final class ManagedReply<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private let deadline = ProcessInfo.processInfo.systemUptime + 5
    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
        Task { @MainActor [self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self.finish(.failure(ManagedTransferError.expired))
        }
    }
    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        if ProcessInfo.processInfo.systemUptime >= deadline {
            continuation.resume(throwing: ManagedTransferError.expired)
        } else { continuation.resume(with: result) }
    }
}

@available(macOS 26.0, *)
@MainActor
final class ManagedXPCClient {
    private let connection: NSXPCConnection
    private var pending: ManagedReply<Data>?
    private var closed = false
    init(identity: ManagedNativeIdentity) {
        // Privileged lookup prevents a per-user Mach service shadowing the system service.
        connection = NSXPCConnection(machServiceName: identity.service, options: .privileged)
        connection.setCodeSigningRequirement(identity.peers.requirement(provider: true))
        connection.remoteObjectInterface = NSXPCInterface(with: ManagedCredentialXPC.self)
        connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.close() } }
        connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.close() } }
        connection.resume()
    }
    func hello(ownerUID: UInt32) async throws -> ManagedDeliveryChallenge {
        let data = try await call { proxy, reply in proxy.hello(reply: reply) }
        guard connection.effectiveUserIdentifier == 0 else { close(); throw ManagedTransferError.invalidIdentity }
        let challenge = try ManagedDeliveryChallenge(data: data)
        guard challenge.ownerUID == ownerUID else { close(); throw ManagedTransferError.invalidIdentity }
        return challenge
    }
    func stage(_ envelope: ManagedDeliveryEnvelope) async throws {
        let bytes = try envelope.encodedForAuthenticatedXPC()
        let reply = try await call { proxy, done in proxy.stage(bytes, reply: done) }
        guard reply == Data("staged-v1".utf8) else { close(); throw ManagedTransferError.invalidMessage }
    }
    func close() {
        guard !closed else { return }
        closed = true
        pending?.finish(.failure(ManagedTransferError.connectionClosed)); pending = nil
        connection.invalidate()
    }
    private func call(_ invoke: (ManagedCredentialXPC, @escaping @Sendable (Data?, String?) -> Void) -> Void) async throws -> Data {
        guard !closed, pending == nil else { throw ManagedTransferError.connectionClosed }
        defer { pending = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let reply = ManagedReply<Data>(continuation); pending = reply
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                Task { @MainActor in reply.finish(.failure(ManagedTransferError.connectionClosed)) }
            }) as? ManagedCredentialXPC else {
                reply.finish(.failure(ManagedTransferError.connectionClosed)); return
            }
            invoke(proxy) { data, error in
                Task { @MainActor in
                    if let error { reply.finish(.failure(ManagedTransferError(rawValue: error) ?? .unavailable)) }
                    else if let data, data.count <= 1024 { reply.finish(.success(data)) }
                    else { reply.finish(.failure(ManagedTransferError.invalidMessage)) }
                }
            }
        }
    }
}
#endif
