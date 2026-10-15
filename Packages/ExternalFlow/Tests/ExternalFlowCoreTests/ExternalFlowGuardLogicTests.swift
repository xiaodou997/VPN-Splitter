// SPDX-License-Identifier: MIT
import XCTest
@testable import ExternalFlowCore

final class ExternalFlowGuardLogicTests: XCTestCase {
    func testRouteFormLossPausesImmediatelyAndRecoveryResumes() {
        var guard_ = ExternalFlowGuardLogic()
        XCTAssertEqual(guard_.onRouteForm(available: true), .stay)
        XCTAssertEqual(guard_.onRouteForm(available: false), .pauseRouteFormLost)
        XCTAssertEqual(guard_.paused, .routeFormLost)
        // Repeated losses do not re-emit; probes are ignored while paused by route form.
        XCTAssertEqual(guard_.onRouteForm(available: false), .stay)
        XCTAssertEqual(guard_.onRouteForm(available: true), .resume)
        XCTAssertNil(guard_.paused)
        XCTAssertEqual(guard_.onRouteForm(available: true), .stay)
    }
    func testVPNPathDeadRequiresTwoConsecutiveFailures() {
        var guard_ = ExternalFlowGuardLogic()
        XCTAssertEqual(guard_.onProbe(vpnPathOK: false), .stay)
        XCTAssertNil(guard_.paused)
        XCTAssertEqual(guard_.onProbe(vpnPathOK: false), .pauseVPNPathDead)
        XCTAssertEqual(guard_.paused, .vpnPathDead)
        XCTAssertEqual(guard_.onProbe(vpnPathOK: false), .stay)
    }
    func testSingleFailureThenSuccessNeverPauses() {
        var guard_ = ExternalFlowGuardLogic()
        XCTAssertEqual(guard_.onProbe(vpnPathOK: false), .stay)
        XCTAssertEqual(guard_.onProbe(vpnPathOK: true), .stay)
        XCTAssertEqual(guard_.onProbe(vpnPathOK: false), .stay)
        XCTAssertNil(guard_.paused)
    }
    func testProbePauseResumesOnFirstSuccess() {
        var guard_ = ExternalFlowGuardLogic()
        _ = guard_.onProbe(vpnPathOK: false)
        _ = guard_.onProbe(vpnPathOK: false)
        XCTAssertEqual(guard_.paused, .vpnPathDead)
        XCTAssertEqual(guard_.onProbe(vpnPathOK: true), .resume)
        XCTAssertNil(guard_.paused)
    }
    func testRouteFormLossOverridesProbePauseAndRecoveryResumes() {
        var guard_ = ExternalFlowGuardLogic()
        _ = guard_.onProbe(vpnPathOK: false)
        _ = guard_.onProbe(vpnPathOK: false)
        XCTAssertEqual(guard_.paused, .vpnPathDead)
        XCTAssertEqual(guard_.onRouteForm(available: false), .pauseRouteFormLost)
        XCTAssertEqual(guard_.paused, .routeFormLost)
        XCTAssertEqual(guard_.onRouteForm(available: true), .resume)
    }
    func testRouteFormRecoveryDoesNotClearProbePause() {
        var guard_ = ExternalFlowGuardLogic()
        _ = guard_.onProbe(vpnPathOK: false)
        _ = guard_.onProbe(vpnPathOK: false)
        XCTAssertEqual(guard_.onRouteForm(available: true), .stay)
        XCTAssertEqual(guard_.paused, .vpnPathDead)
    }
    func testManualPauseIsNotTrackedOrCleared() {
        // The logic only resumes pauses it issued itself; a manual pause is
        // invisible here, so no action is emitted for it.
        var guard_ = ExternalFlowGuardLogic()
        _ = guard_.onProbe(vpnPathOK: false)
        _ = guard_.onProbe(vpnPathOK: false)
        _ = guard_.onProbe(vpnPathOK: true)
        XCTAssertNil(guard_.paused)
        XCTAssertEqual(guard_.onRouteForm(available: true), .stay)
    }
}
