"""LD-02A static wiring checks; these are not Mac GUI or Keychain tests."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = (ROOT / "apps/macos/LocalDev/LocalDevApp.swift").read_text()
CORE = ROOT / "Packages/AppCore/Sources/AppCore"
IMPORT = (CORE / "WireGuardImport.swift").read_text()
PLAN = (CORE / "WireGuardPlanning.swift").read_text()


class WireGuardContractTests(unittest.TestCase):
    def test_import_requires_file_picker_and_confirmation(self):
        self.assertIn("let panel = NSOpenPanel()", UI)
        self.assertIn("panel.runModal() == .OK", UI)
        self.assertIn("WGImportFileReader.readCredentials(url)", UI)
        self.assertIn('Button(persistCredentials ? "保存结构与凭据" : "仅保存结构")', UI)
        self.assertIn("try CredentialOperations.save(pending, persistCredentials: persistCredentials,", UI)

    def test_editor_and_pending_import_are_mutually_exclusive(self):
        self.assertIn("editor.allowsWorkspaceActions && pendingImport == nil && !choosingImport", UI)
        self.assertIn("pending.id == id", UI)
        self.assertIn("WireGuardImportPane(model: model).interactiveDismissDisabled()", UI)

    def test_file_reader_has_bounded_nonblocking_regular_file_checks(self):
        for text in ["O_NOFOLLOW", "O_NONBLOCK", "O_CLOEXEC", "fstat", "S_IFREG", "WireGuardImport.byteLimit + 1"]:
            self.assertIn(text, IMPORT)
        self.assertNotIn("Data(contentsOf:", IMPORT)

    def test_keys_are_validated_but_metadata_has_no_key_payloads(self):
        peer = IMPORT.split("public struct WGPeerMetadata:")[1].split("public struct WGCompatibilityIssue:")[0]
        metadata = IMPORT.split("public struct WGMetadata:")[1].split("private enum WGValidation")[0]
        for declaration in [peer, metadata]:
            for forbidden in ["let privateKey:", "let publicKey:", "let presharedKey:", "let rawConfig:", "let sourceURL:"]:
                self.assertNotIn(forbidden, declaration)
        self.assertIn("publicKeys.insert(decoded).inserted", IMPORT)

    def test_native_keychain_is_isolated_from_ui_and_no_network_resolution(self):
        for text in [UI, IMPORT, PLAN]:
            for forbidden in ["SecItemAdd", "SecItemCopyMatching", "SecItemUpdate", "getaddrinfo", "URLSession", "Process()", "import NetworkExtension"]:
                self.assertNotIn(forbidden, text)

    def test_real_constraint_compiler_is_used_without_dropping_ipv6(self):
        self.assertIn("IPv4ConstrainedPolicyCompiler.compile", PLAN)
        self.assertIn("metadata.compatibilityIssues.contains(where:", PLAN)
        self.assertNotIn("compactMap", PLAN)
        for role in [".vpnEndpoint", ".vpnDNS", ".localAddress"]:
            self.assertIn(role, PLAN)

    def test_preview_uses_constrained_output_and_discloses_limits(self):
        session = (CORE / "LocalSession.swift").read_text()
        self.assertIn("constrainedPlan?.overrides ?? plan.overrides", session)
        self.assertIn("constrainedPlan.decision(for: address)", session)
        self.assertIn("未探测物理网关/局域网", PLAN)
        self.assertIn("preview.overrides.count", UI)

    def test_schema_upgrade_only_happens_on_confirmed_import(self):
        self.assertIn("next.schemaVersion = max(next.schemaVersion, 2)", PLAN)
        self.assertIn("guard current == baseline", PLAN)
        self.assertIn("try session.commit(next, store: store)", PLAN)
        self.assertIn("session.select(id)", PLAN)

    def test_quit_and_cancel_do_not_save_import_implicitly(self):
        cancel = UI.split("func cancelImport()")[1].split("func retryCredentialCleanup")[0]
        self.assertIn("guard !keychainBusy", cancel)
        self.assertIn("pendingImport = nil", cancel)
        self.assertNotIn("CredentialOperations.save", cancel)
        self.assertIn("let wasEditing = editor.edit != nil || pendingImport != nil", UI)
        self.assertIn('alert.addButton(withTitle: "放弃导入并退出")', UI)

    def test_detach_warns_that_only_rule_intent_remains(self):
        self.assertIn("此后仅能检查规则意图，不再检查 Peer 或配置基础设施", UI)
        self.assertIn(".disabled(edit.baseline.wireGuard != nil)", UI)


if __name__ == "__main__":
    unittest.main()
