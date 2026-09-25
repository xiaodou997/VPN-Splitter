// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

private func material(_ byte: UInt8 = 71) throws -> WGCredentialMaterial {
    func key(_ value: UInt8) -> String { Data(repeating: value, count: 32).base64EncodedString() }
    return try WireGuardImport.prepareCredentials(Data("""
    [Interface]
    PrivateKey = \(key(byte))
    Address = 10.9.0.2/32
    DNS = 10.9.0.53
    [Peer]
    PublicKey = \(key(byte + 1))
    PresharedKey = \(key(byte + 2))
    AllowedIPs = 10.9.0.0/16
    Endpoint = 203.0.113.\(byte):51820
    """.utf8))
}

private final class FaultStore: WorkspacePersistence {
    var value = Workspace()
    var saves = 0
    var failures = Set<Int>()
    func load() throws -> Workspace { value }
    func save(_ workspace: Workspace) throws {
        saves += 1
        if failures.contains(saves) { throw DraftError.writeFailed }
        try workspace.validate()
        value = workspace
    }
}

/// Per-test only, never shipped as a runtime fallback or used as Keychain evidence.
private final class FaultVault: CredentialVault, @unchecked Sendable {
    var items: [UUID: Data] = [:]
    var creates = 0
    var verifies = 0
    var removals = 0
    var createError: CredentialError?
    var verifyError: CredentialError?
    var removeError: CredentialError?
    var writeBeforeError = false
    var insertForeignCollision = false
    var removed: [UUID] = []
    func create(_ material: WGCredentialMaterial, reference: CredentialReference) throws {
        creates += 1
        if insertForeignCollision {
            let foreign = CredentialReference(profileID: UUID(), id: reference.id)
            items[reference.id] = try KeychainRecord(reference: foreign, material: material).encoded()
        }
        guard items[reference.id] == nil else { throw CredentialError.duplicate }
        if writeBeforeError { items[reference.id] = try KeychainRecord(reference: reference, material: material).encoded() }
        if let createError { throw createError }
        items[reference.id] = try KeychainRecord(reference: reference, material: material).encoded()
    }
    func verify(reference: CredentialReference, metadata: WGMetadata) throws {
        verifies += 1
        if let verifyError { throw verifyError }
        guard let data = items[reference.id] else { throw CredentialError.missing }
        try KeychainRecord.decode(data).check(reference: reference, metadata: metadata)
    }
    func removeOwned(reference: CredentialReference) throws {
        removals += 1
        if let removeError { throw removeError }
        guard let data = items[reference.id] else { return }
        try KeychainRecord.decode(data).check(reference: reference)
        items[reference.id] = nil; removed.append(reference.id)
    }
}

private struct Fixture {
    let store = FaultStore()
    let vault = FaultVault()
    var session = LocalSession(workspace: Workspace())
    mutating func save(_ byte: UInt8 = 71, replacing id: UUID? = nil, credentials: Bool = true) throws -> CredentialImportTransaction {
        let transaction = try CredentialImportTransaction(material: material(byte), workspace: session.workspace, replacing: id)
        try CredentialOperations.save(transaction, persistCredentials: credentials, session: &session, store: store, vault: vault)
        return transaction
    }
    mutating func cleanup(only reference: CredentialReference? = nil) throws {
        try CredentialOperations.cleanup(session: &session, store: store, vault: vault, only: reference)
    }
}

@Test func credentialsStructureOnlyNeverTouchesVault() throws {
    var f = Fixture(); _ = try f.save(credentials: false)
    #expect(f.session.workspace.schemaVersion == 2)
    #expect(f.session.profile?.credential == nil)
    #expect(f.session.workspace.cleanupQueue.isEmpty)
    #expect(f.vault.creates == 0 && f.vault.verifies == 0 && f.vault.removals == 0)
}

@Test func credentialsSuccessfulSaveUsesV3AndExactStructure() throws {
    var f = Fixture(); let transaction = try f.save()
    let profile = try #require(f.session.profile)
    let reference = try #require(profile.credential)
    #expect(reference.profileID == profile.id)
    #expect(profile.id == transaction.profileID)
    #expect(profile.wireGuard == transaction.metadata)
    #expect(profile.rules.isEmpty)
    #expect(f.session.workspace.schemaVersion == 3)
    #expect(f.session.workspace == f.store.value)
    #expect(f.session.workspace.cleanupQueue.isEmpty)
    #expect(f.store.saves == 2 && f.vault.creates == 1 && f.vault.verifies == 1)
    try f.vault.verify(reference: reference, metadata: transaction.metadata)
}

