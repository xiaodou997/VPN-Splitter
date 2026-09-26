// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import ProviderConfiguration

// All synthetic, in-memory fault injection. No Security or Keychain API is invoked.
private final class CredentialMemoryBackend: ManagedCredentialBackend, @unchecked Sendable {
    struct State {
        var items: [Data: ManagedCredentialStoredItem] = [:]
        var sequence = 0
        var events: [String] = []
        var addError: ManagedCredentialBackendError?
        var readError: ManagedCredentialBackendError?
        var deleteError: ManagedCredentialBackendError?
        var existsError: ManagedCredentialBackendError?
        var badReference = false
        var corruptRead = false
        var changeReadMaterial = false
        var rawReadError = false
        var retainOnDelete = false
        var cancelAfterAdd = false
        var cancelAfterRead = false
    }
    private let lock = NSLock()
    private var state = State()
    func access<T>(_ body: (inout State) throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }; return try body(&state)
    }
    func add(account: String, value: Data) throws -> Data {
        try access { s in
            s.events.append("add")
            if let error = s.addError { throw error }
            guard !s.items.values.contains(where: { $0.account == account }) else { throw ManagedCredentialBackendError.duplicate }
            s.sequence += 1
            let ref = Data("SYNTHETIC-REF-\(s.sequence)".utf8)
            s.items[ref] = .init(account: account, value: value)
            if s.cancelAfterAdd { withUnsafeCurrentTask { $0?.cancel() } }
            return s.badReference ? Data() : ref
        }
    }
    func read(reference: Data) throws -> ManagedCredentialStoredItem {
        try access { s in
            s.events.append("read")
            if let error = s.readError { throw error }
            if s.rawReadError { throw NSError(domain: "SYNTHETIC-SECRET", code: 9, userInfo: [NSLocalizedDescriptionKey: "SYNTHETIC-SECRET"]) }
            guard let item = s.items[reference] else { throw ManagedCredentialBackendError.missing }
            if s.cancelAfterRead { withUnsafeCurrentTask { $0?.cancel() } }
            if s.changeReadMaterial {
                let record = try ManagedCredentialRecord(keychainData: item.value)
                let changed = try ManagedCredentialMaterial(configuration: Data("SYNTHETIC-CHANGED".utf8), policyArchive: Data([1]))
                return .init(account: item.account, value: try ManagedCredentialRecord(profile: record.profile, ownerUID: record.ownerUID, material: changed).encodeForKeychain())
            }
            return s.corruptRead ? .init(account: item.account, value: Data("NOT-A-PLIST".utf8)) : item
        }
    }
    func delete(reference: Data, account: String) throws {
        try access { s in
            s.events.append("delete")
            if let error = s.deleteError { throw error }
            guard let item = s.items[reference], item.account == account else { throw ManagedCredentialBackendError.missing }
            if !s.retainOnDelete { s.items.removeValue(forKey: reference) }
        }
    }
    func exists(reference: Data) throws -> Bool {
        try access { s in
            s.events.append("exists")
            if let error = s.existsError { throw error }
            return s.items[reference] != nil
        }
    }
}

@MainActor
final class ManagedCredentialVaultTests: XCTestCase {
    private func profile(generation: UInt64 = 1) throws -> ManagedProfileDescriptor {
        try .init(profileID: UUID(), credentialID: UUID(), policyRevision: UUID(), generation: generation)
    }
    private func material() throws -> ManagedCredentialMaterial {
        try .init(configuration: Data("[Interface]\nPrivateKey = SYNTHETIC-NOT-A-REAL-KEY\n".utf8),
                  policyArchive: Data("SYNTHETIC-ORDERED-POLICY".utf8))
    }
    private func vault(_ backend: CredentialMemoryBackend, owner: UInt32 = 501) throws -> ManagedCredentialVault {
        try .init(backend: backend, ownerUID: owner)
    }
    private func error(from body: () async throws -> Void) async -> ManagedCredentialError? {
        do { try await body(); XCTFail("Expected a typed failure"); return nil }
        catch let e as ManagedCredentialError { return e }
        catch { XCTFail("Unexpected error type"); return nil }
    }
    private func replaceRecord(_ backend: CredentialMemoryBackend, handle: ManagedCredentialHandle,
                               edit: (inout [String: Any]) -> Void) throws {
        try backend.access { s in
            let item = try XCTUnwrap(s.items[handle.persistentReference])
            var fields = try XCTUnwrap(PropertyListSerialization.propertyList(from: item.value, format: nil) as? [String: Any])
            edit(&fields)
            let data = try PropertyListSerialization.data(fromPropertyList: fields, format: .binary, options: 0)
            s.items[handle.persistentReference] = .init(account: item.account, value: data)
        }
    }

