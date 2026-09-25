"""LD-02C source wiring checks; not a macOS rendering or UI automation result."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
UI = (ROOT / 'apps/macos/LocalDev/LocalDevApp.swift').read_text()
EDIT = (ROOT / 'Packages/AppCore/Sources/AppCore/DraftEditing.swift').read_text()


class LayoutBatchContracts(unittest.TestCase):
    def test_workspace_has_no_nested_navigation_toolbar(self):
        self.assertIn('HSplitView {', UI)
        self.assertNotIn('NavigationSplitView {', UI)
        self.assertNotIn('ignoresSafeArea', UI)
        self.assertNotIn('.offset(y:', UI)
        self.assertNotIn('safeAreaPadding', UI)
        self.assertIn('maxWidth: 300', UI)

    def test_fixed_header_and_controls_remain_outside_scrolling_content(self):
        pane = UI.split('private struct ProfilePane: View {', 1)[1]
        header = pane.split('if let metadata = profile.wireGuard', 1)[0]
        self.assertIn('accessibilityIdentifier("profile-title")', header)
        self.assertIn('accessibilityIdentifier("profile-settings")', header)
        self.assertIn('.fixedSize(horizontal: false, vertical: true)', header)
        self.assertNotIn('ScrollView', header)
        self.assertIn('LD-03B · 真实 VPN 未接入', UI)
        self.assertIn('本地开发模式：不接管网络', UI)

    def test_batch_uses_same_protected_editor(self):
        entry = UI.split('func openBatchRules()', 1)[1].split('private func begin', 1)[0]
        self.assertIn('guard canAct, let profile = session.profile', entry)
        self.assertIn('begin(.batch(profile))', entry)
        self.assertIn('TextEditor(text: field(\\.batchText, edit: edit))', UI)
        self.assertIn('case .batch: !batchText.isEmpty', EDIT)
        self.assertIn('try IPv4RuleBatch.parse(batchText)', EDIT)
        self.assertIn('try batch.appending(to: baseline.rules, action: batchAction)', EDIT)
        self.assertIn('workspace.profiles[index] == baseline', EDIT)

    def test_search_does_not_rebuild_policy_from_visible_rows(self):
        self.assertIn('ruleRow(profile.rules[index], index: index)', UI)
        self.assertIn('RuleSearch.indices(in: profile.rules, query: searchQuery)', UI)
        compile_method = UI.split('func compile()', 1)[1].split('private func reportCheck', 1)[0]
        self.assertIn('try session.compile()', compile_method)
        self.assertNotIn('searchQuery', compile_method)
        self.assertIn('.disabled(index == 0 || isSearching)', UI)
        self.assertIn('.disabled(index + 1 == profile.rules.count || isSearching)', UI)

    def test_normalization_and_all_or_nothing_are_disclosed(self):
        self.assertIn('可能覆盖整个网段；保存前请展开核对', UI)
        self.assertIn('不替换已有规则或改变默认出口', UI)
        self.assertIn('不自动去重', UI)
        self.assertIn('确认追加规则', UI)
        self.assertIn('规则未被删除', UI)


if __name__ == '__main__':
    unittest.main()
