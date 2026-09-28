# SPDX-License-Identifier: MIT
"""Compile the actual ExternalModel and check its task lifetimes without network IO.

The model body is extracted unchanged from the macOS source, not the Linux fallback.
Reader, planner and observation types are explicit test doubles. macOS uses actual
SwiftUI Published/ObservableObject; other hosts use minimal wrappers. This is not a
full app/SDK build or an External routing test. Some older Swift compilers do not
emit ImplicitStrongCapture: the capture contract also guards that spelling directly.
"""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Packages/ExternalCore/Sources/ExternalPreview/ExternalPreviewApp.swift'
EXPLICIT = 'operation = Task { @MainActor [self] in'
IMPLICIT = 'operation = Task { @MainActor in'

DOUBLES = r'''
import Foundation
#if os(macOS)
import SwiftUI
#else
protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> {
    var wrappedValue: Value
    init(wrappedValue: Value) { self.wrappedValue = wrappedValue }
}
#endif

// Synthetic data models and planner: no routes, sockets, credentials or system reads.
struct ExternalObservation: Sendable {
    let id: UUID
    let capturedAtUptime: TimeInterval
}
enum ExternalCore {
    struct ExternalPreview: Sendable { let observationID: UUID }
}
enum ExternalError: String, Error, Sendable {
    case readFailed
    var message: String { "synthetic read failure" }
}
struct ExternalRouteParseDiagnostic: Error, Sendable {
    let message: String
}
enum ExternalPlanner {
    static func preview(_ text: String, observation: ExternalObservation,
                        now: TimeInterval) throws -> ExternalCore.ExternalPreview {
        .init(observationID: observation.id)
    }
    static func topology(_ observation: ExternalObservation, now: TimeInterval) throws {}
}

// Deliberately allow late completion after cancellation to exercise the real fences.
actor CaptureFixture {
    static let shared = CaptureFixture()
    private var pending: [Int: CheckedContinuation<ExternalObservation, any Error>] = [:]
    private(set) var count = 0
    private(set) var returned = 0
    func capture() async throws -> ExternalObservation {
        let value: ExternalObservation = try await withCheckedThrowingContinuation {
            count += 1
            pending[count] = $0
        }
        returned += 1
        return value
    }
    func finish(_ index: Int, value: ExternalObservation) {
        guard let continuation = pending.removeValue(forKey: index) else {
            fatalError("test request missing")
        }
        continuation.resume(returning: value)
    }
    func fail(_ index: Int) {
        guard let continuation = pending.removeValue(forKey: index) else {
            fatalError("test request missing")
        }
        continuation.resume(throwing: ExternalError.readFailed)
    }
}
actor ExternalSystemReader {
    func capture() async throws -> ExternalObservation {
        try await CaptureFixture.shared.capture()
    }
}
'''

