# SPDX-License-Identifier: MIT
"""WG-INT-03 exact contextual adapter guard, after the mandatory policy hook.

No system calls are executed here. The native candidate remains build-only.
"""
from __future__ import annotations
from pathlib import Path
from policy_hook import git_blob, PATCHED_ADAPTER_BLOB

SUPPORT_PATH = 'Packages/WireGuardSupport/Sources/WireGuardSupport/SettingsCompletion.swift'

OLD_SETTINGS = '''    private func setNetworkSettings(_ networkSettings: NEPacketTunnelNetworkSettings) throws {
        var systemError: Error?
        let condition = NSCondition()

        // Activate the condition
        condition.lock()
        defer { condition.unlock() }

        self.packetTunnelProvider?.setTunnelNetworkSettings(networkSettings) { error in
            systemError = error
            condition.signal()
        }

        // Packet tunnel's `setTunnelNetworkSettings` times out in certain
        // scenarios & never calls the given callback.
        let setTunnelNetworkSettingsTimeout: TimeInterval = 5 // seconds

        if condition.wait(until: Date().addingTimeInterval(setTunnelNetworkSettingsTimeout)) {
            if let systemError = systemError {
                throw WireGuardAdapterError.setNetworkSettings(systemError)
            }
        } else {
            self.logHandler(.error, "setTunnelNetworkSettings timed out after 5 seconds; proceeding anyway")
        }
    }
'''
NEW_SETTINGS = '''    private func setNetworkSettings(_ networkSettings: NEPacketTunnelNetworkSettings) throws {
        guard let provider = packetTunnelProvider else {
            markForProviderReset()
            throw WireGuardAdapterError.missingProvider
        }
        let completion = SplitterSettingsCompletion(deadline: .now() + .seconds(5))
        provider.setTunnelNetworkSettings(networkSettings) { error in
            completion.complete(error: error)
        }
        switch completion.wait() {
        case .success: return
        case .failure(let error):
            markForProviderReset()
            throw WireGuardAdapterError.setNetworkSettings(error)
        case .timedOut:
            markForProviderReset()
            throw WireGuardAdapterError.networkSettingsTimedOut
        }
    }

    // Work-queue only. An uncertain OS request cannot safely be retried in place.
    // Stop known protocol work, but do NOT claim the system settings were removed.
    // The future Provider controller must terminate the session and observe teardown.
    private func markForProviderReset() {
        requiresProviderReset = true
        networkMonitor?.cancel()
        networkMonitor = nil
        if case .started(let handle, _) = state { wgTurnOff(handle) }
        state = .stopped
    }

    private func checkedSetConfig(handle: Int32, configuration: String) throws {
        let result = wgSetConfig(handle, configuration)
        guard result == 0 else {
            markForProviderReset()
            throw WireGuardAdapterError.updateWireGuardBackend(result)
        }
    }
'''


def replace_once(text: str, before: str, after: str) -> str:
    if text.count(before) != 1:
        raise ValueError('E_WG_RUNTIME_PATCH_CONTEXT')
    return text.replace(before, after)


