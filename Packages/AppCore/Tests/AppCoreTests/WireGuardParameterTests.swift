// SPDX-License-Identifier: MIT
import Foundation
import Testing
@testable import AppCore

// Each test owns its synchronous fault-injection vault; this is NOT a live Keychain.
private final class ParameterStore: WorkspacePersistence {
    var workspace: Workspace
    var saves = 0
    var failAt: Int?
    init(_ workspace: Workspace) { self.workspace = workspace }
    func load() throws -> Workspace { workspace }
    func save(_ next: Workspace) throws {
        saves += 1
        if saves == failAt { throw DraftError.writeFailed }
        try next.validate(); workspace = next
    }
}
private final class ParameterVault: CredentialVault, @unchecked Sendable {
    enum Phase: CaseIterable { case copyBeforeRead, copyAfterWrite, verify, delete }
    var data: [UUID: Data] = [:]
    var calls: [String] = []
    var phase: Phase?
    var failure: CredentialError = .cancelled
    var observingStore: ParameterStore?
    func create(_ material: WGCredentialMaterial, reference: CredentialReference) throws {
        guard data[reference.id] == nil else { throw CredentialError.duplicate }
        data[reference.id] = try KeychainRecord(reference: reference, material: material).encoded()
    }
    func verify(reference: CredentialReference, metadata: WGMetadata) throws {
        calls.append("verify")
        if phase == .verify { throw failure }
        let record = try read(reference); try record.check(reference: reference, metadata: metadata)
    }
    private func read(_ reference: CredentialReference) throws -> KeychainRecord {
        guard let bytes = data[reference.id] else { throw CredentialError.missing }
        let record = try KeychainRecord.decode(bytes); try record.check(reference: reference)
        return record
    }
    func copyUpdatingParameters(from source: CredentialReference, to destination: CredentialReference,
                                expected: WGMetadata, updated: WGMetadata) throws {
        calls.append("copy")
        if let observingStore {
            #expect(observingStore.workspace.cleanupQueue == [destination])
            #expect(observingStore.workspace.profiles.first?.credential == source)
        }
        if phase == .copyBeforeRead { throw failure }
        guard source.profileID == destination.profileID, source.id != destination.id else { throw CredentialError.ownership }
        let record = try read(source); try record.check(reference: source, metadata: expected)
        try create(record.updatingParameters(updated), reference: destination)
        if phase == .copyAfterWrite { throw failure }
    }
    func removeOwned(reference: CredentialReference) throws {
        calls.append("delete")
        if phase == .delete { throw failure }
        guard data[reference.id] != nil else { return }
        _ = try read(reference); data.removeValue(forKey: reference.id)
    }
}
private func parameterMaterial() throws -> WGCredentialMaterial {
    // Fixed synthetic byte patterns, not a usable server credential.
    let privateKey = Data(repeating: 17, count: 32).base64EncodedString()
    let publicKey = Data(repeating: 34, count: 32).base64EncodedString()
    let psk = Data(repeating: 51, count: 32).base64EncodedString()
    return try WireGuardImport.prepareCredentials(Data("""
    [Interface]
    PrivateKey = \(privateKey)
    Address = 10.8.0.2/24
    DNS = 10.9.0.53, corp.example
    ListenPort = 0
    MTU = 1420
    [Peer]
    PublicKey = \(publicKey)
    PresharedKey = \(psk)
    Endpoint = 203.0.113.9:51820
    AllowedIPs = 10.9.0.0/16
    PersistentKeepalive = 25
    """.utf8))
}
private func parameterSetup(credential: Bool = true) throws -> (LocalSession, ParameterStore, ParameterVault, DraftEdit) {
    let material = try parameterMaterial()
    var profile = ProfileDraft(name: "Parameters", rules: [DraftRule(value: "10.9.0.0/16")])
    profile.wireGuard = material.metadata
    let vault = ParameterVault()
    if credential {
        let reference = CredentialReference(profileID: profile.id)
        profile.credential = reference; try vault.create(material, reference: reference)
    }
    let workspace = Workspace(profiles: [profile, ProfileDraft(name: "Other")], schemaVersion: credential ? 3 : 2)
    let store = ParameterStore(workspace); vault.observingStore = store
    var edit = try DraftEdit.parameterEdit(profile)
    edit.parameters?.mtu = "1380"
    return (LocalSession(workspace: workspace), store, vault, edit)
}

