"""LD-02B static integration contracts; NOT native Security.framework or GUI tests."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "Packages/AppCore/Sources/AppCore"
UI = (ROOT / "apps/macos/LocalDev/LocalDevApp.swift").read_text()
NATIVE = (CORE / "KeychainCredentialVault.swift").read_text()
CREDENTIALS = (CORE / "Credentials.swift").read_text()


class CredentialContractTests(unittest.TestCase):
    def test_only_one_native_boundary(self):
        for path in CORE.glob("*.swift"):
            if path.name != "KeychainCredentialVault.swift":
                for symbol in ["SecItemAdd(", "SecItemCopyMatching(", "SecItemDelete("]:
                    self.assertNotIn(symbol, path.read_text(), path.name)
        self.assertIn("#if os(macOS)", NATIVE)
        self.assertIn("import Security", NATIVE)
        self.assertIn("throw CredentialError.unavailable", NATIVE)

    def test_scoped_file_based_keychain_without_acl_weakening(self):
        self.assertIn('com.vpnsplitter.localdev.wireguard.v1', NATIVE)
        self.assertEqual(NATIVE.count("kSecUseDataProtectionKeychain as String: false"), 3)
        for forbidden in ["kSecAttrAccessGroup", "kSecAttrSynchronizable", "SecAccessCreate", "SecItemUpdate(", "Process(", "kSecMatchLimitAll", "print(", "Logger("]:
            self.assertNotIn(forbidden, NATIVE)
        self.assertIn("kSecAttrAccount as String: reference.id.uuidString", NATIVE)

    def test_readback_and_ownership_before_precise_delete(self):
        self.assertIn("read(reference).record == record", NATIVE)
        deletion = NATIVE.split("public func removeOwned")[1].split("private struct Item")[0]
        self.assertLess(deletion.index("item.record.check(reference: reference)"), deletion.index("SecItemDelete("))
        self.assertIn("kSecValuePersistentRef as String: item.persistentReference", deletion)
        self.assertIn("kSecAttrService as String: Self.service", deletion)
        self.assertIn("kSecAttrAccount as String: reference.id.uuidString", deletion)
        self.assertIn("catch CredentialError.missing { return }", deletion)
        self.assertNotIn("catch {", deletion)

    def test_no_startup_keychain_access_or_cleanup(self):
        initialization = UI.split("    init() {")[1].split("    func select")[0]
        self.assertIn("WorkspaceLease(directory:", initialization)
        self.assertIn("store.load()", initialization)
        for forbidden in ["CredentialOperations.", "KeychainCredentialVault()", "SecItem"]:
            self.assertNotIn(forbidden, initialization)

    def test_new_import_requires_explicit_opt_in_and_confirmation(self):
        self.assertIn("@State private var persistCredentials = false", UI)
        self.assertIn('Toggle("同时把凭据保存到本机 Keychain"', UI)
        self.assertIn("model.confirmImport(id: pending.id, persistCredentials: persistCredentials)", UI)
        self.assertIn("pending.id == id", UI)
        self.assertIn("仅保存结构会解除并尝试清理", UI)

    def test_blocking_native_work_is_not_on_main_actor(self):
        self.assertIn("Task.detached(priority: .userInitiated)", UI)
        self.assertIn("self.session = result.0; self.keychainBusy = false", UI)
        self.assertIn("guard !choosingImport, !keychainBusy else { return false }", UI)
        self.assertIn("!quitAfterEditorDismissal && !keychainBusy", UI)
        self.assertIn(".disabled(model.keychainBusy)", UI)

    def test_failed_save_keeps_report_and_exposes_recovery(self):
        self.assertIn("onSuccess: { [weak self] in self?.pendingImport = nil }", UI)
        self.assertIn("if result.1 { onSuccess() }", UI)
        self.assertGreaterEqual(UI.count("model.retryCredentialCleanup()"), 2)
        self.assertIn("only: old", UI)
        self.assertIn("only: reference", UI)

    def test_journal_precedes_keychain_and_final_commit(self):
        save = CREDENTIALS.split("public static func save(")[1].split("public static func remove(")[0]
        self.assertLess(save.index("try publish(staged"), save.index("try vault.create"))
        self.assertLess(save.index("try vault.verify"), save.index("try publish(committed"))
        self.assertIn("guard session.workspace.cleanupQueue.isEmpty", save)
        self.assertIn("transaction.applying(to: session.workspace, reference: nil)", save)

    def test_no_vault_calls_on_unlink_until_after_persistence(self):
        unlink = CREDENTIALS.split("public static func remove(")[1].split("public static func cleanup(")[0]
        self.assertIn("next.enqueueCleanup(reference)", unlink)
        self.assertIn("try publish(next", unlink)
        self.assertNotIn("vault.", unlink)
        cleanup = CREDENTIALS.split("public static func cleanup(")[1].split("extension Workspace")[0]
        self.assertIn("profiles.contains(where:", cleanup)
        self.assertLess(cleanup.index("try vault.removeOwned"), cleanup.index("try publish(next"))

    def test_secret_containers_have_no_codable_public_surface(self):
        for name in ["WGCredentialMaterial", "CredentialImportTransaction"]:
            declaration = CREDENTIALS.split("public struct " + name + ":")[1].split("{")[0]
            self.assertNotIn("Codable", declaration)
            self.assertIn("CustomReflectable", declaration)
        self.assertIn("KeychainRecord(<redacted>)", CREDENTIALS)
        self.assertIn("private let payload:", CREDENTIALS)

    def test_lease_is_nonblocking_and_does_not_unlink_locks(self):
        text = (CORE / "WorkspaceLease.swift").read_text()
        for required in ["O_NOFOLLOW", "O_NONBLOCK", "O_CLOEXEC", "LOCK_EX | LOCK_NB", "S_IFREG", "st_nlink == 1", "geteuid()"]:
            self.assertIn(required, text)
        self.assertNotIn("removeItem", text)
        self.assertIn("deinit { close(descriptor) }", text)

    def test_profile_controls_warn_and_do_not_promise_authentication(self):
        for label in ["仅移除凭据", "重新导入 WireGuard .conf", "检查 Keychain 读取", "未验证服务器认证", "Keychain 清理待重试", "本地开发模式：不接管网络"]:
            self.assertIn(label, UI)


if __name__ == "__main__":
    unittest.main()