def transform_runtime(text: str) -> str:
    text = replace_once(text, '    case policyNetworkSettings(Error)\n',
        '    case policyNetworkSettings(Error)\n\n'
        '    case missingProvider\n'
        '    case networkSettingsTimedOut\n'
        '    case providerResetRequired\n'
        '    case updateWireGuardBackend(Int64)\n')
    text = replace_once(text, '    private var state: State = .stopped\n',
        '    private var state: State = .stopped\n'
        '    // Never cleared on this instance; timeout is not an OS cancellation.\n'
        '    private var requiresProviderReset = false\n')
    for method in ['start(tunnelConfiguration: TunnelConfiguration, completionHandler: @escaping (WireGuardAdapterError?) -> Void)',
                   'update(tunnelConfiguration: TunnelConfiguration, completionHandler: @escaping (WireGuardAdapterError?) -> Void)',
                   'stop(completionHandler: @escaping (WireGuardAdapterError?) -> Void)']:
        before = '    public func ' + method + ' {\n        workQueue.async {\n'
        text = replace_once(text, before, before +
            '            guard !self.requiresProviderReset else {\n'
            '                completionHandler(.providerResetRequired)\n'
            '                return\n'
            '            }\n')
    text = replace_once(text, OLD_SETTINGS, NEW_SETTINGS)
    text = replace_once(text,
        '    /// This method ensures that the call to `setTunnelNetworkSettings` does not time out, as in\n'
        '    /// certain scenarios the completion handler given to it may not be invoked by the system.\n',
        '    /// A missing/error/late completion fails the adapter; timeout is not rollback.\n')
    text = replace_once(text, '                    wgSetConfig(handle, wgConfig)\n',
        '                    try self.checkedSetConfig(handle: handle, configuration: wgConfig)\n')
    text = replace_once(text, '                wgSetConfig(handle, wgConfig)\n',
        '                do { try checkedSetConfig(handle: handle, configuration: wgConfig) }\n'
        '                catch {\n'
        '                    logHandler(.error, "Protocol update failed; provider reset required")\n'
        '                    return\n'
        '                }\n')
    text = replace_once(text, '    private func didReceivePathUpdate(path: Network.NWPath) {\n',
        '    private func didReceivePathUpdate(path: Network.NWPath) {\n'
        '        guard !requiresProviderReset else { return }\n')
    text = replace_once(text, '            throw WireGuardAdapterError.cannotLocateTunnelFileDescriptor\n',
        '            markForProviderReset()\n'
        '            throw WireGuardAdapterError.cannotLocateTunnelFileDescriptor\n')
    text = replace_once(text, '            throw WireGuardAdapterError.startWireGuardBackend(handle)\n',
        '            markForProviderReset()\n'
        '            throw WireGuardAdapterError.startWireGuardBackend(handle)\n')
    if 'proceeding anyway' in text or 'NSCondition()' in text or '.generateNetworkSettings()' in text:
        raise ValueError('E_WG_RUNTIME_FALLBACK')
    return text


def patch_runtime_adapter(data: bytes) -> bytes:
    if git_blob(data) != PATCHED_ADAPTER_BLOB:
        raise ValueError('E_WG_RUNTIME_INPUT_CHANGED')
    result = transform_admission(transform_runtime(data.decode('utf-8'))).encode('utf-8')
    if git_blob(result) != RUNTIME_ADAPTER_BLOB:
        raise ValueError('E_WG_ADMISSION_RESULT_CHANGED')
    return result


def checked_support(root: Path, lock: dict) -> bytes:
    source = root / SUPPORT_PATH
    if source.is_symlink():
        raise ValueError('E_WG_SETTINGS_SUPPORT_CHANGED')
    data = source.read_bytes()
    if git_blob(data) != lock['settings_completion_blob']:
        raise ValueError('E_WG_SETTINGS_SUPPORT_CHANGED')
    hook = root / 'tools/wireguard/runtime_hook.py'
    if hook.is_symlink() or git_blob(hook.read_bytes()) != lock['runtime_hook_blob']:
        raise ValueError('E_WG_RUNTIME_HOOK_CHANGED')
    return data

# WG-INT-05: fixed after the earlier two stages. No descriptor discovery fallback.
RUNTIME_ADAPTER_BLOB = 'd349ebe6eb7e07062cb1cf4007dada150465c008'

