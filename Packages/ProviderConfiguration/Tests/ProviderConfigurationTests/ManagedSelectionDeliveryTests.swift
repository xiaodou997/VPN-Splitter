// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import ProviderConfiguration

private final class TransactionKeychain: ManagedCredentialBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [Data: ManagedCredentialStoredItem] = [:]
    private var reads = 0
    var readCount: Int { lock.lock(); defer { lock.unlock() }; return reads }
    var count: Int { lock.lock(); defer { lock.unlock() }; return records.count }
    func add(account: String, value: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let reference = Data(UUID().uuidString.utf8)
        records[reference] = ManagedCredentialStoredItem(account: account, value: value)
        return reference
    }
    func read(reference: Data) throws -> ManagedCredentialStoredItem {
        lock.lock(); defer { lock.unlock() }; reads += 1
        guard let value = records[reference] else { throw ManagedCredentialBackendError.missing }
        return value
    }
    func delete(reference: Data, account: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard records[reference]?.account == account else { throw ManagedCredentialBackendError.missing }
        records.removeValue(forKey: reference)
    }
    func exists(reference: Data) throws -> Bool { lock.lock(); defer { lock.unlock() }; return records[reference] != nil }
}

@MainActor
private final class TransactionPreferences: ManagedPreferenceStore {
    var current: ManagedCredentialHandle?
    var onRead: (() async throws -> Void)?
    var onPublish: (() async throws -> Void)?
    var rejectBeforeSave = false
    var rejectAfterSave = false
    var reads = 0
    var writes = 0
    func read() async throws -> ManagedCredentialHandle? {
        reads += 1; try await onRead?(); return current
    }
    func publish(_ new: ManagedCredentialHandle, replacing old: ManagedCredentialHandle?) async throws {
        guard current == old else { throw ManagedTransferError.selectionChanged }
        writes += 1
        if rejectBeforeSave { throw ManagedTransferError.publicationUnconfirmed }
        current = new
        try await onPublish?()
        if rejectAfterSave { throw ManagedTransferError.publicationUnconfirmed }
    }
}

@MainActor
private final class DeliveryClock { var value: TimeInterval = 0 }

