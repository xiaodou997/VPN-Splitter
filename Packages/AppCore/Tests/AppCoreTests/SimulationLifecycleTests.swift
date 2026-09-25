// SPDX-License-Identifier: MIT
import Foundation
import PolicyCore
import Testing
@testable import AppCore

private func simulationProfile() -> ProfileDraft {
    ProfileDraft(name: "Synthetic", rules: [DraftRule(value: "198.51.100.0/24"),
                                          DraftRule(value: "198.51.100.7", action: .direct)])
}
private func startedSession() throws -> LocalSession {
    var session = LocalSession(workspace: Workspace(profiles: [simulationProfile()]))
    _ = try session.beginSimulation()
    return session
}
private final class SimulationStore: WorkspacePersistence {
    var value: Workspace
    var rejectSave = false
    init(_ value: Workspace) { self.value = value }
    func load() throws -> Workspace { value }
    func save(_ next: Workspace) throws {
        if rejectSave { throw DraftError.writeFailed }
        try next.validate(); value = next
    }
}

@Test func simulationStartsWithActualCompilerAndBoundContext() throws {
    let session = try startedSession()
    let attempt = try #require(session.connection.attempt)
    #expect(session.connection.state == .connecting)
    #expect(attempt.profileID == session.selectedID)
    #expect(attempt.context == session.preview?.plan.context)
    #expect(session.connection.history.map(\.note) == [.checking, .started])
    #expect(try session.preview?.explain("198.51.100.7").contains("VPN；命中规则 1") == true)
    #expect(session.preview?.plan.ruleEvaluations[1].effect == .fullyShadowed)
}

