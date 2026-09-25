// SPDX-License-Identifier: MIT
import Foundation
import Dispatch
import Testing
@testable import WireGuardSupport

private enum TestFailure: Error { case denied, other }
private func succeeded(_ result: SplitterSettingsCompletion.Outcome) -> Bool {
    if case .success = result { return true }; return false
}
private func expired(_ result: SplitterSettingsCompletion.Outcome) -> Bool {
    if case .timedOut = result { return true }; return false
}

@Test func synchronousSuccessBeforeWaitingIsNotLost() {
    let gate = SplitterSettingsCompletion(deadline: .now() + .seconds(5))
    #expect(gate.complete(error: nil))
    #expect(succeeded(gate.wait()))
}

@Test func synchronousErrorIsPreserved() {
    let gate = SplitterSettingsCompletion(deadline: .now() + .seconds(5))
    #expect(gate.complete(error: TestFailure.denied))
    guard case .failure(let error) = gate.wait() else { Issue.record("Expected error"); return }
    #expect(error as? TestFailure == .denied)
}

@Test func noCallbackEndsAtDeadline() {
    let gate = SplitterSettingsCompletion(deadline: .now() + .milliseconds(10))
    #expect(expired(gate.wait()))
    #expect(!gate.complete(error: nil))
}

@Test func expiredSuccessCannotWinEvenBeforeWaitStarts() {
    let gate = SplitterSettingsCompletion(deadline: DispatchTime(uptimeNanoseconds: 1))
    #expect(!gate.complete(error: nil))
    #expect(expired(gate.wait()))
}

@Test func expiredErrorCannotReplaceTimeout() {
    let gate = SplitterSettingsCompletion(deadline: DispatchTime(uptimeNanoseconds: 1))
    #expect(!gate.complete(error: TestFailure.denied))
    #expect(expired(gate.wait()))
}

@Test func duplicateCallbackCannotChangeSuccess() {
    let gate = SplitterSettingsCompletion(deadline: .now() + .seconds(5))
    #expect(gate.complete(error: nil))
    #expect(!gate.complete(error: TestFailure.other))
    #expect(succeeded(gate.wait()))
}

@Test func duplicateSuccessCannotHideFirstError() {
    let gate = SplitterSettingsCompletion(deadline: .now() + .seconds(5))
    #expect(gate.complete(error: TestFailure.denied))
    #expect(!gate.complete(error: nil))
    guard case .failure(let error) = gate.wait() else { Issue.record("Expected error"); return }
    #expect(error as? TestFailure == .denied)
}

@Test func independentRequestsCannotCompleteEachOther() {
    let old = SplitterSettingsCompletion(deadline: DispatchTime(uptimeNanoseconds: 1))
    let current = SplitterSettingsCompletion(deadline: .now() + .seconds(5))
    #expect(expired(old.wait()))
    #expect(!old.complete(error: nil))
    #expect(current.complete(error: nil))
    #expect(succeeded(current.wait()))
}

@Test func completionOnAnotherQueueWakesWaitingThread() {
    let gate = SplitterSettingsCompletion(deadline: .now() + .seconds(5))
    let done = DispatchGroup(); done.enter()
    DispatchQueue.global().async {
        _ = gate.complete(error: nil)
        done.leave()
    }
    #expect(succeeded(gate.wait()))
    #expect(done.wait(timeout: .now() + .seconds(5)) == .success)
}

@Test func concurrentCallbacksConsumeOneResult() {
    for _ in 0..<50 {
        let gate = SplitterSettingsCompletion(deadline: .now() + .seconds(5))
        let done = DispatchGroup()
        for index in 0..<8 {
            done.enter()
            DispatchQueue.global().async {
                _ = gate.complete(error: index % 2 == 0 ? nil : TestFailure.denied)
                done.leave()
            }
        }
        let result = gate.wait()
        #expect(!expired(result))
        #expect(done.wait(timeout: .now() + .seconds(5)) == .success)
        #expect(!gate.complete(error: TestFailure.other))
    }
}

@Test func timeoutCallbackRaceAlwaysTerminatesAndRejectsFurtherResults() {
    for _ in 0..<50 {
        let gate = SplitterSettingsCompletion(deadline: .now() + .microseconds(100))
        let done = DispatchGroup(); done.enter()
        DispatchQueue.global().async { _ = gate.complete(error: nil); done.leave() }
        let result = gate.wait()
        #expect(succeeded(result) || expired(result))
        #expect(done.wait(timeout: .now() + .seconds(5)) == .success)
        #expect(!gate.complete(error: nil))
    }
}

@Test func callbackClosureCanOutliveWaiterWithoutOwningAdapter() {
    let gate = SplitterSettingsCompletion(deadline: DispatchTime(uptimeNanoseconds: 1))
    let callback: @Sendable ((any Error)?) -> Void = { error in _ = gate.complete(error: error) }
    #expect(expired(gate.wait()))
    callback(nil)
    callback(TestFailure.other)
    #expect(!gate.complete(error: nil))
}
