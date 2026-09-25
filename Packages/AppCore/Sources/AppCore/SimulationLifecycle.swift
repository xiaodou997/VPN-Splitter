// SPDX-License-Identifier: MIT
import Foundation
import PolicyCore

/// Every state is simulation-only. This model cannot attest to a real VPN connection.
public enum MockState: String, Sendable {
    case idle = "模拟：未开始（真实网络未接管）"
    case preparing = "模拟：检查配置中（真实网络未接管）"
    case connecting = "模拟：连接中（真实网络未接管）"
    case connected = "模拟：连接成功（不代表 VPN 已连接）"
    case stopping = "模拟：停止中（真实网络未接管）"
    case cancelled = "模拟：已取消（真实网络未接管）"
    case failed = "模拟：失败（真实网络未接管）"
}

public enum SimulationFailure: String, Sendable {
    case policyCheck, authentication, timeout, connectionLost
    public var message: String {
        switch self {
        case .policyCheck: "配置或规则检查未通过。请先在检查页修正问题，再重试模拟。"
        case .authentication: "模拟认证失败：这是注入的测试故障，没有联系服务器或读取 Keychain。"
        case .timeout: "模拟连接等待超时，已结束本次尝试；可以手动重试，不会自动重连。"
        case .connectionLost: "模拟连接已中断；不会继续显示成功，也不会自动重连。"
        }
    }
}

/// Fixed messages only: no names, targets, keychain references, arbitrary errors or keys.
public enum SimulationNote: String, Sendable {
    case checking = "检查已保存的配置与规则"
    case started = "开始一次模拟连接"
    case succeeded = "模拟后端返回成功；真实 VPN 未接入"
    case policyRejected = "本地检查拒绝本次模拟"
    case authenticationRejected = "注入模拟认证失败"
    case timedOut = "本次模拟连接超时"
    case connectionLost = "注入模拟连接中断"
    case cancelling = "收到取消请求，旧连接回调立即失效"
    case stopping = "收到停止请求，旧连接回调立即失效"
    case cancelled = "模拟已取消"
    case stopped = "模拟已停止"
    case configurationChanged = "本地配置已保存，旧模拟失效"
    case selectionChanged = "已切换策略，旧模拟失效"
    case rechecked = "重新检查规则，旧模拟失效"
    case editing = "进入编辑，旧模拟失效"
    case credentials = "开始凭据操作，旧模拟失效"
    case environmentChanged = "手动模拟网络变化；未进行系统网络探测"
    case exiting = "应用退出，结束内存中的模拟"
    case interrupted = "模拟已失效"
}

public struct SimulationTraceEntry: Identifiable, Sendable {
    public let id = UUID()
    public let note: SimulationNote
}

/// Identity of one attempt and exactly one compiled intention, not a network epoch probe.
public struct SimulationAttempt: Equatable, Sendable {
    public let id: UUID
    public let profileID: UUID
    public let context: PlanContext
}

public enum SimulationSignal: Equatable, Sendable {
    case connected, authenticationFailed, timedOut, connectionLost
}

public enum SimulationCommandError: Error, Sendable {
    case alreadyActive
    public var message: String { "模拟正在进行，请先取消或停止，不能重复启动。" }
}

/// The LocalSession owns the only lifecycle state. No timers, UI, I/O, or persisted state.
public struct MockConnection: Sendable {
    public private(set) var state: MockState = .idle
    public private(set) var failure: SimulationFailure?
    public private(set) var attempt: SimulationAttempt?
    public private(set) var history: [SimulationTraceEntry] = []
    public static let historyLimit = 32
    private var token: UUID?
    private var stopToken: UUID?
    private var stopWasCancellation = false

    public init() {}
    public var canStart: Bool { state == .idle || state == .failed || state == .cancelled }
    public var canStop: Bool { state == .preparing || state == .connecting || state == .connected }
    public var startTitle: String { state == .failed || state == .cancelled ? "重试模拟" : "开始模拟" }
    public var stopTitle: String { state == .connected ? "停止模拟" : (state == .stopping ? "正在停止" : "取消模拟") }

    mutating func prepare() {
        clearTokens(); failure = nil; state = .preparing; record(.checking)
    }

    // Low-level token replacement used by tests. UI starts only through LocalSession,
    // which rejects duplicate commands BEFORE checking or invalidating the current plan.
    mutating func begin() -> UUID {
        clearTokens(); failure = nil
        let next = UUID(); token = next; state = .connecting; record(.started)
        return next
    }

    mutating func bind(profileID: UUID, context: PlanContext) {
        guard let token, state == .connecting else { return }
        attempt = SimulationAttempt(id: token, profileID: profileID, context: context)
    }

    mutating func rejectPolicy() { fail(.policyCheck, note: .policyRejected) }

    @discardableResult
    mutating func receive(_ signal: SimulationSignal, attempt expected: SimulationAttempt) -> Bool {
        guard attempt == expected else { return false }
        switch signal {
        case .connected:
            guard state == .connecting, token == expected.id else { return false }
            token = nil; state = .connected; record(.succeeded)
        case .authenticationFailed:
            guard state == .connecting, token == expected.id else { return false }
            fail(.authentication, note: .authenticationRejected)
        case .timedOut:
            guard state == .connecting, token == expected.id else { return false }
            fail(.timeout, note: .timedOut)
        case .connectionLost:
            guard state == .connected else { return false }
            fail(.connectionLost, note: .connectionLost)
        }
        return true
    }

    // Compatibility for existing token-fencing regression tests; the UI uses typed signals.
    mutating func finish(token: UUID, success: Bool) {
        guard self.token == token, state == .connecting else { return }
        if success { self.token = nil; state = .connected; record(.succeeded) }
        else { fail(.authentication, note: .authenticationRejected) }
    }

    mutating func requestStop() -> UUID? {
        guard canStop else { return nil }
        stopWasCancellation = state != .connected
        clearTokens()
        let next = UUID(); stopToken = next
        state = .stopping
        record(stopWasCancellation ? .cancelling : .stopping)
        return next
    }

    @discardableResult
    mutating func finishStop(token: UUID) -> Bool {
        guard state == .stopping, stopToken == token else { return false }
        clearTokens(); failure = nil
        state = stopWasCancellation ? .cancelled : .idle
        record(stopWasCancellation ? .cancelled : .stopped)
        return true
    }

    mutating func cancel(reason: SimulationNote = .interrupted) {
        let changed = state != .idle || attempt != nil || stopToken != nil
        clearTokens(); state = .idle; failure = nil
        if changed { record(reason) }
    }

    mutating func clearHistory() { history.removeAll(keepingCapacity: false) }

    private mutating func fail(_ reason: SimulationFailure, note: SimulationNote) {
        clearTokens(); failure = reason; state = .failed; record(note)
    }
    private mutating func clearTokens() { token = nil; stopToken = nil; attempt = nil }
    private mutating func record(_ note: SimulationNote) {
        if history.count >= Self.historyLimit { history.removeFirst(history.count - Self.historyLimit + 1) }
        history.append(SimulationTraceEntry(note: note))
    }
}