HARNESS = r'''
@main @MainActor struct PreviewCaptureHarness {
    static func require(_ condition: Bool, _ reason: String) {
        if !condition { fatalError(reason) }
    }
    static func waitUntil(_ predicate: @MainActor () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await predicate()) {
            require(ContinuousClock.now < deadline, "test condition timed out")
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    static func snapshot(age: Double = 0) -> ExternalObservation {
        .init(id: UUID(), capturedAtUptime: ProcessInfo.processInfo.systemUptime - age)
    }
    static func settle() async throws {
        for _ in 0..<10 { await Task.yield() }
        try await Task.sleep(for: .milliseconds(30))
    }
    static func main() async throws {
        let scenario = CommandLine.arguments[1]
        let fixture = CaptureFixture.shared
        switch scenario {
        case "operation-retains-expiry-does-not":
            var model: ExternalModel? = ExternalModel()
            weak var observedModel = model
            require(await fixture.count == 0, "creating the model must not collect")
            model!.detect(previewRules: false)
            await Task.yield()
            try await waitUntil { await fixture.count == 1 }
            model = nil
            require(observedModel != nil, "in-flight operation lost its existing strong capture")
            await fixture.finish(1, value: snapshot())
            try await waitUntil { observedModel == nil }
        case "cancel-rejects-late-read":
            let model = ExternalModel()
            model.detect(previewRules: false)
            try await waitUntil { await fixture.count == 1 }
            model.cancel()
            let message = model.message
            await fixture.finish(1, value: snapshot())
            try await waitUntil { await fixture.returned == 1 }
            try await settle()
            require(!model.busy && model.observation == nil && model.preview == nil,
                    "cancelled read repopulated UI")
            require(model.message == message, "cancel message overwritten")
        case "old-read-cannot-clear-new-operation":
            let model = ExternalModel()
            model.detect(previewRules: false)
            try await waitUntil { await fixture.count == 1 }
            model.cancel()
            model.detect(previewRules: false)
            try await waitUntil { await fixture.count == 2 }
            await fixture.finish(1, value: snapshot())
            try await waitUntil { await fixture.returned == 1 }
            try await settle()
            require(model.busy && model.observation == nil, "old defer cleared new operation")
            let current = snapshot()
            await fixture.finish(2, value: current)
            try await waitUntil { !model.busy }
            require(model.observation?.id == current.id, "new observation not published")
            model.cancel()
        case "expiry-clears-snapshot":
            let model = ExternalModel()
            model.detect(previewRules: false)
            try await waitUntil { await fixture.count == 1 }
            await fixture.finish(1, value: snapshot(age: 29.5))
            try await waitUntil { !model.busy }
            try await waitUntil { model.observation == nil }
            require(model.message.hasPrefix("快照已过期"), "expiry did not run")
        case "edit-invalidates-preview":
            let model = ExternalModel()
            model.rules = "synthetic rule"
            model.detect(previewRules: true)
            try await waitUntil { await fixture.count == 1 }
            let current = snapshot()
            await fixture.finish(1, value: current)
            try await waitUntil { !model.busy }
            require(model.preview?.observationID == current.id, "preview not published")
            model.rules = "different synthetic rule"
            require(model.preview == nil, "edited preview stayed valid")
            model.cancel()
        case "failure-releases-operation":
            let model = ExternalModel()
            model.detect(previewRules: false)
            try await waitUntil { await fixture.count == 1 }
            await fixture.fail(1)
            try await waitUntil { !model.busy }
            require(model.observation == nil && model.preview == nil, "failed read published data")
            require(model.message.contains("readFailed"), "failure not displayed")
        default: fatalError("unknown test scenario")
        }
        print("preview-capture=PASS scenario=\(scenario) model=ACTUAL reader_planner=TEST_DOUBLES network=NOT_READ")
    }
}
'''

SCENARIOS = (
    'operation-retains-expiry-does-not',
    'cancel-rejects-late-read',
    'old-read-cannot-clear-new-operation',
    'expiry-clears-snapshot',
    'edit-invalidates-preview',
    'failure-releases-operation',
)


def actual_model(source: str) -> str:
    start = '@MainActor\nfinal class ExternalModel: ObservableObject {'
    end = '\n@main\nstruct ExternalPreviewApp: App {'
    if source.count(start) != 1 or source.count(end) != 1:
        raise AssertionError('ExternalModel boundary changed; review extraction')
    return source[source.index(start):source.index(end)]


class PreviewCaptureTests(unittest.TestCase):
    def assert_capture_contract(self, source: str) -> None:
        model = actual_model(source)
        self.assertEqual(model.count(EXPLICIT), 1)
        self.assertNotIn(IMPLICIT, model)
        self.assertEqual(model.count('expiry = Task { @MainActor [weak self] in'), 1)
        self.assertIn('defer { if token == id { busy = false; operation = nil } }', model)

    def test_explicit_outer_capture_and_weak_expiry_contract(self):
        source = SOURCE.read_text()
        self.assert_capture_contract(source)
        # This guard still catches a regression on compilers predating the diagnostic.
        with self.assertRaises(AssertionError):
            self.assert_capture_contract(source.replace(EXPLICIT, IMPLICIT))

    def compile_and_run(self, optimization: str) -> None:
        body = actual_model(SOURCE.read_text())
        with tempfile.TemporaryDirectory(prefix='external-model-capture-') as directory:
            root = Path(directory)
            source = root / 'ModelHarness.swift'
            source.write_text(DOUBLES + '\n' + body + '\n' + HARNESS)
            executable = root / 'harness'
            result = subprocess.run([
                'swiftc', '-swift-version', '6', '-strict-concurrency=complete',
                '-warnings-as-errors', optimization, '-parse-as-library',
                str(source), '-o', str(executable)
            ], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            for scenario in SCENARIOS:
                with self.subTest(optimization=optimization, scenario=scenario):
                    result = subprocess.run([str(executable), scenario], capture_output=True,
                                            text=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertIn('preview-capture=PASS scenario=' + scenario, result.stdout)

    def test_actual_model_debug_lifetimes(self):
        self.compile_and_run('-Onone')

    def test_actual_model_optimized_lifetimes(self):
        self.compile_and_run('-O')


if __name__ == '__main__':
    unittest.main()