@MainActor
final class ManagedSelectionDeliveryTests: XCTestCase {
    private let provider = "test.app.PacketTunnel"
    private func material(_ text: String = "SYNTHETIC-SECRET") throws -> ManagedCredentialMaterial {
        try ManagedCredentialMaterial(configuration: Data(text.utf8), policyArchive: Data("synthetic-rules".utf8))
    }
    private func fixture() throws -> (ManagedSelectionTransaction, TransactionPreferences, TransactionKeychain) {
        let keychain = TransactionKeychain(), store = TransactionPreferences()
        let vault = try ManagedCredentialVault(backend: keychain, ownerUID: 501)
        return (ManagedSelectionTransaction(vault: vault, store: store), store, keychain)
    }
    private func saved() async throws -> (ManagedSelectionTransaction, TransactionPreferences, TransactionKeychain) {
        let (tx, store, backend) = try fixture()
        try await tx.refresh(); _ = try await tx.save(material())
        return (tx, store, backend)
    }
    private func grant() throws -> ManagedDeliveryAuthorization {
        let profile = try ManagedProfileDescriptor(profileID: UUID(), credentialID: UUID(), policyRevision: UUID(), generation: 1)
        return ManagedDeliveryAuthorization(id: UUID(), handle: try ManagedCredentialHandle(profile: profile, ownerUID: 501,
            persistentReference: Data([1, 2, 3])), request: ManagedStartRequest(profile: profile))
    }
    private func checked(_ grant: ManagedDeliveryAuthorization, reference: Data? = nil) throws -> CheckedManagedLaunch {
        try ManagedLaunchContract.check(providerBundleIdentifier: provider, expectedProviderBundleIdentifier: provider,
            providerConfiguration: ManagedLaunchContract.providerConfiguration(for: grant.handle.profile),
            passwordReference: reference ?? grant.handle.persistentReference,
            options: ManagedLaunchContract.startOptions(for: grant.request))
    }
    private func expect(_ expected: ManagedTransferError, _ body: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? ManagedTransferError, expected, file: file, line: line) }
    }
    private func rejects(_ error: ManagedTransferError, _ body: () throws -> Void,
                         file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? ManagedTransferError, error, file: file, line: line) }
    }

    func testSaveRequiresExplicitRefresh() async throws {
        let (tx, _, backend) = try fixture()
        await expect(.selectionMissing) { _ = try await tx.save(material()) }
        XCTAssertEqual(backend.count, 0)
    }
    func testSaveCommitsOnlyAfterReadback() async throws {
        let (tx, store, backend) = try await saved()
        XCTAssertEqual(tx.selected, store.current); XCTAssertEqual(tx.selected?.profile.generation, 1)
        XCTAssertEqual(backend.count, 1); XCTAssertGreaterThanOrEqual(store.reads, 4)
    }
    func testReplaceRetainsOldImmutableRecord() async throws {
        let (tx, store, backend) = try await saved(); let old = try XCTUnwrap(store.current)
        let new = try await tx.save(material("NEW"))
        XCTAssertEqual(new.profile.profileID, old.profile.profileID); XCTAssertEqual(new.profile.generation, 2)
        XCTAssertNotEqual(new.profile.credentialID, old.profile.credentialID)
        XCTAssertNotEqual(new.profile.policyRevision, old.profile.policyRevision)
        XCTAssertEqual(backend.count, 2); XCTAssertEqual(store.current, new)
    }
    func testFreshSelectionMismatchRejectsBeforeKeychainWrite() async throws {
        let (tx, store, backend) = try await saved(); store.current = nil
        await expect(.selectionChanged) { _ = try await tx.save(material()) }
        XCTAssertEqual(backend.count, 1)
    }
    func testCancelAfterPrepareCleansOnlyNewReceipt() async throws {
        let (tx, store, backend) = try await saved(); let old = store.current
        let target = store.reads + 2
        store.onRead = { if store.reads == target { tx.cancel() } }
        await expect(.cancelled) { _ = try await tx.save(material()) }
        XCTAssertEqual(backend.count, 1); XCTAssertEqual(store.current, old)
    }
    func testUncertainFailedSaveRetainsCandidateAndBlocksDelivery() async throws {
        let (tx, store, backend) = try await saved(); store.rejectBeforeSave = true
        await expect(.publicationUnconfirmed) { _ = try await tx.save(material()) }
        XCTAssertEqual(backend.count, 2); XCTAssertTrue(tx.publicationUnconfirmed)
        await expect(.selectionMissing) { _ = try await tx.authorizeDelivery() }
    }
    func testSaveAppliedButCallbackFailedRecoversFromPreferences() async throws {
        let (tx, store, backend) = try await saved(); store.rejectAfterSave = true
        await expect(.publicationUnconfirmed) { _ = try await tx.save(material("NEW")) }
        XCTAssertEqual(backend.count, 2); XCTAssertEqual(store.current?.profile.generation, 2)
        store.rejectAfterSave = false; try await tx.refresh()
        XCTAssertFalse(tx.publicationUnconfirmed)
        let grant = try await tx.authorizeDelivery()
        let loaded = try await tx.material(for: grant)
        XCTAssertEqual(loaded, try material("NEW"))
    }
    func testCancelDuringSaveDoesNotDeletePublishedItem() async throws {
        let (tx, store, backend) = try await saved(); store.onPublish = { tx.cancel() }
        await expect(.publicationUnconfirmed) { _ = try await tx.save(material()) }
        XCTAssertEqual(backend.count, 2); XCTAssertEqual(store.current?.profile.generation, 2)
    }
    func testChangedReadbackDoesNotRollbackOtherWriter() async throws {
        let (tx, store, backend) = try await saved(); store.onPublish = { store.current = nil }
        await expect(.publicationUnconfirmed) { _ = try await tx.save(material()) }
        XCTAssertNil(store.current); XCTAssertEqual(backend.count, 2)
    }
    func testSingleAuthorizationAndSingleMaterialRead() async throws {
        let (tx, _, backend) = try await saved()
        let grant = try await tx.authorizeDelivery()
        await expect(.busy) { _ = try await tx.authorizeDelivery() }
        let before = backend.readCount
        _ = try await tx.material(for: grant)
        await expect(.replay) { _ = try await tx.material(for: grant) }
        XCTAssertEqual(backend.readCount, before + 1)
    }
    func testStaleSelectionPreventsKeychainRead() async throws {
        let (tx, store, backend) = try await saved(); let grant = try await tx.authorizeDelivery()
        let before = backend.readCount; store.current = nil
        await expect(.selectionChanged) { _ = try await tx.material(for: grant) }
        XCTAssertEqual(backend.readCount, before)
    }
    func testSelectionChangeAfterMaterialReadPreventsSubmission() async throws {
        let (tx, store, _) = try await saved(); let grant = try await tx.authorizeDelivery()
        _ = try await tx.material(for: grant); store.current = nil
        await expect(.selectionChanged) { try await tx.validateForStart(grant) }
    }
    func testCancelRevokesAuthorization() async throws {
        let (tx, _, _) = try await saved(); let grant = try await tx.authorizeDelivery(); tx.cancel()
        await expect(.cancelled) { _ = try await tx.material(for: grant) }
    }
    func testOldFailureCannotCancelNewAuthorization() async throws {
        let (tx, _, _) = try await saved(); let old = try await tx.authorizeDelivery(); tx.cancel()
        let new = try await tx.authorizeDelivery(); tx.finishDelivery(old)
        _ = try await tx.material(for: new); try await tx.validateForStart(new)
    }
    func testGenerationOverflowRejectedWithoutWrite() async throws {
        let (tx, store, backend) = try fixture()
        let profile = try ManagedProfileDescriptor(profileID: UUID(), credentialID: UUID(), policyRevision: UUID(), generation: .max)
        store.current = try ManagedCredentialHandle(profile: profile, ownerUID: 501, persistentReference: Data([1]))
        try await tx.refresh()
        await expect(.capacity) { _ = try await tx.save(material()) }
        XCTAssertEqual(backend.count, 0)
    }
    func testConcurrentSaveRejectedWhileAwaitingRead() async throws {
        let (tx, store, backend) = try await saved()
        var release: CheckedContinuation<Void, Never>?
        store.onRead = { await withCheckedContinuation { release = $0 } }
        let first = Task { @MainActor in try await tx.save(material()) }
        while release == nil { await Task.yield() }
        await expect(.busy) { _ = try await tx.save(material()) }
        tx.cancel(); store.onRead = nil; release?.resume()
        do { _ = try await first.value; XCTFail("cancelled save") } catch {}
        XCTAssertEqual(backend.count, 1)
    }

    func testBrokerConsumesMatchingRecordExactlyOnce() async throws {
        let broker = ManagedDeliveryBroker(), id = UUID(), grant = try grant()
        let challenge = try broker.open(connection: id, kernelUID: 501)
        let envelope = try ManagedDeliveryEnvelope(challenge: challenge, grant: grant, material: material())
        try broker.stage(envelope.encodedForAuthenticatedXPC(), connection: id)
        XCTAssertEqual(try broker.consume(checked(grant), ownerUID: 501).material, try material())
        rejects(.deliveryMissing) { _ = try broker.consume(checked(grant), ownerUID: 501) }
    }
    func testRootIsNotAnAppOwner() async throws {
        let broker = ManagedDeliveryBroker()
        rejects(.invalidIdentity) { _ = try broker.open(connection: UUID(), kernelUID: 0) }
    }
    func testHelloCannotBeRepeatedOnLiveConnection() async throws {
        let broker = ManagedDeliveryBroker(), id = UUID()
        _ = try broker.open(connection: id, kernelUID: 501)
        rejects(.replay) { _ = try broker.open(connection: id, kernelUID: 501) }
    }
    func testWrongConnectionCannotReuseChallenge() async throws {
        let broker = ManagedDeliveryBroker(), one = UUID(), two = UUID()
        let challenge = try broker.open(connection: one, kernelUID: 501)
        _ = try broker.open(connection: two, kernelUID: 501)
        let envelope = try ManagedDeliveryEnvelope(challenge: challenge, grant: grant(), material: material())
        rejects(.invalidIdentity) { try broker.stage(envelope.encodedForAuthenticatedXPC(), connection: two) }
    }
    func testWrongKernelUserCannotConsume() async throws {
        let broker = ManagedDeliveryBroker(), id = UUID(), grant = try grant()
        let challenge = try broker.open(connection: id, kernelUID: 501)
        try broker.stage(ManagedDeliveryEnvelope(challenge: challenge, grant: grant, material: material()).encodedForAuthenticatedXPC(), connection: id)
        rejects(.selectionChanged) { _ = try broker.consume(checked(grant), ownerUID: 502) }
        rejects(.deliveryMissing) { _ = try broker.consume(checked(grant), ownerUID: 501) }
    }
    func testWrongReferenceConsumesStagedRecord() async throws {
        let broker = ManagedDeliveryBroker(), id = UUID(), grant = try grant()
        let challenge = try broker.open(connection: id, kernelUID: 501)
        try broker.stage(ManagedDeliveryEnvelope(challenge: challenge, grant: grant, material: material()).encodedForAuthenticatedXPC(), connection: id)
        rejects(.selectionChanged) { _ = try broker.consume(checked(grant, reference: Data([9])), ownerUID: 501) }
        XCTAssertEqual(broker.pendingCount, 0)
    }
    func testTimeoutBeforeStageNeedsNoTimerDelivery() async throws {
        let time = DeliveryClock(); time.value = 100
        let broker = ManagedDeliveryBroker(now: { time.value }), id = UUID()
        let challenge = try broker.open(connection: id, kernelUID: 501)
        time.value += 15
        rejects(.expired) { try broker.stage(ManagedDeliveryEnvelope(challenge: challenge, grant: grant(), material: material()).encodedForAuthenticatedXPC(), connection: id) }
    }
    func testTimeoutAfterStageDropsSecret() async throws {
        let time = DeliveryClock()
        let broker = ManagedDeliveryBroker(now: { time.value }), id = UUID(), grant = try grant()
        let challenge = try broker.open(connection: id, kernelUID: 501)
        try broker.stage(ManagedDeliveryEnvelope(challenge: challenge, grant: grant, material: material()).encodedForAuthenticatedXPC(), connection: id)
        time.value = 16
        rejects(.deliveryMissing) { _ = try broker.consume(checked(grant), ownerUID: 501) }
        XCTAssertEqual(broker.pendingCount, 0)
    }
    func testConnectionCloseInvalidatesStagedSecret() async throws {
        let broker = ManagedDeliveryBroker(), id = UUID(), grant = try grant()
        let challenge = try broker.open(connection: id, kernelUID: 501)
        try broker.stage(ManagedDeliveryEnvelope(challenge: challenge, grant: grant, material: material()).encodedForAuthenticatedXPC(), connection: id)
        broker.close(id)
        rejects(.deliveryMissing) { _ = try broker.consume(checked(grant), ownerUID: 501) }
    }
    func testBrokerChecksLivenessWithoutWaitingForQueuedInvalidation() async throws {
        final class Live: @unchecked Sendable {
            let lock = NSLock(); var value = true
            func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
            func stop() { lock.lock(); value = false; lock.unlock() }
        }
        let live = Live(), broker = ManagedDeliveryBroker(), id = UUID(), grant = try grant()
        let challenge = try broker.open(connection: id, kernelUID: 501, isLive: { live.get() })
        try broker.stage(ManagedDeliveryEnvelope(challenge: challenge, grant: grant, material: material()).encodedForAuthenticatedXPC(), connection: id)
        live.stop()
        rejects(.deliveryMissing) { _ = try broker.consume(checked(grant), ownerUID: 501) }
    }
    func testAttemptReplayAcrossConnectionsRejected() async throws {
        let broker = ManagedDeliveryBroker(), grant = try grant()
        for index in 0..<2 {
            let id = UUID(), challenge = try broker.open(connection: UUID(), kernelUID: 501)
            broker.discard()
            let actual = try broker.open(connection: id, kernelUID: 501)
            XCTAssertNotEqual(challenge.nonce, actual.nonce)
            let bytes = try ManagedDeliveryEnvelope(challenge: actual, grant: grant, material: material()).encodedForAuthenticatedXPC()
            if index == 0 { try broker.stage(bytes, connection: id); _ = try broker.consume(checked(grant), ownerUID: 501) }
            else { rejects(.replay) { try broker.stage(bytes, connection: id) } }
        }
    }
    func testOnlyOneUserCanStageAtOnce() async throws {
        let broker = ManagedDeliveryBroker(), first = UUID(), second = UUID()
        let one = try broker.open(connection: first, kernelUID: 501)
        let two = try broker.open(connection: second, kernelUID: 501)
        try broker.stage(ManagedDeliveryEnvelope(challenge: one, grant: grant(), material: material()).encodedForAuthenticatedXPC(), connection: first)
        rejects(.busy) { try broker.stage(ManagedDeliveryEnvelope(challenge: two, grant: grant(), material: material()).encodedForAuthenticatedXPC(), connection: second) }
    }
    func testConnectionCapacityBounded() async throws {
        let broker = ManagedDeliveryBroker()
        for _ in 0..<8 { _ = try broker.open(connection: UUID(), kernelUID: 501) }
        rejects(.capacity) { _ = try broker.open(connection: UUID(), kernelUID: 501) }
    }
    func testMalformedAndOversizedDataRejected() async throws {
        for bytes in [Data(), Data("<plist/>".utf8), Data(repeating: 1, count: 145001)] {
            let broker = ManagedDeliveryBroker(), id = UUID()
            _ = try broker.open(connection: id, kernelUID: 501)
            rejects(.invalidMessage) { try broker.stage(bytes, connection: id) }
            XCTAssertEqual(broker.pendingCount, 0)
        }
    }
    func testUnknownFieldsAndSchemaRejected() async throws {
        let broker = ManagedDeliveryBroker(), id = UUID()
        let challenge = try broker.open(connection: id, kernelUID: 501)
        let bytes = try ManagedDeliveryEnvelope(challenge: challenge, grant: grant(), material: material()).encodedForAuthenticatedXPC()
        var fields = try ManagedWire.decode(bytes, maximum: 145000)
        fields["untrustedPath"] = "/tmp/secret"
        rejects(.invalidMessage) { _ = try ManagedDeliveryEnvelope(authenticatedXPCData: ManagedWire.encode(fields, maximum: 145000)) }
        fields.removeValue(forKey: "untrustedPath"); fields["schema"] = "future"
        rejects(.invalidMessage) { _ = try ManagedDeliveryEnvelope(authenticatedXPCData: ManagedWire.encode(fields, maximum: 145000)) }
    }
    func testChallengeRejectsNoncanonicalOwnerAndID() async throws {
        var fields = ManagedDeliveryChallenge(instance: UUID(), ownerUID: 501).fields
        for owner in ["0", "0501", "-1", "4294967296"] {
            fields["owner"] = owner
            rejects(.invalidMessage) { _ = try ManagedDeliveryChallenge(fields: fields) }
        }
        fields["owner"] = "501"; fields["nonce"] = "bad"
        rejects(.invalidMessage) { _ = try ManagedDeliveryChallenge(fields: fields) }
    }
    func testEnvelopeAndReceivedReflectionRedacted() async throws {
        let envelope = try ManagedDeliveryEnvelope(challenge: .init(instance: UUID(), ownerUID: 501), grant: grant(), material: material())
        let restored = try ManagedDeliveryEnvelope(authenticatedXPCData: envelope.encodedForAuthenticatedXPC())
        XCTAssertEqual(restored.material, envelope.material)
        XCTAssertEqual(Mirror(reflecting: envelope).children.count, 0)
        let received = ManagedReceivedConfiguration(restored)
        XCTAssertEqual(Mirror(reflecting: received).children.count, 0)
        XCTAssertFalse(String(reflecting: received).contains("SYNTHETIC-SECRET"))
    }
    func testPeerRequirementsPinTeamAndExactRole() async throws {
        let peers = try ManagedPeerRequirement(appID: "test.app", providerID: "test.app.PacketTunnel", teamID: "1BCDEFGHIJ")
        XCTAssertTrue(peers.requirement(provider: true).contains("identifier \"test.app.PacketTunnel\""))
        XCTAssertTrue(peers.requirement(provider: false).contains("identifier \"test.app\""))
        XCTAssertTrue(peers.requirement(provider: true).contains("= \"1BCDEFGHIJ\""))
        XCTAssertTrue(peers.requirement(provider: true).contains("get-task-allow"))
    }
    func testRequirementInjectionAndWrongRoleRejected() async throws {
        for team in ["", "ABCDEFGHI\" or true", "$(TEAM_ID)", "abcdefghij"] {
            rejects(.invalidIdentity) { _ = try ManagedPeerRequirement(appID: "test.app", providerID: "test.app.PacketTunnel", teamID: team) }
        }
        rejects(.invalidIdentity) { _ = try ManagedPeerRequirement(appID: "test.app", providerID: "other.app", teamID: "ABCDEFGHIJ") }
    }
}