BINDING_SOURCE = '''
// VPN-Splitter: one immutable protocol snapshot per Provider session.
// Not an OS ownership proof. The currentRevision closure must observe the live
// controller, be thread-safe and invalidate this binding on every state change.
public final class SplitterWireGuardBinding: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    private let expectedInterface: InterfaceConfiguration
    private let expectedPeers: [PeerConfiguration]
    private let gate: SplitterRevisionGate
    private let currentRevision: () -> SplitterRuntimeRevision?
    fileprivate var providerInstance: UUID { gate.expected.providerInstance }

    public init(configuration: TunnelConfiguration, revision: SplitterRuntimeRevision,
                currentRevision: @escaping () -> SplitterRuntimeRevision?) {
        expectedInterface = configuration.interface
        expectedPeers = configuration.peers
        gate = SplitterRevisionGate(expected: revision)
        self.currentRevision = currentRevision
    }

    public func invalidate() { gate.invalidate() }
    fileprivate func checkCurrent() throws { try gate.check(current: currentRevision()) }

    // Do not use TunnelConfiguration ==: upstream treats peers and AllowedIPs
    // as sets. Policy binding preserves their order and all original key fields.
    fileprivate func checkedCopy(matching request: TunnelConfiguration) throws -> TunnelConfiguration {
        try checkCurrent()
        guard expectedInterface == request.interface,
              expectedInterface.addresses == request.interface.addresses,
              expectedPeers.count == request.peers.count else {
            invalidate(); throw SplitterAdmissionError.configurationChanged
        }
        for (expected, current) in zip(expectedPeers, request.peers) {
            guard expected == current, expected.allowedIPs == current.allowedIPs else {
                invalidate(); throw SplitterAdmissionError.configurationChanged
            }
        }
        try checkCurrent()
        // Fresh reference; a settings factory cannot mutate the UAPI generator's object.
        // Display name and runtime byte/handshake counters are not policy inputs.
        return TunnelConfiguration(name: nil, interface: expectedInterface, peers: expectedPeers)
    }

    public var description: String { "SplitterWireGuardBinding(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
'''


def replace_section(text: str, start: str, end: str, replacement: str) -> str:
    if text.count(start) != 1 or text.count(end) != 1:
        raise ValueError('E_WG_ADMISSION_PATCH_CONTEXT')
    first, last = text.index(start), text.index(end)
    if last <= first:
        raise ValueError('E_WG_ADMISSION_PATCH_CONTEXT')
    return text[:first] + replacement + text[last:]


