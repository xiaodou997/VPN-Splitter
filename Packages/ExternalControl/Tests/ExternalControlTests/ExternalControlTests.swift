// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import ExternalControl

// These are explicit route/clock/console doubles. No native socket or journal is used.
private final class World: @unchecked Sendable {
    private let lock = NSLock()
    private var time = 100.0
    private var permitted: UInt32 = 501
    private var counts: [String: Int] = [:]
    func now() -> Double { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: Double) { lock.lock(); time += seconds; lock.unlock() }
    func allow(_ uid: UInt32) { lock.lock(); permitted = uid; lock.unlock() }
    func authorized(_ uid: UInt32) -> Bool { lock.lock(); defer { lock.unlock() }; return uid == permitted }
    func note(_ key: String) { lock.lock(); counts[key, default: 0] += 1; lock.unlock() }
    func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key, default: 0] }
}
private final class Lease: ExternalControlledLease {
    let world: World
    let unsafeStop: Bool
    let failingPoll: Bool
    var result = ExternalControlResult(.prepared)
    var proposals: [ExternalControlProposal] {
        [.init(destination: "198.51.100.7/32", gateway: "192.0.2.1", interface: "en7", disposition: "wouldAdd")]
    }
    init(_ world: World, unsafeStop: Bool = false, failingPoll: Bool = false) {
        self.world = world; self.unsafeStop = unsafeStop; self.failingPoll = failingPoll; world.note("prepare")
    }
    func start() { world.note("start"); result = .init(.active, owned: 1) }
    func poll() { world.note("poll"); if failingPoll { result = .init(.recoveryRequired, code: "routeUncertain") } }
    func stop() {
        world.note("stop")
        result = unsafeStop || result.state == .recoveryRequired ? .init(.recoveryRequired, code: "routeUncertain") : .init(.closed, comparison: "unchanged")
    }
}
final class ExternalControlTests: XCTestCase, @unchecked Sendable {
    private func service(_ world: World, trial: Bool = true, unsafe: Bool = false, pollFailure: Bool = false) -> ExternalControlService {
        ExternalControlService(allowApply: trial, now: { world.now() }, authorize: { world.authorized($0) },
                               factory: { _, _ in Lease(world, unsafeStop: unsafe, failingPoll: pollFailure) })
    }
    private func prepared(_ service: ExternalControlService, _ peer: ExternalControlPeer) async -> (ExternalControlRequest, ExternalControlReply) {
        _ = await service.handle(.init(.hello), peer: peer)
        let request = ExternalControlRequest(.prepare, instance: service.instance, profile: UUID(), revision: UUID(), rules: "198.51.100.7/32")
        return (request, await service.handle(request, peer: peer))
    }
    private func apply(_ prepare: ExternalControlRequest, _ reply: ExternalControlReply) -> ExternalControlRequest {
        .init(.apply, instance: reply.instance, profile: prepare.profile, revision: prepare.revision, ticket: reply.ticket)
    }
    func testWireRoundTripAndRejectUnknownKeys() throws {
        let value = ExternalControlRequest(.hello)
        XCTAssertEqual(try ExternalControlRequest.decode(value.encoded()).id, value.id)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: value.encoded()) as? [String: Any])
        object["uid"] = 0
        XCTAssertThrowsError(try ExternalControlRequest.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testWireBoundsAndCommandSpecificPayloads() throws {
        for data in [Data(), Data(repeating: 32, count: 16_385), Data("not-json".utf8)] {
            XCTAssertThrowsError(try ExternalControlRequest.decode(data))
        }
        for request in [ExternalControlRequest(.hello, rules: "198.51.100.7"),
                        .init(.status, instance: UUID(), ticket: UUID()), .init(.apply, instance: UUID()),
                        .init(.prepare, instance: UUID(), profile: UUID(), revision: UUID(), rules: "x;sudo cmd")] {
            XCTAssertThrowsError(try ExternalControlRequest.decode(request.encoded()))
        }
    }
    func testTeamRequirementIsExactAndNotCallerData() throws {
        let req = try ExternalControlIdentity.requirement(team: "ABCDE12345", helper: false)
        XCTAssertTrue(req.contains(ExternalControlIdentity.app)); XCTAssertTrue(req.contains("anchor apple generic"))
        XCTAssertTrue(req.contains("get-task-allow")); XCTAssertTrue(req.contains("disable-library-validation"))
        for value in ["", "abcde12345", "ABCDE1234\" or true", "ABCDE123456"] {
            XCTAssertThrowsError(try ExternalControlIdentity.requirement(team: value, helper: true))
        }
    }
    func testHelloRequiresAuthorizedKernelPeer() async {
        let world = World(); let host = service(world)
        for uid: UInt32 in [0, 502] {
            let result = await host.handle(.init(.hello), peer: .init(uid: uid))
            XCTAssertEqual(result.result.code, "authentication")
        }
        XCTAssertEqual(world.count("prepare"), 0)
    }
    func testCannotPrepareBeforeHelloOrWithWrongInstance() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let request = ExternalControlRequest(.prepare, instance: host.instance, profile: UUID(), revision: UUID(), rules: "198.51.100.7")
        let early = await host.handle(request, peer: peer); XCTAssertEqual(early.result.state, .refused)
        _ = await host.handle(.init(.hello), peer: peer)
        var wrong = request; wrong.instance = UUID()
        let result = await host.handle(wrong, peer: peer); XCTAssertEqual(result.result.state, .refused)
        XCTAssertEqual(world.count("prepare"), 0)
    }
    func testPrepareIsReadOnlyAndHasOneShotTicket() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (_, reply) = await prepared(host, peer)
        XCTAssertEqual(reply.result.state, .prepared); XCTAssertNotNil(reply.ticket)
        XCTAssertEqual(reply.proposals.count, 1); XCTAssertEqual(world.count("start"), 0)
    }
    func testReviewBuildCannotApply() async {
        let world = World(); let host = service(world, trial: false); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer)
        let result = await host.handle(apply(request, reply), peer: peer)
        XCTAssertFalse(result.canApply); XCTAssertEqual(result.result.code, "trialDisabled")
        XCTAssertEqual(world.count("start"), 0)
    }
    func testApplyConsumesTicketAndDuplicateRequest() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer); let start = apply(request, reply)
        let active = await host.handle(start, peer: peer); XCTAssertEqual(active.result.state, .active)
        let duplicate = await host.handle(start, peer: peer); XCTAssertEqual(duplicate.result.code, "invalidRequest")
        let reused = await host.handle(apply(request, reply), peer: peer); XCTAssertEqual(reused.result.code, "staleSelection")
        XCTAssertEqual(world.count("start"), 1)
    }
    func testWrongProfileAndRevisionDoNotStart() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer)
        var wrong = apply(request, reply); wrong.revision = UUID()
        let result = await host.handle(wrong, peer: peer); XCTAssertEqual(result.result.code, "staleSelection")
        XCTAssertEqual(world.count("start"), 0)
    }
    func testOtherConnectionCannotApplyOrStopOwner() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501), other = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer)
        let hello = await host.handle(.init(.hello), peer: other); XCTAssertEqual(hello.result.code, "busy")
        _ = await host.handle(.init(.stop, instance: host.instance), peer: other)
        let stolen = await host.handle(apply(request, reply), peer: other); XCTAssertEqual(stolen.result.state, .refused)
        let active = await host.handle(apply(request, reply), peer: peer); XCTAssertEqual(active.result.state, .active)
        XCTAssertEqual(world.count("stop"), 0)
    }
    func testOneGlobalReservationAndSinglePeerIncarnation() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, _) = await prepared(host, peer)
        let forged = ExternalControlPeer(id: peer.id, uid: 501)
        let result = await host.handle(.init(.status, instance: host.instance), peer: forged)
        XCTAssertEqual(result.result.code, "authentication")
        var second = request; second.id = UUID()
        let busy = await host.handle(second, peer: peer); XCTAssertEqual(busy.result.code, "busy")
    }
    func testPreparationExpiresWithoutMutation() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer)
        world.advance(15); await host.tick()
        let stale = await host.handle(apply(request, reply), peer: peer)
        XCTAssertEqual(stale.result.state, .refused); XCTAssertEqual(world.count("start"), 0)
        XCTAssertEqual(world.count("stop"), 0)
    }
    func testDisconnectStopsOwnedSession() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer); _ = await host.handle(apply(request, reply), peer: peer)
        await host.disconnect(peer)
        XCTAssertTrue(peer.cancellation.isCancelled); XCTAssertEqual(world.count("stop"), 1)
    }
    func testImmediateRevocationIsObservedBeforeApply() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer); peer.cancellation.cancel()
        _ = await host.handle(apply(request, reply), peer: peer)
        XCTAssertEqual(world.count("start"), 0)
    }
    func testLostHeartbeatStopsWithoutGuiPolling() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer); _ = await host.handle(apply(request, reply), peer: peer)
        world.advance(10); await host.tick(); XCTAssertEqual(world.count("stop"), 1)
    }
    func testHeartbeatsCannotExtendLease() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer); _ = await host.handle(apply(request, reply), peer: peer)
        for _ in 0..<12 {
            world.advance(5)
            _ = await host.handle(.init(.status, instance: host.instance), peer: peer)
        }
        XCTAssertEqual(world.count("stop"), 1)
    }
    func testConsoleUserChangeAndClockReversalStop() async {
        for reverse in [false, true] {
            let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
            let (request, reply) = await prepared(host, peer); _ = await host.handle(apply(request, reply), peer: peer)
            if reverse { world.advance(-1) } else { world.allow(502) }
            await host.tick(); XCTAssertEqual(world.count("stop"), 1)
        }
    }
    func testUncertainStopBlocksFutureClientsWithoutAdoptingReceipts() async {
        let world = World(); let host = service(world, unsafe: true); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer); _ = await host.handle(apply(request, reply), peer: peer)
        let result = await host.handle(.init(.stop, instance: host.instance), peer: peer)
        XCTAssertEqual(result.result.state, .recoveryRequired)
        await host.disconnect(peer)
        let other = ExternalControlPeer(uid: 501)
        let hello = await host.handle(.init(.hello), peer: other); XCTAssertEqual(hello.result.state, .recoveryRequired)
        XCTAssertEqual(world.count("start"), 1); XCTAssertEqual(world.count("stop"), 1)
    }
    func testNativePollFailureNotConvertedToSuccess() async {
        let world = World(); let host = service(world, pollFailure: true); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer); _ = await host.handle(apply(request, reply), peer: peer)
        await host.tick()
        let result = await host.handle(.init(.status, instance: host.instance), peer: peer)
        XCTAssertEqual(result.result.state, .recoveryRequired)
    }
    func testQuiesceExcludesRacingStartBeforeUnregister() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        _ = await host.handle(.init(.hello), peer: peer)
        let closed = await host.handle(.init(.quiesce, instance: host.instance), peer: peer)
        XCTAssertEqual(closed.result.code, "quiesced")
        let next = await host.handle(.init(.hello), peer: .init(uid: 501))
        XCTAssertEqual(next.result.code, "unavailable"); XCTAssertEqual(world.count("start"), 0)
    }
    func testShutdownAndCleanStopDoNotReactivate() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer); _ = await host.handle(apply(request, reply), peer: peer)
        let stopped = await host.handle(.init(.stop, instance: host.instance), peer: peer)
        XCTAssertEqual(stopped.result.state, .closed); XCTAssertEqual(stopped.result.comparison, "unchanged")
        await host.shutdown()
        let again = await host.handle(apply(request, reply), peer: peer); XCTAssertEqual(again.result.state, .refused)
        XCTAssertEqual(world.count("stop"), 1)
    }
    func testFactoryErrorIsRedactedAndNoMutation() async {
        struct PrivateFailure: Error {}
        let world = World()
        let host = ExternalControlService(allowApply: true, now: { world.now() }, authorize: { _ in true }, factory: { _, _ in throw PrivateFailure() })
        let peer = ExternalControlPeer(uid: 501); let (_, reply) = await prepared(host, peer)
        XCTAssertEqual(reply.result.code, "observationFailed"); XCTAssertEqual(reply.proposals.count, 0)
    }
    func testPersistedRecoveryLatchBlocksBeforeFactoryOrUnregister() async {
        let world = World()
        let host = ExternalControlService(allowApply: true, initialRecovery: true, now: { world.now() },
            authorize: { world.authorized($0) }, factory: { _, _ in Lease(world) })
        let peer = ExternalControlPeer(uid: 501)
        let hello = await host.handle(.init(.hello), peer: peer)
        XCTAssertEqual(hello.result.state, .recoveryRequired)
        let result = await host.handle(.init(.prepare, instance: host.instance, profile: UUID(), revision: UUID(), rules: "198.51.100.7"), peer: peer)
        XCTAssertEqual(result.result.state, .recoveryRequired)
        let unregister = await host.handle(.init(.quiesce, instance: host.instance), peer: peer)
        XCTAssertEqual(unregister.result.state, .recoveryRequired)
        let stopped = await host.handle(.init(.stop, instance: host.instance), peer: peer)
        XCTAssertEqual(stopped.result.state, .recoveryRequired, "no session cannot erase old recovery")
        XCTAssertEqual(world.count("prepare"), 0)
    }
    func testResponseBindingAndBounds() throws {
        let request = ExternalControlRequest(.hello)
        var reply = ExternalControlReply(requestID: request.id, instance: UUID(), canApply: false, result: .init(.idle))
        XCTAssertNoThrow(try ExternalControlReply.decode(reply.encoded(), request: request))
        XCTAssertThrowsError(try ExternalControlReply.decode(reply.encoded(), request: .init(.hello)))
        reply.result.owned = 9
        XCTAssertThrowsError(try ExternalControlReply.decode(reply.encoded(), request: request))
    }
}
