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
    return transform_runtime(data.decode('utf-8')).encode('utf-8')


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
