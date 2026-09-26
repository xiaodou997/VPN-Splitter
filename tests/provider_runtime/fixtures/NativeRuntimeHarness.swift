// SPDX-License-Identifier: MIT
import Foundation
import ProviderSession

@main struct NativeRuntimeHarness {
    @MainActor static func wait(_ test: () -> Bool) async {
        for _ in 0..<400 {
            if test() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        fatalError("runtime harness timed out")
    }
    @MainActor static func main() async throws {
        let trace = Trace.shared
        for scenario in 0..<6 {
            trace.reset()
            let authorization = ManagedRunAuthorization(connectionIsLive: { true })
            let received = ManagedReceivedConfiguration(authorization: authorization)
            let provider = NEPacketTunnelProvider()
            var input = CheckedManagedWireGuardInput()
            if scenario == 5 { input.metadata.mtu = 500 }
            let session = try ManagedPacketFlowSession.make(provider: provider, input: input, received: received,
                event: { trace.record($0) })
            var start: Result<Void, ProviderSessionFailure>?
            session.start { start = $0 }
            if scenario == 5 {
                await wait { start != nil && trace.read().contains("finishRun") }
                precondition(!trace.read().contains("apply")); continue
            }
            await wait { trace.read().contains("apply") }
            precondition(!trace.read().contains("engineStart"))
            if scenario == 1 {
                session.stop { _ in }
                await wait { start != nil }
                precondition(!trace.read().contains("clear"))
                trace.complete(apply: true)
            } else {
                trace.complete(apply: true, success: scenario != 4)
                await wait { start != nil }
                if scenario != 4 { precondition(trace.read().contains("engineStart")) }
                switch scenario {
                case 2: authorization.invalidate()
                case 3: ManagedUnderlayMonitor.latest?.changed?()
                default: session.stop { _ in }
                }
            }
            await wait { trace.read().contains("clear") }
            if trace.read().contains("engineStart") {
                let events = trace.read()
                precondition(events.firstIndex(of: "apply")! < events.firstIndex(of: "engineStart")!)
                precondition(events.firstIndex(of: "engineStop")! < events.firstIndex(of: "clear")!)
            } else { precondition(scenario == 1 || scenario == 4) }
            trace.complete(apply: false)
            await wait { trace.read().contains("finishRun") }
            precondition(trace.read().contains("backend_quiescent_network_restore_NOT_OBSERVED"))
        }
        print("runtime-host=PASS scenarios=6 controller_settings_host=ACTUAL apple_underlay_models_engine=TEST_DOUBLES network=NOT_APPLIED")
    }
}