@Test func credentialsWorkspaceContainsNoKeysOrKeyPayloadFields() throws {
    var f = Fixture(); _ = try f.save()
    let encoded = try JSONEncoder().encode(f.store.value)
    let text = String(decoding: encoded, as: UTF8.self)
    for byte: UInt8 in [71, 72, 73] { #expect(!text.contains(Data(repeating: byte, count: 32).base64EncodedString())) }
    for forbidden in ["privateKey", "publicKey", "presharedKey", "rawConfig", "sourceURL", "payload"] { #expect(!text.contains(forbidden)) }
    let decoded = try JSONDecoder().decode(Workspace.self, from: encoded)
    #expect(decoded == f.store.value)
}

@Test func credentialsMaterialRecordAndImportDescriptionAreRedacted() throws {
    let m = try material()
    let record = try KeychainRecord(reference: CredentialReference(profileID: UUID()), material: m)
    let transaction = try CredentialImportTransaction(material: m, workspace: Workspace())
    for text in [String(describing: m), String(reflecting: m), String(describing: record), String(reflecting: record), String(reflecting: transaction)] {
        #expect(text.contains("<redacted>"))
        #expect(!text.contains(Data(repeating: 71, count: 32).base64EncodedString()))
    }
    #expect(Mirror(reflecting: m).children.isEmpty)
    #expect(Mirror(reflecting: record).children.isEmpty)
    #expect(Mirror(reflecting: transaction).children.isEmpty)
}

@Test func credentialsEnvelopeBindsAllKeysAndMetadata() throws {
    let m = try material()
    let ref = CredentialReference(profileID: UUID())
    let record = try KeychainRecord(reference: ref, material: m)
    let decoded = try KeychainRecord.decode(record.encoded())
    #expect(decoded == record)
    let object = try #require(JSONSerialization.jsonObject(with: record.encoded()) as? [String: Any])
    let payload = try #require(object["payload"] as? [String: Any])
    #expect(payload["privateKey"] as? String == Data(repeating: 71, count: 32).base64EncodedString())
    let peers = try #require(payload["peers"] as? [[String: Any]])
    #expect(peers[0]["publicKey"] as? String == Data(repeating: 72, count: 32).base64EncodedString())
    #expect(peers[0]["presharedKey"] as? String == Data(repeating: 73, count: 32).base64EncodedString())
    #expect(throws: CredentialError.mismatch) { try decoded.check(reference: ref, metadata: material(74).metadata) }
    #expect(throws: CredentialError.ownership) { try decoded.check(reference: CredentialReference(profileID: ref.profileID, id: ref.id)) }
}

@Test(arguments: [Data(), Data("secret-error-not-json".utf8), Data(repeating: 65, count: KeychainRecord.byteLimit + 1)])
func credentialsInvalidPayloadIsStaticError(_ data: Data) {
    #expect(throws: CredentialError.invalidRecord) { try KeychainRecord.decode(data) }
}

@Test func credentialsCorruptOrFutureEnvelopeRejectedWithoutEcho() throws {
    let record = try KeychainRecord(reference: CredentialReference(profileID: UUID()), material: material())
    var object = try #require(JSONSerialization.jsonObject(with: record.encoded()) as? [String: Any])
    object["version"] = 2
    #expect(throws: CredentialError.invalidRecord) { try KeychainRecord.decode(JSONSerialization.data(withJSONObject: object)) }
    object["version"] = 1
    var payload = try #require(object["payload"] as? [String: Any])
    payload["privateKey"] = "PRIVATE_SENTINEL"; object["payload"] = payload
    #expect(throws: CredentialError.invalidRecord) { try KeychainRecord.decode(JSONSerialization.data(withJSONObject: object)) }
    #expect(!PolicyFeedback.message(CredentialError.invalidRecord).contains("PRIVATE_SENTINEL"))
}

@Test func credentialsStageWriteFailureMakesNoVaultCall() throws {
    var f = Fixture(); f.store.failures = [1]
    #expect(throws: DraftError.writeFailed) { try f.save() }
    #expect(f.session.workspace == Workspace() && f.store.value == Workspace())
    #expect(f.vault.creates == 0 && f.vault.items.isEmpty)
}

@Test(arguments: [CredentialError.accessDenied, .cancelled, .unavailable, .operation, .duplicate])
func credentialsCreateFailureKeepsJournalAndCanRetry(_ failure: CredentialError) throws {
    var f = Fixture(); f.vault.createError = failure
    let transaction = try CredentialImportTransaction(material: material(), workspace: f.session.workspace)
    #expect(throws: failure) {
        try CredentialOperations.save(transaction, persistCredentials: true, session: &f.session, store: f.store, vault: f.vault)
    }
    #expect(f.session.workspace.profiles.isEmpty && f.session.workspace.cleanupQueue.count == 1)
    #expect(f.session.workspace == f.store.value)
    #expect(throws: CredentialError.pendingCleanup) {
        try CredentialOperations.save(transaction, persistCredentials: true, session: &f.session, store: f.store, vault: f.vault)
    }
    try f.cleanup()
    f.vault.createError = nil
    try CredentialOperations.save(transaction, persistCredentials: true, session: &f.session, store: f.store, vault: f.vault)
    #expect(f.session.profile?.id == transaction.profileID)
}

