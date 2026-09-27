// SPDX-License-Identifier: MIT
// Actual listener/liveness source; framework and broker are explicit doubles.
@main
private struct XPCListenerHarness {
    @MainActor
    static func main() async throws {
        let broker = ManagedDeliveryBroker()
        let host = ManagedXPCListener(identity: ManagedNativeIdentity(), broker: broker)
        host.start()
        func accept() -> (NSXPCConnection, ManagedXPCExport) {
            let connection = NSXPCConnection()
            precondition(host.listener(host.listener, shouldAcceptNewConnection: connection))
            return (connection, connection.exportedObject as! ManagedXPCExport)
        }
        let (idle, idleExport) = accept()
        let (running, runningExport) = accept()
        broker.active.insert(runningExport.id)
        // Wait for the real timeout branch, accelerated only in the test copy.
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while (idle.invalidations == 0 || !broker.expiryChecks.contains(runningExport.id)) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(idle.invalidations == 1 && !idleExport.alive.isLive())
        precondition(broker.closed.contains(idleExport.id))
        precondition(broker.expiryChecks.contains(runningExport.id))
        precondition(running.invalidations == 0 && runningExport.alive.isLive())
        // Expiring an older connection must not invalidate a new, unrelated ID.
        let (newConnection, newExport) = accept()
        broker.active.insert(newExport.id)
        host.end(idleExport.id)
        precondition(newConnection.invalidations == 0)
        // Explicit end removes exactly once; synchronous invalidation re-enters remove.
        host.end(runningExport.id); host.end(runningExport.id)
        precondition(running.invalidations == 1 && !runningExport.alive.isLive())
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !broker.closed.contains(runningExport.id) && ContinuousClock.now < closeDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        precondition(broker.closed.contains(runningExport.id))
        precondition(newConnection.invalidations == 0 && newExport.alive.isLive())
        host.end(newExport.id)
        print("xpc-listener=PASS source=ACTUAL framework_broker=TEST_DOUBLES timer=ACCELERATED native_auth=NOT_TESTED")
    }
}