@Test func simulationDuplicateStartDoesNotInvalidateCurrentAttemptOrPreview() throws {
    var session = try startedSession()
    let attempt = session.connection.attempt
    let preview = session.preview?.plan
    let notes = session.connection.history.map(\.note)
    #expect(throws: SimulationCommandError.alreadyActive) { try session.beginSimulation() }
    #expect(session.connection.attempt == attempt && session.preview?.plan == preview)
    #expect(session.connection.history.map(\.note) == notes)
    session.finishSimulation(token: try #require(attempt?.id), success: true)
    #expect(throws: SimulationCommandError.alreadyActive) { try session.beginSimulation() }
    #expect(session.connection.state == .connected)
}

@Test func simulationMissingProfileReportsValidationFailureWithoutAttempt() {
    var session = LocalSession(workspace: Workspace())
    #expect(throws: DraftError.noProfile) { try session.beginSimulation() }
    #expect(session.connection.failure == .policyCheck && session.connection.state == .failed)
    #expect(session.connection.attempt == nil && session.preview == nil)
    #expect(session.connection.history.map(\.note) == [.checking, .policyRejected])
}

@Test(arguments: [DraftMatch.domain, .suffix, .ipv6])
func simulationUnsupportedPolicyCannotSucceed(_ match: DraftMatch) {
    var session = LocalSession(workspace: Workspace(profiles: [ProfileDraft(rules: [
        DraftRule(match: match, value: "PRIVATE-INPUT")])]))
    #expect(throws: PolicyCompilationError.self) { try session.beginSimulation() }
    #expect(session.preview == nil && session.connection.attempt == nil)
    #expect(session.connection.failure == .policyCheck)
    #expect(!session.connection.history.map(\.note.rawValue).joined().contains("PRIVATE-INPUT"))
}

@Test func simulationSuccessAndFailureAreSingleConsumption() throws {
    var session = try startedSession()
    let attempt = try #require(session.connection.attempt)
    let accepted1 = session.receiveSimulation(.connected, attempt: attempt)
    #expect(accepted1)
    let history = session.connection.history.map(\.id)
    let accepted2 = !session.receiveSimulation(.connected, attempt: attempt)
    #expect(accepted2)
    let accepted3 = !session.receiveSimulation(.timedOut, attempt: attempt)
    #expect(accepted3)
    let accepted4 = !session.receiveSimulation(.authenticationFailed, attempt: attempt)
    #expect(accepted4)
    #expect(session.connection.history.map(\.id) == history)
    #expect(session.connection.state.rawValue.contains("不代表 VPN 已连接"))
    let accepted5 = session.receiveSimulation(.connectionLost, attempt: attempt)
    #expect(accepted5)
    #expect(session.connection.state == .failed && session.connection.failure == .connectionLost)
    let accepted6 = !session.receiveSimulation(.connected, attempt: attempt)
    #expect(accepted6)
}

@Test(arguments: [SimulationSignal.timedOut, .authenticationFailed])
func simulationFailureHasNoAutomaticRetryOrLateSuccess(_ signal: SimulationSignal) throws {
    var session = try startedSession()
    let old = try #require(session.connection.attempt)
    let accepted7 = !session.receiveSimulation(.connectionLost, attempt: old)
    #expect(accepted7)
    let accepted8 = session.receiveSimulation(signal, attempt: old)
    #expect(accepted8)
    #expect(session.connection.state == .failed && session.connection.canStart)
    #expect(!session.connection.canStop && session.connection.attempt == nil)
    let accepted9 = !session.receiveSimulation(.connected, attempt: old)
    #expect(accepted9)
    #expect(session.connection.history.count == 3)
    _ = try session.beginSimulation()
    let new = try #require(session.connection.attempt)
    #expect(new.id != old.id && new.context != old.context)
    let accepted10 = !session.receiveSimulation(.connected, attempt: old)
    #expect(accepted10)
    let accepted11 = session.receiveSimulation(.connected, attempt: new)
    #expect(accepted11)
}

@Test(arguments: [0, 1, 2, 3, 4, 5])
func simulationRejectsEveryMismatchedIdentity(_ field: Int) throws {
    var session = try startedSession()
    let valid = try #require(session.connection.attempt)
    let c = valid.context
    let forged = SimulationAttempt(id: field == 0 ? UUID() : valid.id,
        profileID: field == 1 ? UUID() : valid.profileID,
        context: PlanContext(sessionID: field == 2 ? "different" : c.sessionID,
            backendID: field == 3 ? "different" : c.backendID,
            generation: field == 4 ? c.generation + 1 : c.generation,
            networkEpoch: field == 5 ? c.networkEpoch + 1 : c.networkEpoch))
    let accepted12 = !session.receiveSimulation(.connected, attempt: forged)
    #expect(accepted12)
    #expect(session.connection.state == .connecting && session.connection.history.count == 2)
}

@Test func simulationCancellationFencesCallbacksBeforeStopCompletes() throws {
    var session = try startedSession()
    let attempt = try #require(session.connection.attempt)
    let requestedStop13 = session.requestSimulationStop()
    let stop = try #require(requestedStop13)
    #expect(session.connection.state == .stopping && session.connection.attempt == nil)
    #expect(!session.connection.canStop && !session.connection.canStart)
    let accepted14 = session.requestSimulationStop() == nil
    #expect(accepted14)
    #expect(throws: SimulationCommandError.alreadyActive) { try session.beginSimulation() }
    let accepted15 = !session.receiveSimulation(.connected, attempt: attempt)
    #expect(accepted15)
    let accepted16 = !session.receiveSimulation(.timedOut, attempt: attempt)
    #expect(accepted16)
    let accepted17 = !session.finishSimulationStop(token: UUID())
    #expect(accepted17)
    let accepted18 = session.finishSimulationStop(token: stop)
    #expect(accepted18)
    #expect(session.connection.state == .cancelled && session.connection.failure == nil)
    let accepted19 = !session.finishSimulationStop(token: stop)
    #expect(accepted19)
    #expect(session.connection.canStart && session.connection.startTitle == "重试模拟")
}

@Test func simulationStopAfterConnectedIsNotCancellationOrAuthenticationFailure() throws {
    var session = try startedSession()
    let attempt = try #require(session.connection.attempt)
    let accepted20 = session.receiveSimulation(.connected, attempt: attempt)
    #expect(accepted20)
    #expect(session.connection.stopTitle == "停止模拟")
    let requestedStop21 = session.requestSimulationStop()
    let stop = try #require(requestedStop21)
    let accepted22 = !session.receiveSimulation(.connectionLost, attempt: attempt)
    #expect(accepted22)
    let accepted23 = session.finishSimulationStop(token: stop)
    #expect(accepted23)
    #expect(session.connection.state == .idle && session.connection.failure == nil)
    #expect(session.connection.history.last?.note == .stopped)
    #expect(session.preview != nil) // Intention remains useful; never installed.
}

@Test func simulationTimeoutWinningRaceCannotBeOverwrittenByStopOrSuccess() throws {
    var session = try startedSession()
    let attempt = try #require(session.connection.attempt)
    let accepted24 = session.receiveSimulation(.timedOut, attempt: attempt)
    #expect(accepted24)
    let accepted25 = session.requestSimulationStop() == nil
    #expect(accepted25)
    let accepted26 = !session.receiveSimulation(.connected, attempt: attempt)
    #expect(accepted26)
    #expect(session.connection.failure == .timeout)
}

@Test func simulationSuccessfulSaveInvalidatesButFailedSavePreservesState() throws {
    var session = try startedSession()
    let old = try #require(session.connection.attempt)
    let store = SimulationStore(session.workspace)
    let preview = session.preview?.plan
    var next = session.workspace; next.profiles[0].rules.reverse()
    store.rejectSave = true
    #expect(throws: DraftError.writeFailed) { try session.commit(next, store: store) }
    #expect(session.workspace == store.value && session.connection.attempt == old && session.preview?.plan == preview)
    store.rejectSave = false
    try session.commit(next, store: store)
    #expect(session.connection.state == .idle && session.preview == nil)
    #expect(session.connection.history.last?.note == .configurationChanged)
    let accepted27 = !session.receiveSimulation(.connected, attempt: old)
    #expect(accepted27)
}

@Test func simulationSelectionAndRecheckInvalidateIdentityWithoutTouchingWorkspace() throws {
    let first = simulationProfile(), other = ProfileDraft(name: "Other")
    var session = LocalSession(workspace: Workspace(profiles: [first, other]))
    let data = try JSONEncoder().encode(session.workspace)
    _ = try session.beginSimulation()
    let attempt = try #require(session.connection.attempt)
    session.select(first.id); session.select(UUID())
    #expect(session.connection.attempt == attempt)
    session.select(other.id)
    let accepted28 = !session.receiveSimulation(.connected, attempt: attempt)
    #expect(accepted28)
    #expect(session.connection.history.last?.note == .selectionChanged)
    _ = try session.beginSimulation()
    let beforeCheck = try #require(session.connection.attempt)
    try session.compile()
    let accepted29 = !session.receiveSimulation(.connected, attempt: beforeCheck)
    #expect(accepted29)
    #expect(session.connection.state == .idle)
    #expect(try JSONDecoder().decode(Workspace.self, from: data) == session.workspace)
}

@Test(arguments: [SimulationNote.editing, .credentials, .environmentChanged, .exiting])
func simulationExplicitInvalidationsRejectBothConnectAndStopCallbacks(_ reason: SimulationNote) throws {
    var session = try startedSession()
    let attempt = try #require(session.connection.attempt)
    let requestedStop30 = session.requestSimulationStop()
    let stop = try #require(requestedStop30)
    session.invalidate(reason: reason)
    #expect(session.connection.history.last?.note == reason)
    #expect(session.preview == nil && session.connection.state == .idle)
    let accepted31 = !session.finishSimulationStop(token: stop)
    #expect(accepted31)
    let accepted32 = !session.receiveSimulation(.connected, attempt: attempt)
    #expect(accepted32)
}

@Test func simulationDeletionAndRestartNeverRestoreRuntimeState() throws {
    var session = try startedSession()
    let store = SimulationStore(session.workspace)
    let id = try #require(session.selectedID)
    let attempt = try #require(session.connection.attempt)
    try CredentialOperations.remove(profileID: id, deleteProfile: true, removeMetadata: true, session: &session, store: store)
    #expect(session.connection.state == .idle && session.selectedID == nil)
    let accepted33 = !session.receiveSimulation(.connected, attempt: attempt)
    #expect(accepted33)
    let restarted = LocalSession(workspace: try store.load())
    #expect(restarted.connection.history.isEmpty && restarted.connection.state == .idle)
}

@Test func simulationHistoryIsBoundedStaticAndClearDoesNotCancelAttempt() throws {
    var session = try startedSession()
    for _ in 0..<40 {
        session.invalidate()
        _ = try session.beginSimulation()
    }
    let attempt = try #require(session.connection.attempt)
    #expect(session.connection.history.count == MockConnection.historyLimit)
    let text = session.connection.history.map(\.note.rawValue).joined()
    #expect(!text.contains("198.51.100") && !text.contains("Synthetic"))
    session.clearSimulationHistory()
    #expect(session.connection.attempt == attempt && session.connection.history.isEmpty)
    let accepted34 = session.receiveSimulation(.connected, attempt: attempt)
    #expect(accepted34)
    let json = try JSONEncoder().encode(session.workspace)
    let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
    #expect(!object.keys.contains("connection") && !object.keys.contains("history"))
}

@Test func simulationParameterSavePreservesRulesButInvalidatesAttempt() throws {
    let key = Data(repeating: 9, count: 32).base64EncodedString()
    let metadata = try WireGuardImport.parse(Data("""
    [Interface]
    PrivateKey = \(key)
    Address = 10.9.0.2/32
    [Peer]
    PublicKey = \(Data(repeating: 10, count: 32).base64EncodedString())
    Endpoint = 203.0.113.9:51820
    AllowedIPs = 10.9.0.0/16
    """.utf8))
    var profile = ProfileDraft(rules: [DraftRule(value: "10.9.4.5")]); profile.wireGuard = metadata
    var session = LocalSession(workspace: Workspace(profiles: [profile], schemaVersion: 2))
    let store = SimulationStore(session.workspace)
    _ = try session.beginSimulation()
    let attempt = try #require(session.connection.attempt)
    var edit = try DraftEdit.parameterEdit(profile); edit.parameters?.mtu = "1380"
    // No credential is associated: this save does not need a vault operation.
    try WGParameterOperations.save(edit, session: &session, store: store, vault: KeychainCredentialVault())
    #expect(session.profile?.rules == profile.rules && session.profile?.wireGuard?.mtu == 1380)
    #expect(session.preview == nil && session.connection.state == .idle)
    let accepted35 = !session.receiveSimulation(.connected, attempt: attempt)
    #expect(accepted35)
}

@Test func simulationPeerAndEndpointConflictsStillBlockBeforeBackendTimers() throws {
    let key = Data(repeating: 9, count: 32).base64EncodedString()
    let metadata = try WireGuardImport.parse(Data("""
    [Interface]
    PrivateKey = \(key)
    Address = 10.9.0.2/32
    [Peer]
    PublicKey = \(Data(repeating: 10, count: 32).base64EncodedString())
    Endpoint = 203.0.113.9:51820
    AllowedIPs = 10.9.0.0/16
    """.utf8))
    var profile = ProfileDraft(rules: [DraftRule(value: "198.51.100.7")]); profile.wireGuard = metadata
    var session = LocalSession(workspace: Workspace(profiles: [profile], schemaVersion: 2))
    #expect(throws: PolicyCompilationError.self) { try session.beginSimulation() }
    #expect(session.connection.attempt == nil && session.connection.failure == .policyCheck)
    var parameters = WGParameterDraft(metadata)
    parameters.peers[0].endpoint = "10.9.4.5:51820"
    profile.wireGuard = try parameters.metadata(replacing: metadata)
    profile.rules = [DraftRule(value: "10.9.4.5")]
    session = LocalSession(workspace: Workspace(profiles: [profile], schemaVersion: 2))
    do {
        _ = try session.beginSimulation()
        Issue.record("Expected endpoint conflict")
    } catch let error as PolicyCompilationError {
        #expect(error.diagnostics.contains { $0.code == .infrastructureConflict })
    }
    #expect(session.connection.attempt == nil && session.preview == nil)
}

@MainActor
private final class ManualSimulationScheduler: SimulationScheduling {
    final class Ticket: SimulationCancellation {
        var cancelled = false
        func cancel() { cancelled = true }
    }
    struct Event {
        let fireAt: Duration
        let delay: Duration
        let ticket: Ticket
        let action: @MainActor @Sendable () -> Void
    }
    var now: Duration = .zero
    var events: [Event] = []
    func schedule(after delay: Duration, action: @escaping @MainActor @Sendable () -> Void) -> any SimulationCancellation {
        let ticket = Ticket(); events.append(Event(fireAt: now + delay, delay: delay, ticket: ticket, action: action)); return ticket
    }
    func fire(_ index: Int, includingCancelled: Bool = false) {
        let event = events[index]
        // Forced callbacks test stale queue delivery without advancing the virtual clock.
        if !includingCancelled { now = max(now, event.fireAt) }
        if includingCancelled || !event.ticket.cancelled { event.action() }
    }
}

@Test @MainActor func driverNormalSuccessCancelsDeadlineAndRejectsQueuedDuplicate() throws {
    let scheduler = ManualSimulationScheduler()
    let tested = SimulationDriver(scheduler: scheduler)
    tested.cancel() // Cancellation before start is valid.
    var session = try startedSession()
    let attempt = try #require(session.connection.attempt)
    tested.start(attempt, scenario: .success) { session.receiveSimulation($1, attempt: $0) }
    #expect(scheduler.events.map(\.delay) == [.seconds(3), .seconds(1)])
    scheduler.fire(1)
    #expect(session.connection.state == .connected && !tested.isRunning)
    #expect(scheduler.events[0].ticket.cancelled)
    scheduler.fire(0, includingCancelled: true); scheduler.fire(1, includingCancelled: true)
    #expect(session.connection.state == .connected && session.connection.history.count == 3)
}

@Test @MainActor func driverIndependentDeadlineEndsNonRespondingBackend() throws {
    let scheduler = ManualSimulationScheduler(), session = try startedSession()
    let driver = SimulationDriver(scheduler: scheduler)
    let attempt = try #require(session.connection.attempt)
    var received: [SimulationSignal] = []
    driver.start(attempt, scenario: .timeout) { _, signal in received.append(signal) }
    #expect(scheduler.events.count == 1)
    scheduler.fire(0)
    #expect(received == [.timedOut] && !driver.isRunning)
    scheduler.fire(0, includingCancelled: true)
    #expect(received == [.timedOut])
}

@Test @MainActor func driverTimeoutWinsAgainstQueuedLateSuccess() throws {
    let scheduler = ManualSimulationScheduler(), session = try startedSession()
    let driver = SimulationDriver(scheduler: scheduler)
    let attempt = try #require(session.connection.attempt)
    var received: [SimulationSignal] = []
    driver.start(attempt, scenario: .success) { _, signal in received.append(signal) }
    scheduler.fire(0); scheduler.fire(1, includingCancelled: true)
    #expect(received == [.timedOut])
}

@Test @MainActor func driverAuthenticationFailureAndDropAreDistinct() throws {
    let scheduler = ManualSimulationScheduler()
    let tested = SimulationDriver(scheduler: scheduler)
    var session = try startedSession()
    tested.start(try #require(session.connection.attempt), scenario: .authenticationFailure) { session.receiveSimulation($1, attempt: $0) }
    scheduler.fire(1)
    #expect(session.connection.failure == .authentication && !tested.isRunning)
    _ = try session.beginSimulation()
    tested.start(try #require(session.connection.attempt), scenario: .disconnectAfterSuccess) { session.receiveSimulation($1, attempt: $0) }
    scheduler.fire(3)
    #expect(session.connection.state == .connected && tested.isRunning)
    scheduler.fire(4)
    #expect(session.connection.failure == .connectionLost && !tested.isRunning)
    #expect(scheduler.events.count == 5) // No automatic reconnect scheduled.
}

@Test @MainActor func driverCancelDuringConnectCompletesOnlyNewStopToken() throws {
    let scheduler = ManualSimulationScheduler()
    let tested = SimulationDriver(scheduler: scheduler)
    var session = try startedSession()
    tested.start(try #require(session.connection.attempt), scenario: .disconnectAfterSuccess) { session.receiveSimulation($1, attempt: $0) }
    let requestedStop36 = session.requestSimulationStop()
    let stop = try #require(requestedStop36)
    tested.stop(token: stop) { session.finishSimulationStop(token: $0) }
    #expect(session.connection.state == .stopping)
    scheduler.fire(1, includingCancelled: true); scheduler.fire(0, includingCancelled: true)
    #expect(session.connection.state == .stopping && scheduler.events.count == 3)
    scheduler.fire(2)
    #expect(session.connection.state == .cancelled && !tested.isRunning)
}

@Test @MainActor func driverSameAttemptReuseStillHasIndependentGenerationFence() throws {
    let scheduler = ManualSimulationScheduler(), session = try startedSession()
    let driver = SimulationDriver(scheduler: scheduler)
    let attempt = try #require(session.connection.attempt)
    var received: [SimulationSignal] = []
    driver.start(attempt, scenario: .authenticationFailure) { _, signal in received.append(signal) }
    driver.start(attempt, scenario: .success) { _, signal in received.append(signal) }
    scheduler.fire(1, includingCancelled: true); scheduler.fire(0, includingCancelled: true)
    #expect(received.isEmpty && driver.isRunning)
    scheduler.fire(3)
    #expect(received == [.connected] && !driver.isRunning)
}

@Test @MainActor func driverReentrantCancellationCannotScheduleDrop() throws {
    let scheduler = ManualSimulationScheduler(), session = try startedSession()
    let driver = SimulationDriver(scheduler: scheduler)
    var received: [SimulationSignal] = []
    driver.start(try #require(session.connection.attempt), scenario: .disconnectAfterSuccess) { _, signal in
        received.append(signal); driver.cancel()
    }
    scheduler.fire(1)
    #expect(received == [.connected] && scheduler.events.count == 2 && !driver.isRunning)
}

@Test @MainActor func driverReleasedOwnerReceivesNoLateEvents() throws {
    let scheduler = ManualSimulationScheduler(), session = try startedSession()
    var driver: SimulationDriver? = SimulationDriver(scheduler: scheduler)
    weak var weakDriver = driver
    var received: [SimulationSignal] = []
    driver?.start(try #require(session.connection.attempt), scenario: .success) { _, signal in received.append(signal) }
    driver = nil
    #expect(weakDriver == nil)
    scheduler.fire(0, includingCancelled: true); scheduler.fire(1, includingCancelled: true)
    #expect(received.isEmpty)
}

@Test @MainActor func nativeTaskSchedulerFiresAndHonoursImmediateCancellation() async throws {
    let scheduler = TaskSimulationScheduler()
    var fired = 0
    let cancelled = scheduler.schedule(after: .milliseconds(5)) { fired += 100 }
    cancelled.cancel()
    let active = scheduler.schedule(after: .milliseconds(5)) { fired += 1 }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while fired == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(fired == 1)
    active.cancel()
    try await Task.sleep(for: .milliseconds(10))
    #expect(fired == 1)
}

@Test @MainActor func driverOverdueSuccessCannotBeatDelayedDeadlineOnBusyActor() throws {
    let scheduler = ManualSimulationScheduler(), session = try startedSession()
    let driver = SimulationDriver(scheduler: scheduler)
    var received: [SimulationSignal] = []
    driver.start(try #require(session.connection.attempt), scenario: .success) { _, signal in received.append(signal) }
    scheduler.now = .seconds(4)
    scheduler.fire(1) // Success timer dequeues first, but the absolute deadline has passed.
    scheduler.fire(0, includingCancelled: true)
    #expect(received == [.timedOut] && !driver.isRunning)
}