@Test func credentialsAmbiguousWriteFailureCleansCreatedItem() throws {
    var f = Fixture(); f.vault.writeBeforeError = true; f.vault.createError = .operation
    #expect(throws: CredentialError.operation) { try f.save() }
    #expect(f.vault.items.count == 1 && f.session.workspace.cleanupQueue.count == 1)
    try f.cleanup()
    #expect(f.vault.items.isEmpty && f.session.workspace.cleanupQueue.isEmpty)
}

@Test func credentialsReadbackFailureDoesNotPublishProfile() throws {
    var f = Fixture(); f.vault.verifyError = .mismatch
    #expect(throws: CredentialError.mismatch) { try f.save() }
    #expect(f.session.workspace.profiles.isEmpty && f.vault.items.count == 1)
    try f.cleanup()
    #expect(f.vault.items.isEmpty)
}

@Test func credentialsFinalWriteFailureKeepsOriginalProfileAndOldKey() throws {
    var f = Fixture(); _ = try f.save()
    let old = try #require(f.session.profile)
    let oldRef = try #require(old.credential)
    let oldBytes = f.vault.items[oldRef.id]
    f.store.failures = [f.store.saves + 2]
    #expect(throws: DraftError.writeFailed) { try f.save(74, replacing: old.id) }
    #expect(f.session.profile == old)
    #expect(f.vault.items[oldRef.id] == oldBytes)
    #expect(f.session.workspace.cleanupQueue.count == 1 && f.vault.items.count == 2)
    try f.cleanup()
    #expect(f.vault.items.count == 1 && f.vault.items[oldRef.id] == oldBytes)
}

@Test func credentialsRestartAfterStagedCreateFindsCleanupWithoutTouchingOldKey() throws {
    var f = Fixture(); f.store.failures = [2]
    #expect(throws: DraftError.writeFailed) { try f.save() }
    var restarted = LocalSession(workspace: try f.store.load())
    #expect(restarted.workspace.profiles.isEmpty)
    #expect(restarted.workspace.cleanupQueue.count == 1)
    #expect(f.vault.removals == 0) // startup itself never cleans
    try CredentialOperations.cleanup(session: &restarted, store: f.store, vault: f.vault)
    #expect(f.vault.items.isEmpty && restarted.workspace.cleanupQueue.isEmpty)
}

@Test func credentialsReimportPreservesIdentityNameRulesAndMode() throws {
    var f = Fixture(); _ = try f.save()
    let id = try #require(f.session.selectedID)
    var workspace = f.session.workspace
    workspace.profiles[0].name = "Keep name"
    workspace.profiles[0].defaultAction = .vpn
    workspace.profiles[0].rules = [DraftRule(value: "198.51.100.7", action: .direct)]
    try f.session.commit(workspace, store: f.store)
    let old = try #require(f.session.profile)
    _ = try f.save(74, replacing: id)
    let next = try #require(f.session.profile)
    #expect(next.id == id && next.name == old.name && next.rules == old.rules && next.defaultAction == old.defaultAction)
    #expect(next.wireGuard == (try material(74).metadata) && next.credential != old.credential)
    #expect(f.session.workspace.cleanupQueue == [try #require(old.credential)])
    try f.cleanup()
    #expect(f.vault.items.count == 1)
    #expect(f.vault.items[try #require(next.credential).id] != nil)
}

