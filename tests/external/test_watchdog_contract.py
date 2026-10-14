# SPDX-License-Identifier: MIT
"""EX-INT-07 watchdog contracts: read-only, prompt-only, explicit start.

The watchdog must stay a pure-logic classifier plus a user-started polling
model. It must never capture through new channels, write network state, call
the Helper/Flow planes, or start itself.
"""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / 'Packages/ExternalCore/Sources/ExternalCore/ExternalWatchdog.swift'
MODEL = ROOT / 'Packages/ExternalCore/Sources/ExternalPreview/ExternalWatchdogModel.swift'
APP = ROOT / 'Packages/ExternalCore/Sources/ExternalPreview/ExternalPreviewApp.swift'
NAVIGATION = ROOT / 'Packages/ExternalCore/Sources/ExternalPreview/ExternalNavigationView.swift'

class WatchdogContracts(unittest.TestCase):
    def test_tracker_is_pure_logic_over_existing_planner(self):
        source = CORE.read_text()
        for token in ['struct ExternalWatchdogTracker', 'enum ExternalWatchdogEvent', 'enum ExternalVPNHealth',
                      'ExternalPlanner.topology(', 'case vpnDisconnected', 'case vpnReconnected',
                      'case tunnelInterfaceChanged', 'case physicalPathLost', 'case observationFailed']:
            self.assertIn(token, source)
        # Pure logic: no capture channel, I/O, persistence or platform fork.
        for token in ['#if os(', 'Process(', 'netstat', 'SCDynamicStore', 'SCNetworkInterface', 'getifaddrs',
                      'NWConnection', 'URLSession', 'SecItem', 'write(to:', '/sbin/route', 'UserDefaults',
                      'FileManager', 'ExternalExecution']:
            self.assertNotIn(token, source)

    def test_model_is_explicit_start_and_prompt_only(self):
        source = MODEL.read_text()
        for token in ['func start()', 'func stop()', 'guard loop == nil', 'ExternalSystemReader',
                      'maximumEvents', 'Task.isCancelled']:
            self.assertIn(token, source)
        # No automatic start, no writes, no privileged or data-plane calls.
        for token in ['ExternalHelperModel', 'helper.', 'ExternalExecution', 'ExternalFlowBridge',
                      'write(to:', 'UserDefaults', 'Timer(', 'SCDynamicStoreSet', 'NETunnelProvider',
                      'NWConnection', 'init() {']:
            self.assertNotIn(token, source)

    def test_ui_wires_watchdog_without_changing_existing_contracts(self):
        app = APP.read_text()
        navigation = NAVIGATION.read_text()
        self.assertIn('ExternalWatchdogModel', app)
        self.assertIn('watchdog.stop()', app)          # sleep/wake shutdown
        self.assertIn('watchdog.start()', navigation)  # explicit button only
        self.assertIn('watchdog: watchdog', app)
        for token in ['.onAppear', '.task {', 'UserDefaults', '@AppStorage', 'write(to:', 'NSPasteboard']:
            self.assertNotIn(token, app + navigation)

if __name__ == '__main__': unittest.main()
