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
    // Protocol v2: every request carries a per-peer consecutive sequence. Each test
    // instance numbers each peer's chain independently, like the real client does.
    private var sequences: [UUID: UInt64] = [:]
    private func sequenced(_ request: ExternalControlRequest, _ peer: ExternalControlPeer) -> ExternalControlRequest {
        let next = sequences[peer.id, default: 0] + 1
        sequences[peer.id] = next
        var value = request; value.sequence = next; return value
    }
    private func service(_ world: World, trial: Bool = true, unsafe: Bool = false, pollFailure: Bool = false) -> ExternalControlService {
        ExternalControlService(allowApply: trial, now: { world.now() }, authorize: { world.authorized($0) },
                               factory: { _, _ in Lease(world, unsafeStop: unsafe, failingPoll: pollFailure) })
    }
    private func prepared(_ service: ExternalControlService, _ peer: ExternalControlPeer) async -> (ExternalControlRequest, ExternalControlReply) {
        _ = await service.handle(sequenced(.init(.hello), peer), peer: peer)
        let request = sequenced(ExternalControlRequest(.prepare, instance: service.instance, profile: UUID(), revision: UUID(), rules: "198.51.100.7/32"), peer)
        return (request, await service.handle(request, peer: peer))
    }
    private func apply(_ prepare: ExternalControlRequest, _ reply: ExternalControlReply) -> ExternalControlRequest {
        .init(.apply, instance: reply.instance, profile: prepare.profile, revision: prepare.revision, ticket: reply.ticket)
    }
    func testExpiredIdlePeerNeedsFreshAuthenticatedHello() async {
        let world = World(); let host = service(world, trial: false)
        let old = ExternalControlPeer(uid: 501)
        _ = await host.handle(sequenced(.init(.hello), old), peer: old)
        let first = await host.handle(sequenced(.init(.recoveryAudit, instance: host.instance), old), peer: old)
        XCTAssertEqual(first.result.code, "noRecovery")
        world.advance(31)
        let expired = await host.handle(sequenced(.init(.recoveryAudit, instance: host.instance), old), peer: old)
        XCTAssertEqual(expired.result.code, "authentication")
        let fresh = ExternalControlPeer(uid: 501)
        let hello = await host.handle(sequenced(.init(.hello), fresh), peer: fresh)
        XCTAssertEqual(hello.result.state, .idle)
        let second = await host.handle(sequenced(.init(.recoveryAudit, instance: host.instance), fresh), peer: fresh)
        XCTAssertEqual(second.result.code, "noRecovery")
        XCTAssertEqual(world.count("prepare"), 0)
        XCTAssertEqual(world.count("start"), 0)
    }
    func testWireRoundTripAndRejectUnknownKeys() throws {
        var value = ExternalControlRequest(.hello); value.sequence = 1
        XCTAssertEqual(try ExternalControlRequest.decode(value.encoded()).id, value.id)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: value.encoded()) as? [String: Any])
        object["uid"] = 0
        XCTAssertThrowsError(try ExternalControlRequest.decode(JSONSerialization.data(withJSONObject: object)))
    }
    func testWireV2RequiresCurrentSchemaAndSequence() throws {
        var value = ExternalControlRequest(.hello); value.sequence = 1
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: value.encoded()) as? [String: Any])
        object["schema"] = 1
        let legacy = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try ExternalControlRequest.decode(legacy))
        XCTAssertEqual(ExternalControlRequest.protocolProbe(legacy)?.schema, 1)
        XCTAssertEqual(ExternalControlRequest.protocolProbe(legacy)?.id, value.id)
        value.sequence = nil
        XCTAssertThrowsError(try ExternalControlRequest.decode(value.encoded()))
        value.sequence = 0
        XCTAssertThrowsError(try ExternalControlRequest.decode(value.encoded()))
        XCTAssertNil(ExternalControlRequest.protocolProbe(Data("not-json".utf8)))
    }
    func testWireBoundsAndCommandSpecificPayloads() throws {
        for data in [Data(), Data(repeating: 32, count: 16_385), Data("not-json".utf8)] {
            XCTAssertThrowsError(try ExternalControlRequest.decode(data))
        }
        for request in [ExternalControlRequest(.hello, rules: "198.51.100.7"),
                        .init(.status, instance: UUID(), ticket: UUID()), .init(.apply, instance: UUID()),
                        .init(.prepare, instance: UUID(), profile: UUID(), revision: UUID(), rules: "x;sudo cmd")] {
            var sequencedRequest = request; sequencedRequest.sequence = 1
            XCTAssertThrowsError(try ExternalControlRequest.decode(sequencedRequest.encoded()))
        }
    }
    func testWirePrepareAcceptsResolvableDomainLinesOnly() throws {
        for rules in ["DOMAIN,example.com", "DOMAIN-SUFFIX,example.com\n198.51.100.7/32",
                      "DOMAIN,a-b.c-d.example.com", "198.51.100.7/32"] {
            var request = ExternalControlRequest(.prepare, instance: UUID(), profile: UUID(), revision: UUID(), rules: rules)
            request.sequence = 1
            XCTAssertNoThrow(try ExternalControlRequest.decode(request.encoded()))
        }
        // Flow-only kinds, malformed hostnames and non-canonical lines never pass the envelope.
        for rules in ["DOMAIN-KEYWORD,google", "APPLICATION,Telegram", "APP,Telegram", "domain,example.com",
                      "DOMAIN,", "DOMAIN-SUFFIX,", "DOMAIN,UPPER.com", "DOMAIN,bad_under.com",
                      "DOMAIN-SUFFIX,*.example.com", "DOMAIN,example.com\n", "DOMAIN,exam ple.com"] {
            var request = ExternalControlRequest(.prepare, instance: UUID(), profile: UUID(), revision: UUID(), rules: rules)
            request.sequence = 1
            XCTAssertThrowsError(try ExternalControlRequest.decode(request.encoded()))
        }
    }
    func testReplyProposalSourceDomainIsOptionalAndBounded() throws {
        var request = ExternalControlRequest(.status, instance: UUID()); request.sequence = 1
        let reply = ExternalControlReply(requestID: request.id, instance: request.instance!, canApply: true,
                                         result: .init(.prepared))
        var valued = reply
        valued.proposals = [.init(destination: "203.0.113.9/32", gateway: "192.0.2.1", interface: "en7",
                                  disposition: "wouldAdd", sourceDomain: "example.com")]
        let decoded = try ExternalControlReply.decode(valued.encoded(), request: request)
        XCTAssertEqual(decoded.proposals.first?.sourceDomain, "example.com")
        // A peer built before this field existed simply omits the key; schema stays 2.
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: valued.encoded()) as? [String: Any])
        var proposals = try XCTUnwrap(object["proposals"] as? [[String: Any]])
        proposals[0].removeValue(forKey: "sourceDomain")
        object["proposals"] = proposals
        let legacy = try ExternalControlReply.decode(JSONSerialization.data(withJSONObject: object), request: request)
        XCTAssertNil(legacy.proposals.first?.sourceDomain)
        var oversized = reply
        oversized.proposals = [.init(destination: "203.0.113.9/32", gateway: "192.0.2.1", interface: "en7",
                                     disposition: "wouldAdd", sourceDomain: String(repeating: "a", count: 281))]
        XCTAssertThrowsError(try ExternalControlReply.decode(oversized.encoded(), request: request))
    }
    func testPrepareWithDomainRulesReachesTheLeaseFactory() async {
        let world = World(); let host = service(world)
        let peer = ExternalControlPeer(uid: 501)
        _ = await host.handle(sequenced(.init(.hello), peer), peer: peer)
        let request = sequenced(ExternalControlRequest(.prepare, instance: host.instance,
            profile: UUID(), revision: UUID(), rules: "DOMAIN,example.com\n198.51.100.7/32"), peer)
        let reply = await host.handle(request, peer: peer)
        XCTAssertEqual(world.count("prepare"), 1)
        XCTAssertEqual(reply.result.state, .prepared)
        XCTAssertEqual(reply.proposals.first?.sourceDomain, nil) // The double has no resolver.
    }
    func testTeamRequirementIsExactAndNotCallerData() throws {
        let req = try ExternalControlIdentity.requirement(team: "ABCDE12345", helper: false)
        XCTAssertTrue(req.contains(ExternalControlIdentity.app)); XCTAssertTrue(req.contains("anchor apple generic"))
        XCTAssertTrue(req.contains("get-task-allow")); XCTAssertTrue(req.contains("disable-library-validation"))
        for value in ["", "abcde12345", "ABCDE1234\" or true", "ABCDE123456"] {
            XCTAssertThrowsError(try ExternalControlIdentity.requirement(team: value, helper: true))
        }
    }
    func testSustainedSessionPastLegacyLimitsAndReplayCannotRenew() async {
        let world = World()
        let host = ExternalControlService(allowApply: true, sustained: true,
            now: { world.now() }, authorize: { world.authorized($0) },
            factory: { _, _ in Lease(world) })
        let peer = ExternalControlPeer(uid: 501)
        var hello = ExternalControlRequest(.hello); hello.sequence = 1
        let connected = await host.handle(hello, peer: peer)
        XCTAssertEqual(connected.result.state, .idle)
        var prepare = ExternalControlRequest(.prepare, instance: host.instance,
            profile: UUID(), revision: UUID(), rules: "198.51.100.7/32")
        prepare.sequence = 2
        let proposal = await host.handle(prepare, peer: peer)
        var start = apply(prepare, proposal); start.sequence = 3
        let active = await host.handle(start, peer: peer)
        XCTAssertEqual(active.result.state, .active)
        var last = ExternalControlRequest(.status, instance: host.instance)
        for sequence in UInt64(4)...700 {
            world.advance(1)
            last = .init(.status, instance: host.instance); last.sequence = sequence
            let status = await host.handle(last, peer: peer)
            XCTAssertEqual(status.result.state, .active)
        }
        let kept = await host.keepsActiveChannel(peer)
        XCTAssertTrue(kept)
        world.advance(9)
        let replay = await host.handle(last, peer: peer)
        XCTAssertEqual(replay.result.code, "invalidRequest")
        world.advance(1); await host.tick()
        XCTAssertEqual(world.count("stop"), 1)
        let retained = await host.keepsActiveChannel(peer)
        XCTAssertFalse(retained)
    }
    func testSustainedStopHasBoundedTerminalDeliveryGrace() async {
        let world = World()
        let host = ExternalControlService(allowApply: true, sustained: true,
            now: { world.now() }, authorize: { world.authorized($0) }, factory: { _, _ in Lease(world) })
        let peer = ExternalControlPeer(uid: 501)
        var hello = ExternalControlRequest(.hello); hello.sequence = 1
        _ = await host.handle(hello, peer: peer)
        var prepare = ExternalControlRequest(.prepare, instance: host.instance,
            profile: UUID(), revision: UUID(), rules: "198.51.100.7/32"); prepare.sequence = 2
        let proposal = await host.handle(prepare, peer: peer)
        var start = apply(prepare, proposal); start.sequence = 3
        _ = await host.handle(start, peer: peer)
        for seq in UInt64(4)...140 {
            world.advance(1)
            var status = ExternalControlRequest(.status, instance: host.instance); status.sequence = seq
            _ = await host.handle(status, peer: peer)
        }
        var stop = ExternalControlRequest(.stop, instance: host.instance); stop.sequence = 141
        let result = await host.handle(stop, peer: peer)
        XCTAssertEqual(result.result.state, .closed)
        let grace = await host.keepsActiveChannel(peer)
        XCTAssertTrue(grace)
        XCTAssertEqual(world.count("stop"), 1)
        world.advance(10)
        let expired = await host.keepsActiveChannel(peer)
        XCTAssertFalse(expired)
    }
    func testSequenceIsMandatoryAndConsecutivePerPeer() async {
        let world = World(); let host = service(world)
        let peer = ExternalControlPeer(uid: 501)
        let legacy = await host.handle(.init(.hello), peer: peer)
        XCTAssertEqual(legacy.result.code, "invalidRequest")
        _ = await host.handle(sequenced(.init(.hello), peer), peer: peer)
        var skipped = ExternalControlRequest(.status, instance: host.instance); skipped.sequence = 3
        let outOfOrder = await host.handle(skipped, peer: peer)
        XCTAssertEqual(outOfOrder.result.code, "invalidRequest")
        let replayed = await host.handle(sequenced(.init(.status, instance: host.instance), peer), peer: peer)
        XCTAssertEqual(replayed.result.state, .idle)
    }
    func testHelloRequiresAuthorizedKernelPeer() async {
        let world = World(); let host = service(world)
        for uid: UInt32 in [0, 502] {
            let peer = ExternalControlPeer(uid: uid)
            let result = await host.handle(sequenced(.init(.hello), peer), peer: peer)
            XCTAssertEqual(result.result.code, "authentication")
        }
        XCTAssertEqual(world.count("prepare"), 0)
    }
    func testCannotPrepareBeforeHelloOrWithWrongInstance() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let request = sequenced(ExternalControlRequest(.prepare, instance: host.instance, profile: UUID(), revision: UUID(), rules: "198.51.100.7"), peer)
        let early = await host.handle(request, peer: peer); XCTAssertEqual(early.result.state, .refused)
        _ = await host.handle(sequenced(.init(.hello), peer), peer: peer)
        var wrong = sequenced(request, peer); wrong.instance = UUID()
        let result = await host.handle(wrong, peer: peer); XCTAssertEqual(result.result.state, .refused)
        XCTAssertEqual(world.count("prepare"), 0)
    }
    func testRecoveryCannotReportIdleWhileReservationOrLeaseExists() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer)
        for active in [false, true] {
            if active { _ = await host.handle(sequenced(apply(request, reply), peer), peer: peer) }
            for action: ExternalControlAction in [.recoveryAudit, .recoveryClear] {
                let response = await host.handle(sequenced(.init(action, instance: host.instance), peer), peer: peer)
                XCTAssertEqual(response.result.state, .refused)
                XCTAssertEqual(response.result.code, "busy")
            }
        }
        XCTAssertEqual(world.count("stop"), 0)
        await host.disconnect(peer)
        let fresh = ExternalControlPeer(uid: 501)
        _ = await host.handle(sequenced(.init(.hello), fresh), peer: fresh)
        let audit = await host.handle(sequenced(.init(.recoveryAudit, instance: host.instance), fresh), peer: fresh)
        XCTAssertEqual(audit.result.code, "noRecovery")
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
        let result = await host.handle(sequenced(apply(request, reply), peer), peer: peer)
        XCTAssertFalse(result.canApply); XCTAssertEqual(result.result.code, "trialDisabled")
        XCTAssertEqual(world.count("start"), 0)
    }
    func testApplyConsumesTicketAndDuplicateRequest() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer); let start = sequenced(apply(request, reply), peer)
        let active = await host.handle(start, peer: peer); XCTAssertEqual(active.result.state, .active)
        let duplicate = await host.handle(start, peer: peer); XCTAssertEqual(duplicate.result.code, "invalidRequest")
        let reused = await host.handle(sequenced(apply(request, reply), peer), peer: peer)
        XCTAssertEqual(reused.result.code, "staleSelection")
        XCTAssertEqual(world.count("start"), 1)
    }
    func testWrongProfileAndRevisionDoNotStart() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer)
        var wrong = sequenced(apply(request, reply), peer); wrong.revision = UUID()
        let result = await host.handle(wrong, peer: peer); XCTAssertEqual(result.result.code, "staleSelection")
        XCTAssertEqual(world.count("start"), 0)
    }
    func testOtherConnectionCannotApplyOrStopOwner() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501), other = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer)
        let hello = await host.handle(sequenced(.init(.hello), other), peer: other); XCTAssertEqual(hello.result.code, "busy")
        _ = await host.handle(sequenced(.init(.stop, instance: host.instance), other), peer: other)
        let stolen = await host.handle(sequenced(apply(request, reply), other), peer: other); XCTAssertEqual(stolen.result.state, .refused)
        let active = await host.handle(sequenced(apply(request, reply), peer), peer: peer); XCTAssertEqual(active.result.state, .active)
        XCTAssertEqual(world.count("stop"), 0)
    }
    func testOneGlobalReservationAndSinglePeerIncarnation() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, _) = await prepared(host, peer)
        let forged = ExternalControlPeer(id: peer.id, uid: 501)
        // Authentication fires before the sequence check; keep the forged request off
        // the shared per-peer counter so the real peer's chain stays consecutive.
        var forgedRequest = ExternalControlRequest(.status, instance: host.instance); forgedRequest.sequence = 99
        let result = await host.handle(forgedRequest, peer: forged)
        XCTAssertEqual(result.result.code, "authentication")
        var replacement = request; replacement.id = UUID()
        let busy = await host.handle(sequenced(replacement, peer), peer: peer); XCTAssertEqual(busy.result.code, "busy")
    }
    func testPreparationExpiresWithoutMutation() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer)
        world.advance(15); await host.tick()
        let stale = await host.handle(sequenced(apply(request, reply), peer), peer: peer)
        XCTAssertEqual(stale.result.state, .refused); XCTAssertEqual(world.count("start"), 0)
        XCTAssertEqual(world.count("stop"), 0)
    }
    func testDisconnectStopsOwnedSession() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer); _ = await host.handle(sequenced(apply(request, reply), peer), peer: peer)
        await host.disconnect(peer)
        XCTAssertTrue(peer.cancellation.isCancelled); XCTAssertEqual(world.count("stop"), 1)
    }
    func testImmediateRevocationIsObservedBeforeApply() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer); peer.cancellation.cancel()
        _ = await host.handle(sequenced(apply(request, reply), peer), peer: peer)
        XCTAssertEqual(world.count("start"), 0)
    }
    func testLostHeartbeatStopsWithoutGuiPolling() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer); _ = await host.handle(sequenced(apply(request, reply), peer), peer: peer)
        world.advance(10); await host.tick(); XCTAssertEqual(world.count("stop"), 1)
    }
    func testHeartbeatsCannotExtendLease() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer); _ = await host.handle(sequenced(apply(request, reply), peer), peer: peer)
        for _ in 0..<12 {
            world.advance(5)
            _ = await host.handle(sequenced(.init(.status, instance: host.instance), peer), peer: peer)
        }
        XCTAssertEqual(world.count("stop"), 1)
    }
    func testConsoleUserChangeAndClockReversalStop() async {
        for reverse in [false, true] {
            let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
            let (request, reply) = await prepared(host, peer); _ = await host.handle(sequenced(apply(request, reply), peer), peer: peer)
            if reverse { world.advance(-1) } else { world.allow(502) }
            await host.tick(); XCTAssertEqual(world.count("stop"), 1)
        }
    }
    func testUncertainStopBlocksFutureClientsWithoutAdoptingReceipts() async {
        let world = World(); let host = service(world, unsafe: true); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer); _ = await host.handle(sequenced(apply(request, reply), peer), peer: peer)
        let result = await host.handle(sequenced(.init(.stop, instance: host.instance), peer), peer: peer)
        XCTAssertEqual(result.result.state, .recoveryRequired)
        await host.disconnect(peer)
        let other = ExternalControlPeer(uid: 501)
        let hello = await host.handle(sequenced(.init(.hello), other), peer: other); XCTAssertEqual(hello.result.state, .recoveryRequired)
        XCTAssertEqual(world.count("start"), 1); XCTAssertEqual(world.count("stop"), 1)
    }
    func testNativePollFailureNotConvertedToSuccess() async {
        let world = World(); let host = service(world, pollFailure: true); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer); _ = await host.handle(sequenced(apply(request, reply), peer), peer: peer)
        await host.tick()
        let result = await host.handle(sequenced(.init(.status, instance: host.instance), peer), peer: peer)
        XCTAssertEqual(result.result.state, .recoveryRequired)
    }
    func testQuiesceExcludesRacingStartBeforeUnregister() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        _ = await host.handle(sequenced(.init(.hello), peer), peer: peer)
        let closed = await host.handle(sequenced(.init(.quiesce, instance: host.instance), peer), peer: peer)
        XCTAssertEqual(closed.result.code, "quiesced")
        let next = ExternalControlPeer(uid: 501)
        let reply = await host.handle(sequenced(.init(.hello), next), peer: next)
        XCTAssertEqual(reply.result.code, "unavailable"); XCTAssertEqual(world.count("start"), 0)
    }
    func testShutdownAndCleanStopDoNotReactivate() async {
        let world = World(); let host = service(world); let peer = ExternalControlPeer(uid: 501)
        let (request, reply) = await prepared(host, peer); _ = await host.handle(sequenced(apply(request, reply), peer), peer: peer)
        let stopped = await host.handle(sequenced(.init(.stop, instance: host.instance), peer), peer: peer)
        XCTAssertEqual(stopped.result.state, .closed); XCTAssertEqual(stopped.result.comparison, "unchanged")
        await host.shutdown()
        let again = await host.handle(sequenced(apply(request, reply), peer), peer: peer); XCTAssertEqual(again.result.state, .refused)
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
        let hello = await host.handle(sequenced(.init(.hello), peer), peer: peer)
        XCTAssertEqual(hello.result.state, .recoveryRequired)
        let result = await host.handle(sequenced(.init(.prepare, instance: host.instance, profile: UUID(), revision: UUID(), rules: "198.51.100.7"), peer), peer: peer)
        XCTAssertEqual(result.result.state, .recoveryRequired)
        let unregister = await host.handle(sequenced(.init(.quiesce, instance: host.instance), peer), peer: peer)
        XCTAssertEqual(unregister.result.state, .recoveryRequired)
        let stopped = await host.handle(sequenced(.init(.stop, instance: host.instance), peer), peer: peer)
        XCTAssertEqual(stopped.result.state, .recoveryRequired, "no session cannot erase old recovery")
        XCTAssertEqual(world.count("prepare"), 0)
    }
    func testRecoveryAuditRequiresExplicitClearAndFreshZeroPresent() async {
        let world = World()
        let host = ExternalControlService(allowApply: true, initialRecovery: true, now: { world.now() },
            authorize: { world.authorized($0) }, factory: { _, _ in Lease(world) },
            recovery: { action in
                world.note(action.rawValue)
                if action == .recoveryAudit {
                    return .init(.recoveryRequired, code: "recoveryAbsent",
                                 recoveryCandidates: 1, recoveryPresent: 0)
                }
                return .init(.closed, code: "recoveryCleared",
                             recoveryCandidates: 1, recoveryPresent: 0)
            })
        let peer = ExternalControlPeer(uid: 501)
        let hello = await host.handle(sequenced(.init(.hello), peer), peer: peer)
        XCTAssertEqual(hello.result.state, .recoveryRequired)
        let audit = await host.handle(sequenced(.init(.recoveryAudit, instance: host.instance), peer), peer: peer)
        XCTAssertEqual(audit.result.code, "recoveryAbsent")
        XCTAssertEqual(audit.result.recoveryCandidates, 1)
        XCTAssertEqual(audit.result.recoveryPresent, 0)
        let stillBlocked = await host.handle(sequenced(.init(.prepare, instance: host.instance,
            profile: UUID(), revision: UUID(), rules: "198.51.100.7/32"), peer), peer: peer)
        XCTAssertEqual(stillBlocked.result.state, .recoveryRequired)
        let cleared = await host.handle(sequenced(.init(.recoveryClear, instance: host.instance), peer), peer: peer)
        XCTAssertEqual(cleared.result.code, "recoveryCleared")
        let next = await host.handle(sequenced(.init(.status, instance: host.instance), peer), peer: peer)
        XCTAssertEqual(next.result.state, .idle)
        XCTAssertEqual(world.count("recoveryAudit"), 1)
        XCTAssertEqual(world.count("recoveryClear"), 1)
        XCTAssertEqual(world.count("prepare"), 0)
    }
    func testRecoveryClearRefusesWhenFreshAuditStillFindsCandidate() async {
        let world = World()
        let host = ExternalControlService(allowApply: true, initialRecovery: true, now: { world.now() },
            authorize: { world.authorized($0) }, factory: { _, _ in Lease(world) },
            recovery: { _ in
                .init(.recoveryRequired, code: "recoveryPresent",
                      recoveryCandidates: 1, recoveryPresent: 1)
            })
        let peer = ExternalControlPeer(uid: 501); _ = await host.handle(sequenced(.init(.hello), peer), peer: peer)
        let cleared = await host.handle(sequenced(.init(.recoveryClear, instance: host.instance), peer), peer: peer)
        XCTAssertEqual(cleared.result.state, .recoveryRequired)
        XCTAssertEqual(cleared.result.recoveryPresent, 1)
        let status = await host.handle(sequenced(.init(.status, instance: host.instance), peer), peer: peer)
        XCTAssertEqual(status.result.state, .recoveryRequired)
    }
    func testResponseBindingAndBounds() throws {
        let request = ExternalControlRequest(.hello)
        var reply = ExternalControlReply(requestID: request.id, instance: UUID(), canApply: false, result: .init(.idle))
        XCTAssertNoThrow(try ExternalControlReply.decode(reply.encoded(), request: request))
        XCTAssertThrowsError(try ExternalControlReply.decode(reply.encoded(), request: .init(.hello)))
        reply.result.owned = 9
        XCTAssertThrowsError(try ExternalControlReply.decode(reply.encoded(), request: request))
        reply.result.owned = 0; reply.result.recoveryCandidates = 1; reply.result.recoveryPresent = 2
        XCTAssertThrowsError(try ExternalControlReply.decode(reply.encoded(), request: request))
    }
}