    func testPrepareReadsBackAndLoadReturnsOriginalBytes() async throws {
        let backend = CredentialMemoryBackend(), m = try material(), p = try profile(), v = try vault(backend)
        let h = try await v.prepare(profile: p, material: m)
        XCTAssertEqual(h.profile, p); XCTAssertEqual(h.ownerUID, 501)
        XCTAssertEqual(backend.access { $0.events }, ["add", "read"])
        let loaded = try await v.load(h); XCTAssertEqual(loaded, m)
    }
    func testDuplicateNeverDeletesOrReplacesExistingRecord() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b), p = try profile(), m = try material()
        let old = try await v.prepare(profile: p, material: m)
        let e = await error { _ = try await v.prepare(profile: p, material: m) }
        XCTAssertEqual(e?.reason, .duplicate); XCTAssertEqual(e?.cleanup, .notNeeded)
        XCTAssertEqual(b.access { $0.items.count }, 1)
        XCTAssertFalse(b.access { $0.events.contains("delete") })
        let loaded = try await v.load(old); XCTAssertEqual(loaded, m)
    }
    func testNewRecordDoesNotRemoveOldSelection() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b), m = try material()
        let old = try await v.prepare(profile: profile(), material: m)
        _ = try await v.prepare(profile: profile(generation: 2), material: m)
        XCTAssertEqual(b.access { $0.items.count }, 2)
        let loaded = try await v.load(old); XCTAssertEqual(loaded, m)
    }
    func testPrepareReadbackFailureCleansOnlyNewRecord() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b), m = try material()
        let old = try await v.prepare(profile: profile(), material: m)
        b.access { $0.corruptRead = true }
        let e = await error { _ = try await v.prepare(profile: profile(), material: m) }
        XCTAssertEqual(e?.reason, .invalidRecord); XCTAssertEqual(e?.cleanup, .confirmedAbsent)
        XCTAssertNil(e?.cleanupTicket); XCTAssertEqual(b.access { $0.items.count }, 1)
        b.access { $0.corruptRead = false }
        let loaded = try await v.load(old); XCTAssertEqual(loaded, m)
    }
    func testReadbackChecksMaterialNotOnlyMetadata() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b); b.access { $0.changeReadMaterial = true }
        let e = await error { _ = try await v.prepare(profile: profile(), material: material()) }
        XCTAssertEqual(e?.reason, .verificationFailed); XCTAssertEqual(e?.cleanup, .confirmedAbsent)
        XCTAssertEqual(b.access { $0.items.count }, 0)
    }
    func testRawBackendErrorDoesNotEscapeInFailureDescription() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b); b.access { $0.rawReadError = true }
        let e = await error { _ = try await v.prepare(profile: profile(), material: material()) }
        XCTAssertEqual(e?.reason, .unavailable); XCTAssertEqual(e?.cleanup, .confirmedAbsent)
        XCTAssertFalse(String(describing: e).contains("SYNTHETIC"))
    }
    func testFailedCleanupKeepsRetryReceipt() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b)
        b.access { $0.corruptRead = true; $0.deleteError = .denied }
        let e = await error { _ = try await v.prepare(profile: profile(), material: material()) }
        XCTAssertEqual(e?.cleanup, .unconfirmed)
        let ticket = try XCTUnwrap(e?.cleanupTicket)
        XCTAssertEqual(b.access { $0.items.count }, 1)
        b.access { $0.deleteError = nil }
        try await v.retryCleanup(ticket)
        XCTAssertEqual(b.access { $0.items.count }, 0)
    }
    func testSuccessfulDeleteReturnDoesNotProveAbsence() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b)
        let h = try await v.prepare(profile: profile(), material: material())
        b.access { $0.retainOnDelete = true }
        let e = await error { try await v.revoke(h) }
        XCTAssertEqual(e?.reason, .cleanupUnconfirmed); XCTAssertEqual(e?.cleanup, .unconfirmed)
        XCTAssertNotNil(e?.cleanupTicket); XCTAssertEqual(b.access { $0.items.count }, 1)
    }
    func testAbsenceCheckFailureIsUnconfirmedNotSuccess() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b)
        let h = try await v.prepare(profile: profile(), material: material())
        b.access { $0.existsError = .denied }
        let e = await error { try await v.revoke(h) }
        XCTAssertEqual(e?.reason, .cleanupUnconfirmed); XCTAssertEqual(e?.cleanup, .unconfirmed)
        let ticket = try XCTUnwrap(e?.cleanupTicket)
        b.access { $0.existsError = nil }
        try await v.retryCleanup(ticket)
    }
    func testRevokeIsIdempotentOnlyWithObservedAbsence() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b)
        let h = try await v.prepare(profile: profile(), material: material())
        try await v.revoke(h); try await v.revoke(h)
        XCTAssertEqual(b.access { $0.events.suffix(2) }, ["read", "exists"])
        XCTAssertEqual(b.access { $0.items.count }, 0)
    }
    func testMissingScopedRecordButReferenceStillPresentIsUnconfirmed() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b)
        let h = try await v.prepare(profile: profile(), material: material())
        b.access { $0.readError = .missing }
        let e = await error { try await v.revoke(h) }
        XCTAssertEqual(e?.reason, .cleanupUnconfirmed); XCTAssertEqual(e?.cleanup, .unconfirmed)
        XCTAssertFalse(b.access { $0.events.contains("delete") })
    }
    func testMissingRecordThenDeniedAbsenceHasConsistentCleanupState() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b)
        let h = try await v.prepare(profile: profile(), material: material())
        b.access { $0.readError = .missing; $0.existsError = .denied }
        let e = await error { try await v.revoke(h) }
        XCTAssertEqual(e?.reason, .cleanupUnconfirmed); XCTAssertEqual(e?.cleanup, .unconfirmed)
        XCTAssertNil(e?.cleanupTicket) // No verified ownership receipt for this revoke.
        XCTAssertFalse(b.access { $0.events.contains("delete") })
    }
    func testWrongUIDRejectedBeforeAnyBackendCall() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b)
        let h = try ManagedCredentialHandle(profile: profile(), ownerUID: 502, persistentReference: Data([1]))
        let e = await error { _ = try await v.load(h) }
        XCTAssertEqual(e?.reason, .wrongOwner); XCTAssertTrue(b.access { $0.events.isEmpty })
        let revoke = await error { try await v.revoke(h) }; XCTAssertEqual(revoke?.reason, .wrongOwner)
    }
    func testForeignAccountIsNeverDeleted() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b)
        let h = try await v.prepare(profile: profile(), material: material())
        b.access { s in let old = s.items[h.persistentReference]!; s.items[h.persistentReference] = .init(account: "FOREIGN", value: old.value) }
        let e = await error { try await v.revoke(h) }
        XCTAssertEqual(e?.reason, .wrongOwner); XCTAssertFalse(b.access { $0.events.contains("delete") })
    }
    func testRecordOwnerMismatchRejected() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b)
        let h = try await v.prepare(profile: profile(), material: material())
        try replaceRecord(b, handle: h) { $0["owner"] = "502" }
        let e = await error { _ = try await v.load(h) }; XCTAssertEqual(e?.reason, .invalidRecord)
    }
    func testEveryProfileBindingFieldIsChecked() async throws {
        for field in ["profile", "credential", "policyRevision", "generation"] {
            let b = CredentialMemoryBackend(), v = try vault(b)
            let h = try await v.prepare(profile: profile(), material: material())
            try replaceRecord(b, handle: h) { fields in
                var profile = fields["profile"] as! [String: String]
                profile[field] = field == "generation" ? "2" : UUID().uuidString
                fields["profile"] = profile
            }
            let e = await error { _ = try await v.load(h) }; XCTAssertEqual(e?.reason, .invalidRecord, field)
        }
    }
    func testUnknownSchemaAndFieldsRejected() async throws {
        for schemaChange in [true, false] {
            let b = CredentialMemoryBackend(), v = try vault(b)
            let h = try await v.prepare(profile: profile(), material: material())
            try replaceRecord(b, handle: h) { fields in fields[schemaChange ? "schema" : "unexpected"] = "unexpected-v2" }
            let e = await error { _ = try await v.load(h) }; XCTAssertEqual(e?.reason, .invalidRecord)
        }
    }
    func testOwnerNumericCoercionAndNoncanonicalStringRejected() async throws {
        for owner: Any in [NSNumber(value: true), NSNumber(value: 501), "0501", "0", "-1", "4294967296"] {
            let b = CredentialMemoryBackend(), v = try vault(b)
            let h = try await v.prepare(profile: profile(), material: material())
            try replaceRecord(b, handle: h) { $0["owner"] = owner }
            let e = await error { _ = try await v.load(h) }; XCTAssertEqual(e?.reason, .invalidRecord)
        }
    }
    func testChangedReferenceDoesNotReadAnotherCredential() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b)
        let one = try await v.prepare(profile: profile(), material: material())
        let two = try await v.prepare(profile: profile(), material: material())
        let wrong = try ManagedCredentialHandle(profile: one.profile, ownerUID: one.ownerUID, persistentReference: two.persistentReference)
        let e = await error { _ = try await v.load(wrong) }; XCTAssertEqual(e?.reason, .wrongOwner)
    }
    func testLaunchMetadataMustMatchSelectedHandleBeforeRead() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b)
        let h = try await v.prepare(profile: profile(), material: material())
        let request = ManagedStartRequest(profile: h.profile)
        let launch = try ManagedLaunchContract.check(providerBundleIdentifier: "test.provider", expectedProviderBundleIdentifier: "test.provider",
            providerConfiguration: ManagedLaunchContract.providerConfiguration(for: h.profile), passwordReference: h.persistentReference,
            options: ManagedLaunchContract.startOptions(for: request))
        let loaded = try await v.load(for: launch, selected: h); XCTAssertEqual(loaded, try material())
        let wrong = try ManagedCredentialHandle(profile: h.profile, ownerUID: 501, persistentReference: Data([1, 2]))
        let before = b.access { $0.events.count }
        let e = await error { _ = try await v.load(for: launch, selected: wrong) }
        XCTAssertEqual(e?.reason, .invalidHandle); XCTAssertEqual(b.access { $0.events.count }, before)
    }
    func testDeniedAddDoesNotDeleteOrFallback() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b); b.access { $0.addError = .denied }
        let e = await error { _ = try await v.prepare(profile: profile(), material: material()) }
        XCTAssertEqual(e?.reason, .denied); XCTAssertEqual(b.access { $0.events }, ["add"])
    }
    func testInvalidSuccessfulAddReferencePreservesUncertainWrite() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b); b.access { $0.badReference = true }
        let e = await error { _ = try await v.prepare(profile: profile(), material: material()) }
        XCTAssertEqual(e?.reason, .writeUnconfirmed); XCTAssertEqual(e?.cleanup, .unconfirmed)
        XCTAssertNil(e?.cleanupTicket); XCTAssertEqual(b.access { $0.events }, ["add"])
        XCTAssertEqual(b.access { $0.items.count }, 1) // Not hidden by broad cleanup.
    }
    func testBackendIndeterminateAddPreservedAsUnconfirmed() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b); b.access { $0.addError = .writeUnconfirmed }
        let e = await error { _ = try await v.prepare(profile: profile(), material: material()) }
        XCTAssertEqual(e?.reason, .writeUnconfirmed); XCTAssertEqual(e?.cleanup, .unconfirmed)
        XCTAssertEqual(b.access { $0.events }, ["add"])
    }
    func testCancellationBeforePrepareNeverTouchesBackend() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b), p = try profile(), m = try material()
        let task = Task { () -> ManagedCredentialError? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await v.prepare(profile: p, material: m); return nil }
            catch { return error as? ManagedCredentialError }
        }
        let e = await task.value; XCTAssertEqual(e?.reason, .cancelled)
        XCTAssertTrue(b.access { $0.events.isEmpty })
    }
    func testCancellationAfterAddCleansReceiptEvenWhileCancelled() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b), p = try profile(), m = try material()
        b.access { $0.cancelAfterAdd = true }
        let task = Task { () -> ManagedCredentialError? in
            do { _ = try await v.prepare(profile: p, material: m); return nil }
            catch { return error as? ManagedCredentialError }
        }
        let e = await task.value; XCTAssertEqual(e?.reason, .cancelled); XCTAssertEqual(e?.cleanup, .confirmedAbsent)
        XCTAssertEqual(b.access { $0.events }, ["add", "delete", "exists"])
    }
    func testCancellationAfterReadDiscardsMaterialAndCleansNewItem() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b), p = try profile(), m = try material()
        b.access { $0.cancelAfterRead = true }
        let task = Task { () -> ManagedCredentialError? in
            do { _ = try await v.prepare(profile: p, material: m); return nil }
            catch { return error as? ManagedCredentialError }
        }
        let e = await task.value; XCTAssertEqual(e?.reason, .cancelled); XCTAssertEqual(e?.cleanup, .confirmedAbsent)
        XCTAssertEqual(b.access { $0.items.count }, 0)
    }
    func testCancellationDuringLoadDoesNotDeleteSavedCredential() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b)
        let h = try await v.prepare(profile: profile(), material: material())
        b.access { $0.cancelAfterRead = true }
        let task = Task { () -> ManagedCredentialError? in
            do { _ = try await v.load(h); return nil }
            catch { return error as? ManagedCredentialError }
        }
        let e = await task.value; XCTAssertEqual(e?.reason, .cancelled)
        XCTAssertEqual(b.access { $0.items.count }, 1); XCTAssertFalse(b.access { $0.events.contains("delete") })
    }
    func testConcurrentDuplicatePreparesHaveSingleWinner() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b), p = try profile(), m = try material()
        let wins = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<10 { group.addTask { (try? await v.prepare(profile: p, material: m)) != nil } }
            var count = 0; for await won in group { if won { count += 1 } }; return count
        }
        XCTAssertEqual(wins, 1); XCTAssertEqual(b.access { $0.items.count }, 1)
        XCTAssertFalse(b.access { $0.events.contains("delete") })
    }
    func testInvalidMaterialAndHandleLimits() throws {
        for config in [Data(), Data([0xFF]), Data(repeating: 65, count: 65_537)] {
            XCTAssertThrowsError(try ManagedCredentialMaterial(configuration: config, policyArchive: Data([1])))
        }
        for policy in [Data(), Data(repeating: 1, count: 65_537)] {
            XCTAssertThrowsError(try ManagedCredentialMaterial(configuration: Data([65]), policyArchive: policy))
        }
        let valid = try ManagedCredentialMaterial(configuration: Data(repeating: 65, count: 65_536), policyArchive: Data(repeating: 1, count: 65_536))
        let r = ManagedCredentialRecord(profile: try profile(), ownerUID: 501, material: valid)
        XCTAssertEqual(try ManagedCredentialRecord(keychainData: r.encodeForKeychain()), r)
        for ref in [Data(), Data(repeating: 0, count: 4097)] {
            XCTAssertThrowsError(try ManagedCredentialHandle(profile: profile(), ownerUID: 501, persistentReference: ref))
        }
        XCTAssertThrowsError(try ManagedCredentialHandle(profile: profile(), ownerUID: 0, persistentReference: Data([1])))
        XCTAssertThrowsError(try vault(CredentialMemoryBackend(), owner: 0))
    }
    func testOversizedAndMalformedRecordRejected() throws {
        for data in [Data(), Data("MALFORMED-SYNTHETIC".utf8), Data(repeating: 65, count: 140_001)] {
            XCTAssertThrowsError(try ManagedCredentialRecord(keychainData: data)) { error in
                XCTAssertEqual((error as? ManagedCredentialError)?.reason, .invalidRecord)
            }
        }
    }
    func testMaterialAndReferenceDetachMutableFoundationStorage() throws {
        let source = NSMutableData(data: Data("SYNTHETIC-CONFIG".utf8))
        let policy = NSMutableData(data: Data("SYNTHETIC-POLICY".utf8))
        let m = try ManagedCredentialMaterial(configuration: Data(referencing: source), policyArchive: Data(referencing: policy))
        source.resetBytes(in: NSRange(location: 0, length: source.length)); policy.resetBytes(in: NSRange(location: 0, length: policy.length))
        m.withContents { XCTAssertEqual(String(data: $0, encoding: .utf8), "SYNTHETIC-CONFIG"); XCTAssertEqual(String(data: $1, encoding: .utf8), "SYNTHETIC-POLICY") }
        let ref = NSMutableData(data: Data("SYNTHETIC-REF".utf8))
        let h = try ManagedCredentialHandle(profile: profile(), ownerUID: 501, persistentReference: Data(referencing: ref))
        ref.resetBytes(in: NSRange(location: 0, length: ref.length))
        XCTAssertEqual(h.persistentReference, Data("SYNTHETIC-REF".utf8))
    }
    func testDescriptionsAndMirrorsDoNotExposePayloadsOrReferences() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b), m = try material()
        let h = try await v.prepare(profile: profile(), material: m)
        b.access { $0.retainOnDelete = true }
        let failure = await error { try await v.revoke(h) }
        let e = try XCTUnwrap(failure)
        let ticket = try XCTUnwrap(e.cleanupTicket)
        for item: Any in [m, h, v, e, ticket] {
            var text = ""; dump(item, to: &text)
            XCTAssertFalse(text.contains("SYNTHETIC")); XCTAssertFalse(String(reflecting: item).contains("SYNTHETIC"))
            XCTAssertEqual(Mirror(reflecting: item).children.count, 0)
        }
    }
    func testCleanupReceiptCannotBeUsedByOtherUserVault() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b)
        b.access { $0.corruptRead = true; $0.deleteError = .denied }
        let e = await error { _ = try await v.prepare(profile: profile(), material: material()) }
        let ticket = try XCTUnwrap(e?.cleanupTicket), other = try vault(b, owner: 502)
        let count = b.access { $0.events.count }
        let failure = await error { try await other.retryCleanup(ticket) }
        XCTAssertEqual(failure?.reason, .wrongOwner); XCTAssertEqual(b.access { $0.events.count }, count)
    }
    func testCorruptSavedRecordIsNotSilentlyDeleted() async throws {
        let b = CredentialMemoryBackend(), v = try vault(b)
        let h = try await v.prepare(profile: profile(), material: material())
        b.access { $0.corruptRead = true }
        let e = await error { try await v.revoke(h) }
        XCTAssertEqual(e?.reason, .invalidRecord); XCTAssertFalse(b.access { $0.events.contains("delete") })
    }
}
