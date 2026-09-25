"""LD-03B wiring checks only. Swift tests exercise the reducer and scheduler; no Mac GUI proof."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]
CORE = ROOT / "Packages/AppCore/Sources/AppCore"
UI = (ROOT / "apps/macos/LocalDev/LocalDevApp.swift").read_text()
SESSION = (CORE / "LocalSession.swift").read_text()
DRIVER = (CORE / "SimulationDriver.swift").read_text()
STATE = (CORE / "SimulationLifecycle.swift").read_text()


class SimulationContracts(unittest.TestCase):
    def test_ui_uses_one_timer_driver_and_guarded_commands(self):
        self.assertIn("private let simulationDriver = SimulationDriver()", UI)
        self.assertNotIn("private var completion: Task", UI)
        start = UI.split("func simulate(scenario:", 1)[1].split("func cancel()", 1)[0]
        self.assertIn("guard canAct, session.connection.canStart", start)
        self.assertIn("try session.beginSimulation()", start)
        self.assertIn("simulationDriver.start(attempt, scenario: scenario)", start)
        self.assertIn("session.receiveSimulation(signal, attempt: attempt)", start)
        self.assertNotIn("KeychainCredentialVault", start)
        self.assertIn("session.requestSimulationStop()", UI)
        self.assertIn("simulationDriver.stop(token: token)", UI)

    def test_attempt_is_bound_to_real_compilation_and_full_context(self):
        start = SESSION.split("public mutating func beginSimulation()", 1)[1].split("@discardableResult", 1)[0]
        self.assertLess(start.index("guard connection.canStart"), start.index("preview = nil"))
        self.assertIn("try PolicyPreview.compile(profile)", start)
        self.assertIn("connection.bind(profileID: profile.id, context: compiled.plan.context)", start)
        receive = SESSION.split("public mutating func receiveSimulation", 1)[1].split("public mutating func finishSimulation", 1)[0]
        self.assertIn("selectedID == attempt.profileID", receive)
        self.assertIn("preview.plan.context.check(against: attempt.context) == .current", receive)
        self.assertIn("guard attempt == expected", STATE)

    def test_deadline_and_stale_callbacks_do_not_depend_only_on_task_cancel(self):
        self.assertIn("connectionTimeout: Duration = .seconds(3)", DRIVER)
        self.assertIn("let expiresAt = scheduler.now + Self.connectionTimeout", DRIVER)
        self.assertIn("guard self.scheduler.now < expiresAt", DRIVER)
        self.assertGreaterEqual(DRIVER.count("self.operationID == operation"), 4)
        self.assertIn("clock: .continuous", DRIVER)
        self.assertIn("guard !Task.isCancelled", DRIVER)
        cancel = DRIVER.split("    public func cancel()", 1)[1]
        self.assertLess(cancel.index("operationID = nil"), cancel.index("work?.cancel()"))

    def test_editor_credential_and_approved_exit_invalidate_simulation(self):
        self.assertIn("session.cancelSimulation(reason: .editing)", UI)
        self.assertIn("session.cancelSimulation(reason: .credentials)", UI)
        self.assertIn("invalidate(reason: .configurationChanged)", SESSION)
        self.assertIn("invalidate(reason: .selectionChanged)", SESSION)
        delegate = UI.split("func applicationShouldTerminate", 1)[1].split("@main", 1)[0]
        self.assertLess(delegate.index("model?.canQuit()"), delegate.index("model?.endSimulationForQuit()"))
        self.assertIn("session.cancelSimulation(reason: .exiting)", UI)

    def test_network_change_is_manual_not_a_probe(self):
        self.assertIn('Button("模拟网络变化")', UI)
        self.assertIn("session.invalidate(reason: .environmentChanged)", UI)
        self.assertIn("未进行系统网络探测", STATE)
        for text in [DRIVER, STATE]:
            for symbol in ["KeychainCredentialVault", "CredentialVault", "WGCredentialMaterial", "WGMetadata", "URLSession", "NetworkExtension", "Process(", "getaddrinfo", "NWPathMonitor", "SecItem"]:
                self.assertNotIn(symbol, text)

    def test_simulation_ui_is_folded_and_has_distinct_failures(self):
        tools = UI.split('DisclosureGroup("开发工具（模拟与合成示例）")', 1)[1].split('private struct EditorPane', 1)[0]
        for label in ['Picker("本次模拟场景"', 'simulation-start', 'simulation-stop', 'connection.failure', 'connection.history']:
            self.assertIn(label, tools)
        self.assertIn("LD-03B · 真实 VPN 未接入", UI)
        self.assertIn("不代表 VPN 已连接", STATE)
        self.assertIn("不会自动重连", STATE)
        self.assertIn("认证失败（注入）", DRIVER)
        self.assertIn("连接超时（不返回结果）", DRIVER)

    def test_trace_is_bounded_and_not_written_to_workspace(self):
        self.assertIn("historyLimit = 32", STATE)
        self.assertIn("history.removeFirst", STATE)
        self.assertNotIn("Codable", STATE)
        workspace = (CORE / "Drafts.swift").read_text()
        for field in ["Simulation", "MockState", "history:", "attempt:"]:
            self.assertNotIn(field, workspace)
        self.assertIn("case authenticationRejected", STATE)
        self.assertNotIn("print(", STATE)
        self.assertNotIn("Logger(", DRIVER)


if __name__ == "__main__":
    unittest.main()