def transform_admission(text: str) -> str:
    text = replace_once(text, '    case updateWireGuardBackend(Int64)\n',
                        '    case updateWireGuardBackend(Int64)\n    case runtimeAdmission\n')
    text = replace_once(text, '    private var requiresProviderReset = false\n',
        '    private var requiresProviderReset = false\n'
        '    private let runtimeBinding: SplitterWireGuardBinding\n'
        '    private let tunnelDescriptorProvider: () throws -> SplitterTunnelDescriptorLease\n'
        '    private let interfaceLock = NSLock()\n'
        '    private var boundInterfaceName: String?\n')
    text = replace_section(text, '    /// Tunnel device file descriptor.\n',
        '    /// Returns a WireGuard version.\n', '')
    text = replace_section(text, '    /// Returns the tunnel device interface name, or nil on error.\n',
        '    // MARK: - Initialization\n', '''    /// Last explicitly bound interface, not the first utun found in this process.
    public var interfaceName: String? {
        interfaceLock.lock(); defer { interfaceLock.unlock() }
        return boundInterfaceName
    }

    private func recordInterface(_ name: String?) {
        interfaceLock.lock(); boundInterfaceName = name; interfaceLock.unlock()
    }

''')
    text = replace_once(text,
        '                networkSettingsProvider: @escaping (TunnelConfiguration) throws -> NEPacketTunnelNetworkSettings,\n',
        '                runtimeBinding: SplitterWireGuardBinding,\n'
        '                tunnelDescriptorProvider: @escaping () throws -> SplitterTunnelDescriptorLease,\n'
        '                networkSettingsProvider: @escaping (TunnelConfiguration) throws -> NEPacketTunnelNetworkSettings,\n')
    text = replace_once(text, '        self.networkSettingsProvider = networkSettingsProvider\n',
        '        self.networkSettingsProvider = networkSettingsProvider\n'
        '        self.runtimeBinding = runtimeBinding\n'
        '        self.tunnelDescriptorProvider = tunnelDescriptorProvider\n')
    text = replace_once(text, '    deinit {\n', '    deinit {\n        runtimeBinding.invalidate()\n')
    text = replace_once(text, '            self.state = .stopped\n\n            completionHandler(nil)\n',
        '            self.state = .stopped\n'
        '            self.runtimeBinding.invalidate()\n'
        '            self.recordInterface(nil)\n\n'
        '            completionHandler(nil)\n')
    text = replace_once(text, '        requiresProviderReset = true\n',
        '        requiresProviderReset = true\n'
        '        runtimeBinding.invalidate()\n'
        '        recordInterface(nil)\n')
    text = replace_section(text,
        '    private func policyNetworkSettings(_ generator: PacketTunnelSettingsGenerator)',
        '    private func setNetworkSettings(_ networkSettings:', '''    private func policyNetworkSettings(_ generator: PacketTunnelSettingsGenerator) throws -> NEPacketTunnelNetworkSettings {
        do {
            let request = try runtimeBinding.checkedCopy(matching: generator.tunnelConfiguration)
            let settings = try networkSettingsProvider(request)
            _ = try runtimeBinding.checkedCopy(matching: request)
            return settings
        } catch {
            markForProviderReset()
            throw WireGuardAdapterError.runtimeAdmission
        }
    }

    private func checkAdmission() throws {
        do { try runtimeBinding.checkCurrent() }
        catch { markForProviderReset(); throw WireGuardAdapterError.runtimeAdmission }
    }

''')
    anchor = '                try self.setNetworkSettings(self.policyNetworkSettings(settingsGenerator))\n'
    if text.count(anchor) != 3:
        raise ValueError('E_WG_ADMISSION_SETTINGS_SITES')
    text = text.replace(anchor, anchor + '                try self.checkAdmission()\n')
    text = replace_once(text, '        let result = wgSetConfig(handle, configuration)\n',
        '        try checkAdmission()\n        let result = wgSetConfig(handle, configuration)\n')
    text = replace_once(text, '            throw WireGuardAdapterError.updateWireGuardBackend(result)\n        }\n',
        '            throw WireGuardAdapterError.updateWireGuardBackend(result)\n        }\n        try checkAdmission()\n')
    text = replace_once(text, '        guard !requiresProviderReset else { return }\n',
        '        guard !requiresProviderReset else { return }\n'
        '        do { try checkAdmission() } catch { return }\n')
    text = replace_section(text, '    private func startWireGuardBackend(wgConfig: String)',
        '    /// Resolves the hostnames in the given tunnel configuration', '''    private func startWireGuardBackend(wgConfig: String) throws -> Int32 {
        do {
            try checkAdmission()
            let lease = try tunnelDescriptorProvider()
            defer { lease.close() }
            let handle = try lease.withFileDescriptor(for: runtimeBinding.providerInstance) { descriptor in
                try checkAdmission()
                let started = wgTurnOn(wgConfig, descriptor)
                guard started >= 0 else { throw WireGuardAdapterError.startWireGuardBackend(started) }
                do { try runtimeBinding.checkCurrent() }
                catch {
                    // Not yet in state: release the newly returned handle explicitly.
                    wgTurnOff(started)
                    throw WireGuardAdapterError.runtimeAdmission
                }
                return started
            }
            recordInterface(lease.interfaceName)
            #if os(iOS)
            wgDisableSomeRoamingForBrokenMobileSemantics(handle)
            #endif
            return handle
        } catch {
            markForProviderReset()
            if let error = error as? WireGuardAdapterError { throw error }
            throw WireGuardAdapterError.runtimeAdmission
        }
    }

''')
    text = replace_section(text, '    private func makeSettingsGenerator(with tunnelConfiguration:',
        '    /// Log DNS resolution results.', '''    private func makeSettingsGenerator(with tunnelConfiguration: TunnelConfiguration) throws -> PacketTunnelSettingsGenerator {
        do {
            let approved = try runtimeBinding.checkedCopy(matching: tunnelConfiguration)
            let endpoints = try resolvePeers(for: approved)
            try checkAdmission()
            return PacketTunnelSettingsGenerator(tunnelConfiguration: approved, resolvedEndpoints: endpoints)
        } catch {
            markForProviderReset()
            if let error = error as? WireGuardAdapterError { throw error }
            throw WireGuardAdapterError.runtimeAdmission
        }
    }

''')
    if any(token in text for token in ['for fd:', 'self.tunnelFileDescriptor', '.generateNetworkSettings()']):
        raise ValueError('E_WG_ADMISSION_FALLBACK')
    return text + BINDING_SOURCE