@Test func credentialsReimportCanExplicitlyDetachToStructureOnly() throws {
    var f = Fixture(); _ = try f.save()
    let old = try #require(f.session.profile)
    _ = try f.save(74, replacing: old.id, credentials: false)
    #expect(f.session.profile?.credential == nil)
    #expect(f.session.profile?.wireGuard == (try material(74).metadata))
    #expect(f.session.workspace.schemaVersion == 3)
    #expect(f.session.workspace.cleanupQueue == [try #require(old.credential)])
    #expect(f.vault.creates == 1)
    try f.cleanup(); #expect(f.vault.items.isEmpty)
}

@Test func credentialsCancelledTransactionHasNoSideEffects() throws {
    let f = Fixture()
    _ = try CredentialImportTransaction(material: material(), workspace: f.session.workspace)
    #expect(f.store.saves == 0 && f.vault.creates == 0 && f.session.workspace == Workspace())
}

@Test func credentialsRepeatedConfirmationOrStaleImportIsRejected() throws {
    var f = Fixture(); let transaction = try f.save()
    let before = f.session.workspace
    #expect(throws: DraftEditError.conflict) {
        try CredentialOperations.save(transaction, persistCredentials: true, session: &f.session, store: f.store, vault: f.vault)
    }
    #expect(f.session.workspace == before && f.vault.creates == 1)
}

@Test func credentialsImportUnknownProfileAndWrongBackendRejected() throws {
    #expect(throws: DraftEditError.missing) { try CredentialImportTransaction(material: material(), workspace: Workspace(), replacing: UUID()) }
    let profile = ProfileDraft(backend: .openVPN)
    #expect(throws: DraftEditError.missing) {
        try CredentialImportTransaction(material: material(), workspace: Workspace(profiles: [profile]), replacing: profile.id)
    }
}

@Test func credentialsDiskConflictStopsBeforeVault() throws {
    var f = Fixture(); f.store.value = Workspace(profiles: [ProfileDraft()])
    #expect(throws: CredentialError.workspaceChanged) { try f.save() }
    #expect(f.vault.creates == 0 && f.store.saves == 0)
}

@Test func credentialsDeleteFirstUnlinksThenCleans() throws {
    var f = Fixture(); _ = try f.save()
    let profile = try #require(f.session.profile)
    try CredentialOperations.remove(profileID: profile.id, deleteProfile: true, removeMetadata: true, session: &f.session, store: f.store)
    #expect(f.session.workspace.profiles.isEmpty && f.vault.items.count == 1 && f.vault.removals == 0)
    #expect(f.session.workspace.cleanupQueue == [try #require(profile.credential)])
    try f.cleanup()
    #expect(f.vault.items.isEmpty && f.session.workspace.cleanupQueue.isEmpty)
}

@Test func credentialsDeleteWriteFailureNeverDeletesKey() throws {
    var f = Fixture(); _ = try f.save()
    let old = try #require(f.session.profile)
    f.store.failures = [f.store.saves + 1]
    #expect(throws: DraftError.writeFailed) {
        try CredentialOperations.remove(profileID: old.id, deleteProfile: true, removeMetadata: true, session: &f.session, store: f.store)
    }
    #expect(f.session.profile == old && f.vault.items.count == 1 && f.vault.removals == 0)
}

@Test func credentialsOnlyRemoveKeepsMetadataAndRules() throws {
    var f = Fixture(); _ = try f.save()
    let old = try #require(f.session.profile)
    try CredentialOperations.remove(profileID: old.id, deleteProfile: false, removeMetadata: false, session: &f.session, store: f.store)
    #expect(f.session.profile?.wireGuard == old.wireGuard && f.session.profile?.rules == old.rules)
    #expect(f.session.profile?.credential == nil)
    try f.cleanup()
    #expect(f.vault.items.isEmpty)
}

