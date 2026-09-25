"""LD-03A static wiring checks; not native Keychain or GUI behaviour tests."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = (ROOT / "apps/macos/LocalDev/LocalDevApp.swift").read_text()
CORE = ROOT / "Packages/AppCore/Sources/AppCore"
PARAMETERS = (CORE / "WireGuardParameterEditing.swift").read_text()
NATIVE = (CORE / "KeychainCredentialVault.swift").read_text()


class ParameterContracts(unittest.TestCase):
    def test_explicit_parameter_editor_and_single_transaction(self):
        self.assertIn('Button("编辑参数")', UI)
        self.assertIn('begin(try .parameterEdit(profile))', UI)
        self.assertIn('WGParameterOperations.save(edit, session: &state', UI)
        self.assertIn('case .parameters: throw WGParameterError.transactionRequired', (CORE / 'DraftEditing.swift').read_text())

    def test_busy_blocks_editing_and_save_is_background_work(self):
        self.assertIn('Task.detached(priority: .userInitiated)', UI)
        update = UI.split('func updateEditor')[1].split('@discardableResult')[0]
        self.assertIn('guard !keychainBusy', update)
        self.assertIn('.frame(width: 540).disabled(model.keychainBusy)', UI)
        self.assertIn('self.editor.edit?.id == edit.id', UI)

    def test_dirty_parameter_quit_does_not_start_async_save(self):
        branch = UI.split('if editor.edit?.kind == .parameters {')[1].split('let alert = NSAlert()', 1)[1].split('let alert = NSAlert()', 1)[0]
        self.assertIn('放弃修改并退出', branch)
        self.assertIn('closeEditor(discard: true)', branch)
        self.assertNotIn('saveWireGuardParameters()', branch)

    def test_recovery_is_available_inside_editor(self):
        self.assertIn('Button("重试清理（不保存参数）")', UI)
        self.assertIn('model.retryParameterCleanup()', UI)
        self.assertIn('only: old', UI)
        self.assertIn('原 .conf 未修改', UI)

    def test_vault_rebind_has_identity_and_exact_metadata_guards(self):
        method = NATIVE.split('public func copyUpdatingParameters')[1].split('public func removeOwned')[0]
        self.assertIn('source.profileID == destination.profileID', method)
        self.assertIn('source.id != destination.id', method)
        self.assertLess(method.index('record.check(reference: source, metadata: expected)'), method.index('try create('))
        self.assertIn('WGParameterDraft.checkPreserved', method)
        self.assertIn('throw CredentialError.unavailable', method)

    def test_journal_precedes_copy_and_final_publish(self):
        self.assertLess(PARAMETERS.index('try publish(staged'), PARAMETERS.index('try vault.copyUpdatingParameters'))
        self.assertLess(PARAMETERS.index('try vault.verify'), PARAMETERS.index('try publish(next'))
        self.assertIn('session.profile == edit.baseline', PARAMETERS)
        self.assertIn('store.load() == session.workspace', PARAMETERS)
        self.assertIn('next.enqueueCleanup(old)', PARAMETERS)

    def test_fields_cannot_edit_peer_ranges_or_secret_keys(self):
        fields = UI.split('private func parameterFields')[1].split('private func batchFields')[0]
        for forbidden in ['TextField("PrivateKey', 'TextField("PublicKey', 'TextField("AllowedIPs', '.allowedIPs =', 'SecItem']:
            self.assertNotIn(forbidden, fields)
        self.assertIn('old.allowedIPs == new.allowedIPs', PARAMETERS)
        self.assertIn('old.hadPresharedKey == new.hadPresharedKey', PARAMETERS)
        self.assertIn('original.searchDomains == updated.searchDomains', PARAMETERS)

    def test_normal_layout_and_no_new_network_effects(self):
        self.assertIn('HSplitView {', UI)
        self.assertIn('LD-03B · 真实 VPN 未接入', UI)
        self.assertIn('本地开发模式：不接管网络', UI)
        for forbidden in ['import Network', 'URLSession', 'Process()', 'SecItem', 'print(', 'Logger(']:
            self.assertNotIn(forbidden, PARAMETERS)


if __name__ == '__main__':
    unittest.main()