@Test func parameterEditorIsIdentityBoundAndHasNoKeyInputs() throws {
    let (session, _, _, edit) = try parameterSetup()
    let original = try #require(session.profile?.wireGuard)
    let clean = try DraftEdit.parameterEdit(try #require(session.profile))
    #expect(!clean.hasChanges && edit.hasChanges)
    #expect(throws: WGParameterError.missing) { try DraftEdit.parameterEdit(ProfileDraft()) }
    #expect(throws: WGParameterError.transactionRequired) { try edit.applying(to: session.workspace) }
    var draft = try #require(edit.parameters)
    draft.addresses = "10.8.0.7/24, 10.8.1.2/24"; draft.dnsServers = "10.9.0.54"
    draft.listenPort = "51821"; draft.peers[0].endpoint = "203.0.113.10:51822"
    draft.peers[0].persistentKeepalive = "off"
    let next = try draft.metadata(replacing: original)
    #expect(next.addresses[0].text == "10.8.0.7/24")
    #expect(next.dnsServers == ["10.9.0.54"] && next.mtu == 1380 && next.listenPort == 51821)
    #expect(next.peers[0].persistentKeepalive == 0)
    #expect(next.peers[0].allowedIPs == original.peers[0].allowedIPs)
    #expect(next.searchDomains == original.searchDomains && next.peers[0].hadPresharedKey)
    #expect(try draft.changedFields(from: original).count == 6)
}

@Test(arguments: ["-1", "01", "65536", "word", "1\n2", "1\u{0}", String(repeating: "1", count: 100)])
func parameterNumbersRejectInvalidInput(_ input: String) throws {
    let metadata = try parameterMaterial().metadata
    var draft = WGParameterDraft(metadata); draft.listenPort = input
    #expect(throws: WGImportError.self) { try draft.metadata(replacing: metadata) }
    draft = WGParameterDraft(metadata); draft.mtu = input
    #expect(throws: WGImportError.self) { try draft.metadata(replacing: metadata) }
    draft = WGParameterDraft(metadata); draft.peers[0].persistentKeepalive = input
    #expect(throws: WGImportError.self) { try draft.metadata(replacing: metadata) }
}

@Test func parameterBlankZeroAndLimitsAreDistinct() throws {
    let metadata = try parameterMaterial().metadata
    var draft = WGParameterDraft(metadata)
    draft.listenPort = ""; draft.mtu = ""; draft.peers[0].persistentKeepalive = ""
    var next = try draft.metadata(replacing: metadata)
    #expect(next.listenPort == nil && next.mtu == nil && next.peers[0].persistentKeepalive == nil)
    draft.listenPort = "0"; draft.mtu = "576"; draft.peers[0].persistentKeepalive = "0"
    next = try draft.metadata(replacing: metadata)
    #expect(next.listenPort == 0 && next.mtu == 576 && next.peers[0].persistentKeepalive == 0)
    draft.mtu = "575"
    #expect(throws: WGImportError(.number, field: .mtu)) { try draft.metadata(replacing: metadata) }
    draft.mtu = "65535"; draft.listenPort = "65535"; draft.peers[0].persistentKeepalive = "65535"
    #expect(try draft.metadata(replacing: metadata).mtu == 65535)
}

@Test(arguments: ["10.8.0.7/33", "10.8.0.01", "10.8.0.7,", ",10.8.0.7", "PrivateKey=PRIVATE", "10.8.0.7\n10.8.0.8"])
func parameterListsRejectMalformedOrConfigText(_ input: String) throws {
    let metadata = try parameterMaterial().metadata
    var draft = WGParameterDraft(metadata); draft.addresses = input
    #expect(throws: WGImportError.self) { try draft.metadata(replacing: metadata) }
    draft = WGParameterDraft(metadata); draft.dnsServers = input
    #expect(throws: WGImportError.self) { try draft.metadata(replacing: metadata) }
}

@Test func parameterBudgetsAndRedaction() throws {
    let metadata = try parameterMaterial().metadata
    var draft = WGParameterDraft(metadata); draft.addresses = Array(repeating: "10.8.0.7", count: 65).joined(separator: ",")
    #expect(throws: WGImportError(.limit, field: .address)) { try draft.metadata(replacing: metadata) }
    draft = WGParameterDraft(metadata); draft.dnsServers = Array(repeating: "10.9.0.53", count: 33).joined(separator: ",")
    #expect(throws: WGImportError(.limit, field: .dns)) { try draft.metadata(replacing: metadata) }
    draft = WGParameterDraft(metadata); draft.peers[0].endpoint = String(repeating: "s", count: 265)
    #expect(throws: WGImportError(.limit, field: .endpoint)) { try draft.metadata(replacing: metadata) }
    draft.dnsServers = "PRIVATE.example"
    do { _ = try draft.metadata(replacing: metadata); Issue.record("Expected failure") }
    catch { #expect(!PolicyFeedback.message(error).contains("PRIVATE")) }
}

@Test func parameterUnsupportedStructureIsRetainedAndBlocksPlanning() throws {
    let (session, _, _, edit) = try parameterSetup(credential: false)
    let metadata = try #require(session.profile?.wireGuard)
    var draft = try #require(edit.parameters)
    draft.peers[0].endpoint = "vpn.example:51820"
    let named = try draft.metadata(replacing: metadata)
    #expect(named.peers[0].endpoint?.isHostname == true)
    #expect(named.compatibilityIssues.contains { $0.code == "W_WG_ENDPOINT_DNS" && $0.blocksPlanning })
    draft.addresses = "2001:db8::2/64"; draft.dnsServers = "2001:db8::53"
    #expect(try draft.metadata(replacing: metadata).addresses[0].text == "2001:db8::2/64")
    draft.addresses = ""; draft.peers[0].endpoint = ""
    let empty = try draft.metadata(replacing: metadata)
    #expect(empty.compatibilityIssues.contains { $0.code == "W_WG_ADDRESS_REQUIRED" })
    #expect(empty.compatibilityIssues.contains { $0.code == "W_WG_ENDPOINT_REQUIRED" })
}

@Test func parameterPeerIdentityAndProtectedRangesCannotBeRebound() throws {
    let original = try parameterMaterial().metadata
    var draft = WGParameterDraft(original); draft.peers = []
    #expect(throws: WGParameterError.identity) { try draft.metadata(replacing: original) }
    let peer = original.peers[0]
    let changed = WGMetadata(formatVersion: 1, addresses: original.addresses, dnsServers: original.dnsServers,
        searchDomains: original.searchDomains, listenPort: original.listenPort, mtu: original.mtu,
        peers: [.init(id: peer.id, allowedIPs: [try WGAddressRange("0.0.0.0/0")], endpoint: peer.endpoint,
                      persistentKeepalive: peer.persistentKeepalive, hadPresharedKey: peer.hadPresharedKey)])
    let material = try parameterMaterial()
    let record = try KeychainRecord(reference: CredentialReference(profileID: UUID()), material: material)
    #expect(throws: WGParameterError.identity) { try record.updatingParameters(changed) }
}

@Test func parameterStructuralSavePreservesWorkspaceWithoutVault() throws {
    var (session, store, vault, edit) = try parameterSetup(credential: false)
    let before = session.workspace; try session.compile()
    let token = try session.beginSimulation()
    #expect(try WGParameterOperations.save(edit, session: &session, store: store, vault: vault))
    #expect(vault.calls.isEmpty && store.saves == 1)
    #expect(session.workspace.schemaVersion == 2 && session.profile?.wireGuard?.mtu == 1380)
    #expect(session.workspace.profiles[1] == before.profiles[1])
    #expect(session.profile?.rules == before.profiles[0].rules && session.profile?.name == before.profiles[0].name)
    #expect(session.profile?.defaultAction == before.profiles[0].defaultAction)
    #expect(session.profile?.credential == nil && session.preview == nil)
    session.finishSimulation(token: token, success: true)
    #expect(session.connection.state == .idle)
}

@Test func parameterCredentialSaveCopiesExactKeysThenRetiresOnlyOldReference() throws {
    var (session, store, vault, edit) = try parameterSetup()
    let before = session.workspace
    let old = try #require(session.profile?.credential); let oldData = try #require(vault.data[old.id])
    #expect(try WGParameterOperations.save(edit, session: &session, store: store, vault: vault))
    let new = try #require(session.profile?.credential)
    #expect(new != old && session.workspace.cleanupQueue == [old] && vault.data[old.id] == oldData)
    #expect(vault.calls == ["copy", "verify"] && store.saves == 2)
    let beforeJSON = try #require(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
    let newData = try #require(vault.data[new.id])
    let afterJSON = try #require(JSONSerialization.jsonObject(with: newData) as? [String: Any])
    #expect((beforeJSON["payload"] as? NSDictionary) == (afterJSON["payload"] as? NSDictionary))
    #expect(session.profile?.rules == before.profiles[0].rules)
    #expect(session.workspace.profiles[1] == before.profiles[1])
    try CredentialOperations.cleanup(session: &session, store: store, vault: vault, only: old)
    #expect(vault.data[old.id] == nil && vault.data[new.id] != nil && session.workspace.cleanupQueue.isEmpty)
    let json = String(decoding: try JSONEncoder().encode(session.workspace), as: UTF8.self)
    for value in [17, 34, 51] { #expect(!json.contains(Data(repeating: UInt8(value), count: 32).base64EncodedString())) }
    #expect(!json.contains("privateKey") && !json.contains("payload"))
}

@Test func parameterNoopDoesNotPromptOrWrite() throws {
    var (session, store, vault, edit) = try parameterSetup()
    edit.parameters?.mtu = " 1420 "
    #expect(!(try WGParameterOperations.save(edit, session: &session, store: store, vault: vault)))
    #expect(vault.calls.isEmpty && store.saves == 0 && session.workspace.cleanupQueue.isEmpty)
}

@Test func parameterSelectionBaselineAndDiskChangesStopBeforeSideEffects() throws {
    var (session, store, vault, edit) = try parameterSetup()
    session.select(session.workspace.profiles[1].id)
    #expect(throws: DraftEditError.conflict) { try WGParameterOperations.save(edit, session: &session, store: store, vault: vault) }
    session.select(edit.baseline.id)
    store.workspace.profiles[0].name = "changed-on-disk"
    #expect(throws: CredentialError.workspaceChanged) { try WGParameterOperations.save(edit, session: &session, store: store, vault: vault) }
    session = LocalSession(workspace: store.workspace)
    #expect(throws: DraftEditError.conflict) { try WGParameterOperations.save(edit, session: &session, store: store, vault: vault) }
    #expect(vault.calls.isEmpty && store.saves == 0)
}

@Test func parameterInvalidInputAndStagingFailureDoNotTouchVault() throws {
    var (session, store, vault, edit) = try parameterSetup()
    let original = session.workspace
    edit.parameters?.mtu = "invalid"
    #expect(throws: WGImportError.self) { try WGParameterOperations.save(edit, session: &session, store: store, vault: vault) }
    edit.parameters?.mtu = "1380"; store.failAt = 1
    #expect(throws: DraftError.writeFailed) { try WGParameterOperations.save(edit, session: &session, store: store, vault: vault) }
    #expect(vault.calls.isEmpty && session.workspace == original && store.workspace == original)
}

@Test(arguments: [CredentialError.cancelled, .accessDenied, .unavailable, .missing, .ownership, .mismatch, .invalidRecord])
func parameterVaultFailureKeepsOldAndCanCleanThenRetry(_ error: CredentialError) throws {
    var (session, store, vault, edit) = try parameterSetup()
    let oldProfile = try #require(session.profile)
    vault.phase = .copyBeforeRead; vault.failure = error
    #expect(throws: error) { try WGParameterOperations.save(edit, session: &session, store: store, vault: vault) }
    #expect(session.profile == oldProfile && session.workspace.cleanupQueue.count == 1)
    #expect(vault.data.count == 1)
    #expect(throws: CredentialError.pendingCleanup) { try WGParameterOperations.save(edit, session: &session, store: store, vault: vault) }
    vault.phase = nil
    try CredentialOperations.cleanup(session: &session, store: store, vault: vault)
    #expect(try WGParameterOperations.save(edit, session: &session, store: store, vault: vault))
    #expect(session.profile?.wireGuard?.mtu == 1380)
}

@Test(arguments: [ParameterVault.Phase.copyAfterWrite, .verify])
private func parameterPartialVaultWritesRemainRecoverable(_ phase: ParameterVault.Phase) throws {
    var (session, store, vault, edit) = try parameterSetup()
    let oldProfile = try #require(session.profile); let old = try #require(oldProfile.credential)
    vault.phase = phase
    #expect(throws: CredentialError.cancelled) { try WGParameterOperations.save(edit, session: &session, store: store, vault: vault) }
    #expect(session.profile == oldProfile && vault.data.count == 2)
    vault.phase = nil
    session = LocalSession(workspace: try store.load())
    try CredentialOperations.cleanup(session: &session, store: store, vault: vault)
    #expect(vault.data.count == 1 && vault.data[old.id] != nil)
}

@Test func parameterFinalPublishFailureAndCleanupAcknowledgementRetry() throws {
    var (session, store, vault, edit) = try parameterSetup()
    let before = try #require(session.profile)
    store.failAt = 2
    #expect(throws: DraftError.writeFailed) { try WGParameterOperations.save(edit, session: &session, store: store, vault: vault) }
    #expect(session.profile == before && store.workspace.profiles[0] == before && vault.data.count == 2)
    let stale = try #require(session.workspace.cleanupQueue.first)
    store.failAt = 3
    #expect(throws: DraftError.writeFailed) { try CredentialOperations.cleanup(session: &session, store: store, vault: vault) }
    #expect(vault.data[stale.id] == nil && session.workspace.cleanupQueue == [stale])
    store.failAt = nil; session = LocalSession(workspace: try store.load())
    try CredentialOperations.cleanup(session: &session, store: store, vault: vault)
    #expect(session.workspace.cleanupQueue.isEmpty && session.profile == before)
}

@Test func parameterCleanupFailureCannotUndoPublishedBinding() throws {
    var (session, store, vault, edit) = try parameterSetup()
    let old = try #require(session.profile?.credential)
    try WGParameterOperations.save(edit, session: &session, store: store, vault: vault)
    let new = try #require(session.profile?.credential)
    vault.phase = .delete
    #expect(throws: CredentialError.cancelled) { try CredentialOperations.cleanup(session: &session, store: store, vault: vault, only: old) }
    #expect(session.profile?.credential == new && session.profile?.wireGuard?.mtu == 1380)
    #expect(session.workspace.cleanupQueue == [old] && vault.data.count == 2)
}

@Test func parameterEditorFailureRetainsBufferAndCancelGuard() throws {
    var (session, store, vault, edit) = try parameterSetup()
    var editor = DraftEditor(); try editor.begin(edit)
    store.failAt = 1
    #expect(throws: DraftError.writeFailed) { try WGParameterOperations.save(edit, session: &session, store: store, vault: vault) }
    #expect(editor.edit?.parameters?.mtu == "1380")
    #expect(!editor.cancel() && !editor.allowsWorkspaceActions)
    #expect(throws: DraftEditError.alreadyEditing) { try editor.begin(.settings(edit.baseline)) }
    #expect(editor.cancel(discardChanges: true) && editor.allowsWorkspaceActions)
}

@Test func parameterRealStoreKeepsRulesAndUpdatedStructureAcrossReload() throws {
    var (session, _, vault, edit) = try parameterSetup(credential: false)
    vault.observingStore = nil
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("parameter-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = DraftStore(directory: directory); try store.save(session.workspace)
    try WGParameterOperations.save(edit, session: &session, store: store, vault: vault)
    #expect(try store.load() == session.workspace)
    #expect(try store.load().profiles[0].wireGuard?.mtu == 1380)
}

@Test func parameterNativeCopyDoesNotFallBackOnLinux() throws {
    #if !os(macOS)
    let metadata = try parameterMaterial().metadata
    let id = UUID()
    #expect(throws: CredentialError.unavailable) {
        try KeychainCredentialVault().copyUpdatingParameters(from: .init(profileID: id), to: .init(profileID: id), expected: metadata, updated: metadata)
    }
    #endif
}

@Test func parameterPeerReorderAndPresharedFlagCannotChange() throws {
    let original = try parameterMaterial().metadata
    let first = original.peers[0]
    let second = WGPeerMetadata(id: "peer-2", allowedIPs: first.allowedIPs, endpoint: first.endpoint,
                                persistentKeepalive: nil, hadPresharedKey: false)
    let multi = WGMetadata(formatVersion: 1, addresses: original.addresses, dnsServers: original.dnsServers,
                           searchDomains: original.searchDomains, listenPort: nil, mtu: nil, peers: [first, second])
    var draft = WGParameterDraft(multi); draft.peers.reverse()
    #expect(throws: WGParameterError.identity) { try draft.metadata(replacing: multi) }
    let changedFlag = WGPeerMetadata(id: first.id, allowedIPs: first.allowedIPs, endpoint: first.endpoint,
                                     persistentKeepalive: first.persistentKeepalive, hadPresharedKey: false)
    let changed = WGMetadata(formatVersion: 1, addresses: original.addresses, dnsServers: original.dnsServers,
                             searchDomains: original.searchDomains, listenPort: nil, mtu: nil, peers: [changedFlag])
    #expect(throws: WGParameterError.identity) { try WGParameterDraft.checkPreserved(original, updated: changed) }
    let domains = WGMetadata(formatVersion: 1, addresses: original.addresses, dnsServers: original.dnsServers,
                             searchDomains: [], listenPort: nil, mtu: nil, peers: original.peers)
    #expect(throws: WGParameterError.identity) { try WGParameterDraft.checkPreserved(original, updated: domains) }
}

@Test func parameterActuallyMismatchedSourceIsNotOverwrittenOrDeleted() throws {
    var (session, store, vault, edit) = try parameterSetup()
    let old = try #require(session.profile?.credential)
    let record = try KeychainRecord.decode(try #require(vault.data[old.id]))
    var modified = WGParameterDraft(record.metadata); modified.mtu = "1300"
    let material = try record.updatingParameters(modified.metadata(replacing: record.metadata))
    let mismatchedBytes = try KeychainRecord(reference: old, material: material).encoded()
    vault.data[old.id] = mismatchedBytes
    #expect(throws: CredentialError.mismatch) { try WGParameterOperations.save(edit, session: &session, store: store, vault: vault) }
    #expect(session.profile == edit.baseline && vault.data[old.id] == mismatchedBytes)
    try CredentialOperations.cleanup(session: &session, store: store, vault: vault)
    #expect(vault.data.count == 1 && vault.data[old.id] == mismatchedBytes)
}

@Test func parameterStructuralWriteFailureKeepsOriginalPreview() throws {
    var (session, store, vault, edit) = try parameterSetup(credential: false)
    try session.compile(); let old = session.workspace
    store.failAt = 1
    #expect(throws: DraftError.writeFailed) { try WGParameterOperations.save(edit, session: &session, store: store, vault: vault) }
    #expect(session.workspace == old && session.preview != nil && vault.calls.isEmpty)
}

@Test func parameterSavedEndpointConflictIsCaughtByRealCompiler() throws {
    var (session, store, vault, edit) = try parameterSetup(credential: false)
    try session.compile()
    edit.parameters?.peers[0].endpoint = "10.9.0.10:51820"
    try WGParameterOperations.save(edit, session: &session, store: store, vault: vault)
    #expect(session.preview == nil)
    #expect(throws: (any Error).self) { try session.compile() }
    #expect(session.preview == nil)
    edit = try DraftEdit.parameterEdit(try #require(session.profile))
    edit.parameters?.peers[0].endpoint = "203.0.113.10:51820"
    try WGParameterOperations.save(edit, session: &session, store: store, vault: vault)
    try session.compile()
    #expect(session.preview?.constrainedPlan != nil)
}