@Test func credentialsRemoveStructureAlsoUnlinksCredential() throws {
    var f = Fixture(); _ = try f.save()
    let old = try #require(f.session.profile)
    try CredentialOperations.remove(profileID: old.id, deleteProfile: false, removeMetadata: true, session: &f.session, store: f.store)
    #expect(f.session.profile?.wireGuard == nil && f.session.profile?.credential == nil)
    #expect(f.session.profile?.name == old.name && f.session.profile?.rules == old.rules)
    #expect(f.session.workspace.schemaVersion == 3)
    try f.cleanup()
}

@Test(arguments: [CredentialError.cancelled, .accessDenied, .unavailable, .operation])
func credentialsDeleteFailureRemainsVisibleAndRetryable(_ error: CredentialError) throws {
    var f = Fixture(); _ = try f.save()
    try CredentialOperations.remove(profileID: try #require(f.session.selectedID), deleteProfile: true, removeMetadata: true, session: &f.session, store: f.store)
    let before = f.session.workspace
    f.vault.removeError = error
    #expect(throws: error) { try f.cleanup() }
    #expect(f.session.workspace == before && f.vault.items.count == 1)
    f.vault.removeError = nil
    try f.cleanup()
    #expect(f.session.workspace.cleanupQueue.isEmpty && f.vault.items.isEmpty)
}

@Test func credentialsDeleteAcknowledgementFailureIsIdempotentAfterRestart() throws {
    var f = Fixture(); _ = try f.save()
    try CredentialOperations.remove(profileID: try #require(f.session.selectedID), deleteProfile: true, removeMetadata: true, session: &f.session, store: f.store)
    f.store.failures = [f.store.saves + 1]
    #expect(throws: DraftError.writeFailed) { try f.cleanup() }
    #expect(f.vault.items.isEmpty && f.session.workspace.cleanupQueue.count == 1)
    f.session = LocalSession(workspace: try f.store.load())
    try f.cleanup()
    #expect(f.session.workspace.cleanupQueue.isEmpty && f.vault.removed.count == 1)
    let count = f.vault.removals
    try f.cleanup(); #expect(f.vault.removals == count)
}

@Test func credentialsCleanupDoesNotTouchAnotherProfile() throws {
    var f = Fixture(); _ = try f.save()
    let first = try #require(f.session.profile)
    _ = try f.save(74)
    let second = try #require(f.session.profile)
    let secondReference = try #require(second.credential)
    let secondBytes = f.vault.items[secondReference.id]
    try CredentialOperations.remove(profileID: first.id, deleteProfile: true, removeMetadata: true, session: &f.session, store: f.store)
    try f.cleanup()
    #expect(f.vault.items.count == 1 && f.vault.items[secondReference.id] == secondBytes)
    #expect(f.session.workspace.profiles == [second])
}

@Test func credentialsTargetedCleanupLeavesOtherPendingEntries() throws {
    var f = Fixture(); _ = try f.save()
    let first = try #require(f.session.profile)
    _ = try f.save(74)
    let second = try #require(f.session.profile)
    for profile in [first, second] {
        try CredentialOperations.remove(profileID: profile.id, deleteProfile: true, removeMetadata: true, session: &f.session, store: f.store)
    }
    let secondReference = try #require(second.credential)
    try f.cleanup(only: secondReference)
    #expect(f.session.workspace.cleanupQueue == [try #require(first.credential)])
    #expect(f.vault.items.count == 1)
}

@Test func credentialsCollisionNeverOverwritesOrDeletesForeignItem() throws {
    var f = Fixture(); f.vault.insertForeignCollision = true
    #expect(throws: CredentialError.duplicate) { try f.save() }
    let foreign = f.vault.items
    #expect(throws: CredentialError.ownership) { try f.cleanup() }
    #expect(f.vault.items == foreign && f.session.workspace.cleanupQueue.count == 1)
    #expect(f.vault.removed.isEmpty)
}

@Test func credentialsMalformedOwnedItemIsNotDeleted() throws {
    var f = Fixture(); _ = try f.save()
    let reference = try #require(f.session.profile?.credential)
    try CredentialOperations.remove(profileID: reference.profileID, deleteProfile: true, removeMetadata: true, session: &f.session, store: f.store)
    f.vault.items[reference.id] = Data("corrupt-secret-sentinel".utf8)
    #expect(throws: CredentialError.invalidRecord) { try f.cleanup() }
    #expect(f.vault.removed.isEmpty && f.session.workspace.cleanupQueue.count == 1)
}

@Test func credentialsMissingActiveRecordDoesNotDeleteProfile() throws {
    var f = Fixture(); _ = try f.save()
    let profile = try #require(f.session.profile)
    f.vault.items = [:]
    #expect(throws: CredentialError.missing) { try f.vault.verify(reference: #require(profile.credential), metadata: #require(profile.wireGuard)) }
    #expect(f.session.profile == profile && f.vault.removals == 0)
}

@Test func credentialsSchemaRejectsActiveCleanupCollisionAndWrongOwner() throws {
    var f = Fixture(); _ = try f.save()
    var workspace = f.session.workspace
    let reference = try #require(workspace.profiles[0].credential)
    workspace.pendingCredentialCleanup = [reference]
    #expect(throws: DraftError.invalidDraft) { try workspace.validate() }
    workspace.pendingCredentialCleanup = nil
    workspace.profiles[0].credential = CredentialReference(profileID: UUID())
    #expect(throws: DraftError.invalidDraft) { try workspace.validate() }
}

@Test func credentialsSchemaRejectsV2CredentialAndMissingStructure() throws {
    var f = Fixture(); _ = try f.save()
    var workspace = f.session.workspace; workspace.schemaVersion = 2
    #expect(throws: DraftError.invalidDraft) { try workspace.validate() }
    workspace.schemaVersion = 3; workspace.profiles[0].wireGuard = nil
    #expect(throws: DraftError.invalidDraft) { try workspace.validate() }
}

@Test func credentialsSchemaBoundsPendingCleanup() {
    var workspace = Workspace(schemaVersion: 3)
    workspace.pendingCredentialCleanup = (0..<201).map { _ in CredentialReference(profileID: UUID()) }
    #expect(throws: DraftError.invalidDraft) { try workspace.validate() }
}

@Test func credentialsOldV1V2DecodeWithoutMigrationOnRead() throws {
    for version in [1, 2] {
        let data = Data("{\"schemaVersion\":\(version),\"profiles\":[]}".utf8)
        let workspace = try JSONDecoder().decode(Workspace.self, from: data)
        try workspace.validate()
        #expect(workspace.schemaVersion == version && workspace.cleanupQueue.isEmpty)
    }
}

@Test func credentialsPreviewAndRuleEditsWorkWithV3References() throws {
    var f = Fixture(); _ = try f.save()
    let oldReference = try #require(f.session.profile?.credential)
    var next = f.session.workspace
    next.profiles[0].rules = [DraftRule(value: "10.9.4.0/24")]
    try f.session.commit(next, store: f.store)
    try f.session.compile()
    #expect(try f.session.preview?.explain("10.9.4.5").contains("peer-1") == true)
    #expect(f.session.profile?.credential == oldReference && f.vault.creates == 1)
}

@Test func credentialsFutureWorkspaceFilePreserved() throws {
    let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DraftStore(directory: dir); try store.save(Workspace())
    let bytes = Data(#"{"schemaVersion":4,"profiles":[]}"#.utf8); try bytes.write(to: store.file)
    #expect(throws: DraftError.unsupportedVersion) { try store.load() }
    #expect(try Data(contentsOf: store.file) == bytes)
}

@Test func credentialsDiskJournalRoundTripUsesPrivateFileMode() throws {
    let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = DraftStore(directory: dir)
    var session = LocalSession(workspace: Workspace()); let vault = FaultVault(); vault.createError = .cancelled
    let transaction = try CredentialImportTransaction(material: material(), workspace: session.workspace)
    #expect(throws: CredentialError.cancelled) {
        try CredentialOperations.save(transaction, persistCredentials: true, session: &session, store: store, vault: vault)
    }
    #expect(try store.load() == session.workspace)
    let mode = try FileManager.default.attributesOfItem(atPath: store.file.path)[.posixPermissions] as? NSNumber
    #expect(mode?.intValue == 0o600)
    let text = String(decoding: try Data(contentsOf: store.file), as: UTF8.self)
    #expect(!text.contains("privateKey") && !text.contains(Data(repeating: 71, count: 32).base64EncodedString()))
}

@Test func credentialsLeasePreventsConcurrentWriterAndReleasesOnDeinit() throws {
    let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    var first: WorkspaceLease? = try WorkspaceLease(directory: dir)
    #expect(first != nil)
    #expect(throws: CredentialError.workspaceInUse) { try WorkspaceLease(directory: dir) }
    first = nil
    let second = try WorkspaceLease(directory: dir)
    withExtendedLifetime(second) { #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("workspace.lock").path)) }
}

@Test func credentialsLeaseRejectsLinkedLockWithoutChangingTarget() throws {
    let dir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let target = dir.appendingPathComponent("do-not-change"); let data = Data("sentinel".utf8); try data.write(to: target)
    try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("workspace.lock"), withDestinationURL: target)
    #expect(throws: CredentialError.workspaceInUse) { try WorkspaceLease(directory: dir) }
    #expect(try Data(contentsOf: target) == data)
}

@Test func credentialsNativeBackendIsUnavailableOnLinuxNotAnInMemoryFallback() throws {
    #if !os(macOS)
    #expect(throws: CredentialError.unavailable) {
        try KeychainCredentialVault().create(material(), reference: CredentialReference(profileID: UUID()))
    }
    #endif
}

@Test func credentialsProfileLimitFailsBeforeJournalOrVault() throws {
    var f = Fixture()
    f.store.value = Workspace(profiles: (0..<100).map { _ in ProfileDraft() })
    f.session = LocalSession(workspace: f.store.value)
    #expect(throws: DraftError.tooLarge) { try f.save() }
    #expect(f.store.saves == 0 && f.vault.creates == 0 && f.session.workspace.cleanupQueue.isEmpty)
}

@Test func credentialsRuleEditorPreservesActiveReferenceAndPendingJournal() throws {
    var f = Fixture(); _ = try f.save()
    let profile = try #require(f.session.profile)
    let reference = try #require(profile.credential)
    // Model an unrelated pending cleanup record, never the active reference.
    var next = f.session.workspace
    let pending = CredentialReference(profileID: UUID())
    next.pendingCredentialCleanup = [pending]
    try f.session.commit(next, store: f.store)
    var edit = DraftEdit.settings(try #require(f.session.profile))
    edit.name = "Renamed safely"
    let updated = try edit.applying(to: f.session.workspace)
    #expect(updated.profiles[0].credential == reference)
    #expect(updated.cleanupQueue == [pending] && updated.schemaVersion == 3)
}

@Test func credentialsMetadataMismatchDoesNotChangeWorkspaceOrDeleteItem() throws {
    var f = Fixture(); _ = try f.save()
    let profile = try #require(f.session.profile)
    let reference = try #require(profile.credential)
    let before = f.vault.items
    #expect(throws: CredentialError.mismatch) { try f.vault.verify(reference: reference, metadata: material(74).metadata) }
    #expect(f.session.profile == profile && f.vault.items == before && f.vault.removals == 0)
}

@Test func credentialsNoopCleanupDoesNotCallVaultOrRewriteWorkspace() throws {
    var f = Fixture(); let original = f.session.workspace
    try f.cleanup()
    #expect(f.session.workspace == original && f.store.saves == 0)
    #expect(f.vault.creates == 0 && f.vault.verifies == 0 && f.vault.removals == 0)
}

@Test func credentialsDeliveredReimportFixtureChangesStructureNotPeerPermission() throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<5 { root.deleteLastPathComponent() }
    let fixtures = root.appendingPathComponent("tests/fixtures/wireguard")
    let first = try WGImportFileReader.readCredentials(fixtures.appendingPathComponent("synthetic-ipv4.conf"))
    let second = try WGImportFileReader.readCredentials(fixtures.appendingPathComponent("synthetic-reimport.conf"))
    #expect(first.metadata != second.metadata)
    #expect(first.metadata.peers.map(\.allowedIPs) == second.metadata.peers.map(\.allowedIPs))
    #expect(first.metadata.compatibilityIssues.isEmpty && second.metadata.compatibilityIssues.isEmpty)
}
