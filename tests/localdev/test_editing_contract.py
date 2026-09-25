"""LD-UI-01/02/03/04 wiring checks. Static contracts, not GUI behaviour tests."""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = (ROOT / "apps/macos/LocalDev/LocalDevApp.swift").read_text()
CORE = (ROOT / "Packages/AppCore/Sources/AppCore/DraftEditing.swift").read_text()


def method(name):
    match = re.search(r"    (?:private )?func " + name + r"\b", UI)
    if not match:
        raise AssertionError("Missing method: " + name)
    tail = UI[match.start():]
    end = re.search(r"\n    (?:@|(?:private )?func |//)", tail[1:])
    return tail[:end.start() + 1] if end else tail


class EditingContractTests(unittest.TestCase):
    def test_all_workspace_actions_are_guarded(self):
        for name in ["select", "commit", "addProfile", "deleteProfile", "changeRules",
                     "openSettings", "openRule", "compile", "simulate"]:
            with self.subTest(name=name):
                self.assertIn("guard canAct", method(name))

    def test_buffer_is_owned_by_model_not_replaceable_detail(self):
        self.assertIn("@Published private(set) var editor = DraftEditor()", UI)
        self.assertNotIn("@State private var rule", UI)
        self.assertNotIn("@State private var name", UI)
        self.assertIn(".disabled(!model.canAct)", UI)

    def test_modal_dismissal_cannot_discard_dirty_input(self):
        self.assertIn("EditorPane(model: model).interactiveDismissDisabled()", UI)
        self.assertIn("if !presented { _ = model.closeEditor() }", UI)
        self.assertIn("if !model.closeEditor() { confirmDiscard = true }", UI)
        self.assertIn('Button("放弃修改", role: .destructive)', UI)

    def test_menu_and_system_quit_use_shared_guard(self):
        self.assertIn("CommandGroup(replacing: .appTermination)", UI)
        self.assertIn("applicationShouldTerminate", UI)
        self.assertIn("model?.canQuit()", UI)
        self.assertIn("guard canQuit()", method("requestQuit"))
        self.assertIn("return saveEditor()", method("canQuit"))
        self.assertIn("onDismiss: { model.editorDidDismiss() }", UI)
        self.assertIn("guard quitAfterEditorDismissal", method("editorDidDismiss"))

    def test_editor_save_uses_tested_transaction(self):
        self.assertIn("try editor.save(session: &session, store: store)", method("saveEditor"))
        self.assertIn("value.id == id", CORE)
        self.assertIn("session.selectedID == edit.baseline.id", CORE)
        self.assertIn("workspace.profiles[index] == baseline", CORE)

    def test_developer_controls_are_folded(self):
        self.assertIn('DisclosureGroup("开发工具（模拟与合成示例）")', UI)
        self.assertIn('DisclosureGroup("其他草稿类型（开发选项）")', UI)
        self.assertIn('DisclosureGroup("范围与技术详情")', UI)

    def test_deletes_require_explicit_confirmation(self):
        self.assertIn('Button("确认删除", role: .destructive)', UI)
        self.assertIn('isPresented: $confirmDelete, titleVisibility: .visible', UI)
        self.assertIn("guard model.session.selectedID == profile.id", UI)

    def test_feedback_is_localized_and_rule_addressable(self):
        self.assertIn("PolicyFeedback.issues(error, profile: profile)", UI)
        self.assertIn("$0.ruleID == item.id", UI)
        self.assertIn('Button("编辑规则")', UI)
        self.assertIn("仅检查已保存的规则，不应用网络设置", UI)


if __name__ == "__main__":
    unittest.main()
