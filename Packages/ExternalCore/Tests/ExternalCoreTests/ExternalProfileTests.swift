// SPDX-License-Identifier: MIT
import Foundation
import XCTest
@testable import ExternalCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class ExternalProfileTests: XCTestCase {
    private func profile(_ name: String = "测试方案") -> ExternalSavedProfile {
        ExternalSavedProfile(name: name, rules: [ExternalSavedRule(target: "198.51.100.7"), ExternalSavedRule(target: "203.0.113.0/24", enabled: false)])
    }
    func testNormalizeAndRetainDisabledOrderAndIDs() throws {
        let input = profile(); let value = try input.validated()
        XCTAssertEqual(value.rules.map(\.target), ["198.51.100.7/32", "203.0.113.0/24"])
        XCTAssertEqual(value.rules.map(\.id), input.rules.map(\.id))
        XCTAssertEqual(value.enabledRulesText, "198.51.100.7/32")
    }
    func testBatchRejectsWholeInputWithoutPartialMutation() throws {
        var value = profile(); let before = value
        XCTAssertThrowsError(try value.appendBatch("192.0.2.1\nnot-a-host"))
        XCTAssertEqual(value, before)
        try value.appendBatch(" 192.0.2.9/24 \n192.0.2.10")
        XCTAssertEqual(value.rules.suffix(2).map(\.target), ["192.0.2.0/24", "192.0.2.10/32"])
    }
    func testDisabledInvalidRuleStillRejected() throws {
        let value = ExternalSavedProfile(name: "test", rules: [.init(target: "::1", enabled: false)])
        XCTAssertThrowsError(try value.validated())
    }
    func testNameAndRulesLimits() throws {
        for name in ["", "  ", "A\nB", String(repeating: "界", count: 65)] {
            XCTAssertThrowsError(try profile(name).validated())
        }
        for target in ["010.0.0.1", "localhost", "192.0.2.1;id", "192.0.2.1/33"] {
            XCTAssertThrowsError(try ExternalSavedRule(target: target).validated())
        }
        XCTAssertThrowsError(try ExternalSavedProfile(name: "many", rules: (0..<65).map { _ in .init(target: "192.0.2.1") }).validated())
        let many = (0..<17).map { profile("p\($0)") }
        XCTAssertThrowsError(try ExternalProfileWorkspace(profiles: many).validated())
    }
    func testDuplicateAndSelectionValidation() throws {
        let p = profile()
        XCTAssertThrowsError(try ExternalProfileWorkspace(profiles: [p,p]).validated())
        XCTAssertThrowsError(try ExternalProfileWorkspace(profiles: [p], selectedID: UUID()).validated())
        var repeated = p; repeated.rules.append(p.rules[0])
        XCTAssertThrowsError(try repeated.validated())
        XCTAssertThrowsError(try ExternalProfileWorkspace().validated(persisted: true))
    }
    func testMovesTogglesAndDuplicatesDoNotActivateAnything() throws {
        var p = profile(); let first = p.rules[0].id
        p.move(first, by: 1); XCTAssertEqual(p.rules[1].id, first)
        let after = p; p.move(first, by: 2); XCTAssertEqual(p, after)
        p.rules[1].enabled = false; XCTAssertEqual(p.enabledRulesText, "")
        let copy = p.duplicated(name: "copy")
        XCTAssertNotEqual(copy.id, p.id); XCTAssertTrue(Set(copy.rules.map(\.id)).isDisjoint(with: p.rules.map(\.id)))
        XCTAssertEqual(copy.rules.map(\.enabled), p.rules.map(\.enabled))
    }
    func testDeletingSelectionDoesNotChooseAnotherProfile() throws {
        let p = profile(); let q = profile("q")
        let w = ExternalProfileWorkspace(revision: UUID(), profiles: [p,q], selectedID:p.id)
        let result = try w.deleting(p.id)
        XCTAssertNil(result.selectedID); XCTAssertEqual(result.profiles, [q])
        XCTAssertThrowsError(try result.deleting(UUID()))
    }
    func testUnsavedEditorMustNotReloadOrCreateImplicitly() throws {
        var editor = ExternalProfileEditor(); try editor.loaded(ExternalProfileWorkspace())
        try editor.new(); try editor.edit { $0.name = "local edits" }
        XCTAssertTrue(editor.isDirty)
        XCTAssertThrowsError(try editor.loaded(ExternalProfileWorkspace()))
        XCTAssertThrowsError(try editor.new())
        XCTAssertEqual(editor.draft?.name, "local edits")
        try editor.loaded(ExternalProfileWorkspace(), discard:true); XCTAssertFalse(editor.isDirty)
    }
    func testStaleAndUncertainSaveRetainDraftAndRequireReload() throws {
        for failure in [ExternalProfileError.staleRevision, .saveUncertain] {
            var editor = ExternalProfileEditor(); try editor.loaded(ExternalProfileWorkspace()); try editor.new()
            try editor.edit { $0.name = "keep this" }; editor.failed(failure)
            XCTAssertTrue(editor.mustReload); XCTAssertTrue(editor.isDirty)
            XCTAssertEqual(editor.draft?.name, "keep this")
            XCTAssertThrowsError(try editor.candidate())
            editor.discarded(); XCTAssertTrue(editor.mustReload)
            try editor.loaded(ExternalProfileWorkspace(), discard:true); XCTAssertFalse(editor.mustReload)
        }
    }
    func testWorkspaceEncodingContainsOnlyRuleDocuments() throws {
        let p = profile(); let w = ExternalProfileWorkspace(revision:UUID(), profiles:[p], selectedID:p.id)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(w)) as! [String:Any]
        XCTAssertEqual(Set(json.keys), ["format", "revision", "profiles", "selectedID"])
        let records = json["profiles"] as! [[String:Any]]
        XCTAssertEqual(Set(records[0].keys), ["id", "name", "rules"])
        XCTAssertFalse(String(reflecting:w).contains("198.51")); XCTAssertEqual(Mirror(reflecting:w).children.count,0)
        let rule = (records[0]["rules"] as! [[String:Any]])[0]
        XCTAssertEqual(rule["kind"] as? String, "IP-CIDR")
    }
    func testTypedDomainApplicationAndLegacyMigration() throws {
        var value = ExternalSavedProfile(name: "typed")
        try value.appendBatch("DOMAIN,WWW.Example.COM.\nDOMAIN-SUFFIX,*.Example.COM\nDOMAIN-KEYWORD,GitHub\nAPP,Google Chrome\n192.0.2.9")
        XCTAssertEqual(value.rules.map(\.kind), [.domain, .domainSuffix, .domainKeyword, .application, .ipCIDR])
        XCTAssertEqual(value.rules.map(\.target), ["www.example.com", "example.com", "github", "Google Chrome", "192.0.2.9/32"])
        XCTAssertTrue(value.hasEnabledFlowRules)
        XCTAssertThrowsError(try value.routeExecutionRulesText()) {
            XCTAssertEqual($0 as? ExternalProfileError, .ruleNeedsFlowBackend)
        }
        let legacy = #"{"format":"external-profiles-v1","revision":"00000000-0000-0000-0000-000000000001","profiles":[{"id":"00000000-0000-0000-0000-000000000002","name":"old","rules":[{"id":"00000000-0000-0000-0000-000000000003","target":"192.0.2.9","enabled":true}]}],"selectedID":"00000000-0000-0000-0000-000000000002"}"#
        let migrated = try JSONDecoder().decode(ExternalProfileWorkspace.self, from: Data(legacy.utf8)).validated(persisted: true)
        XCTAssertEqual(migrated.format, ExternalProfileWorkspace.schema)
        XCTAssertEqual(migrated.selected?.rules.first?.kind, .ipCIDR)
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(migrated), as: UTF8.self).contains("external-profiles-v2"))
    }
}

// Stateless async XCTest fixture. Each test owns its temporary directory and actors.
final class ExternalProfileStoreTests: XCTestCase, @unchecked Sendable {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("external-profiles-test-" + UUID().uuidString, isDirectory:true)
        try FileManager.default.createDirectory(at:root, withIntermediateDirectories:false)
        return root
    }
    private func initial(_ title: String = "First") throws -> ExternalProfileWorkspace {
        try ExternalProfileWorkspace().replacing(.init(name:title, rules:[.init(target:"192.0.2.7")]))
    }
    private func file(_ root: URL) -> URL { root.appendingPathComponent("store/profiles.json") }
    private func replace(_ root: URL, _ data: Data) throws {
        try data.write(to:file(root)); XCTAssertEqual(chmod(file(root).path, 0o600),0)
    }
    func testRoundtripFreshRevisionSelectionAndPermission() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let store = ExternalProfileStore(directory:root.appendingPathComponent("store"))
        let empty = try await store.load(); XCTAssertNil(empty.revision)
        XCTAssertFalse(FileManager.default.fileExists(atPath:file(root).path))
        let saved = try await store.save(initial(), expectedRevision:nil)
        let loaded = try await store.load(); XCTAssertEqual(saved,loaded); XCTAssertNotNil(saved.revision)
        XCTAssertEqual(loaded.selected?.rules[0].target,"192.0.2.7/32")
        let mode = try FileManager.default.attributesOfItem(atPath:file(root).path)[.posixPermissions] as! NSNumber
        XCTAssertEqual(mode.intValue & 0o777, 0o600)
    }
    func testTwoStoresCannotOverwriteStaleRevision() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let a = ExternalProfileStore(directory:root.appendingPathComponent("store"))
        let b = ExternalProfileStore(directory:root.appendingPathComponent("store"))
        let first = try await a.save(initial(), expectedRevision:nil)
        var candidate = first; candidate.profiles[0].name = "newer"
        let latest = try await b.save(candidate, expectedRevision:first.revision)
        do { _ = try await a.save(first, expectedRevision:first.revision); XCTFail("stale save accepted") }
        catch { XCTAssertEqual(error as? ExternalProfileError, .staleRevision) }
        let current = try await a.load(); XCTAssertEqual(current,latest)
    }
    func testFileCorruptionIsNeverResetOrOverwritten() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let store = ExternalProfileStore(directory:root.appendingPathComponent("store"))
        let first = try await store.save(initial(), expectedRevision:nil)
        let broken = Data("{not JSON".utf8); try replace(root,broken)
        do { _ = try await store.load(); XCTFail("corruption ignored") }
        catch { XCTAssertEqual(error as? ExternalProfileError,.invalidDocument) }
        do { _ = try await store.save(first, expectedRevision:first.revision); XCTFail("corruption overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf:file(root)),broken)
    }
    func testFutureSchemaDoesNotDowngrade() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let store = ExternalProfileStore(directory:root.appendingPathComponent("store"))
        let first = try await store.save(initial(),expectedRevision:nil)
        let future = try JSONEncoder().encode(first)
        let text = String(decoding:future,as:UTF8.self).replacingOccurrences(of:"external-profiles-v2",with:"external-profiles-v9")
        try replace(root,Data(text.utf8))
        do { _ = try await store.load(); XCTFail("future version accepted") }
        catch { XCTAssertEqual(error as? ExternalProfileError,.unsupportedVersion) }
    }
    func testSymlinkFileAndDirectoryAreNotFollowed() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let outside = root.appendingPathComponent("outside"); try Data("untouched".utf8).write(to:outside)
        let store = ExternalProfileStore(directory:root.appendingPathComponent("store")); _ = try await store.load()
        XCTAssertEqual(symlink(outside.path,file(root).path),0)
        do { _ = try await store.load(); XCTFail("symlink read") } catch {}
        do { _ = try await store.save(initial(),expectedRevision:nil); XCTFail("symlink overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf:outside),Data("untouched".utf8))
        let link = root.appendingPathComponent("alias"); XCTAssertEqual(symlink(root.appendingPathComponent("store").path,link.path),0)
        do { _ = try await ExternalProfileStore(directory:link).load(); XCTFail("directory symlink followed") } catch {}
    }
    func testHardlinksAndUnsafeModesFail() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let store = ExternalProfileStore(directory:root.appendingPathComponent("store"))
        _ = try await store.save(initial(),expectedRevision:nil)
        let alias = root.appendingPathComponent("alias.json")
        XCTAssertEqual(link(file(root).path,alias.path),0)
        do { _ = try await store.load(); XCTFail("hardlink read") } catch {}
        try FileManager.default.removeItem(at:alias)
        XCTAssertEqual(chmod(file(root).path,0o644),0)
        do { _ = try await store.load(); XCTFail("unsafe mode read") } catch {}
    }
    func testFIFOIsRejectedWithoutBlocking() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let store = ExternalProfileStore(directory:root.appendingPathComponent("store")); _ = try await store.load()
        XCTAssertEqual(mkfifo(file(root).path,0o600),0)
        do { _ = try await store.load(); XCTFail("FIFO read") } catch {}
    }
    func testOversizedFileRejectedWithoutReset() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let store = ExternalProfileStore(directory:root.appendingPathComponent("store")); _ = try await store.load()
        try replace(root,Data(repeating:65,count:ExternalProfileStore.maximumBytes+1))
        do { _ = try await store.load(); XCTFail("oversized read") } catch {}
        XCTAssertEqual(try Data(contentsOf:file(root)).count,ExternalProfileStore.maximumBytes+1)
    }
    func testLockNeverUnlinkedAndContentionDoesNotWrite() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let store = ExternalProfileStore(directory:root.appendingPathComponent("store")); _ = try await store.load()
        let path = root.appendingPathComponent("store/profiles.lock").path
        let fd = open(path,O_RDWR); XCTAssertGreaterThanOrEqual(fd,0); defer { close(fd) }
        XCTAssertEqual(flock(fd,LOCK_EX|LOCK_NB),0)
        do { _ = try await store.save(initial(),expectedRevision:nil); XCTFail("lock ignored") }
        catch { XCTAssertEqual(error as? ExternalProfileError,.busy) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:file(root).path))
        XCTAssertEqual(flock(fd,LOCK_UN),0)
        _ = try await store.save(initial(),expectedRevision:nil)
        var opened = stat(), named = stat(); XCTAssertEqual(fstat(fd,&opened),0); XCTAssertEqual(lstat(path,&named),0)
        XCTAssertEqual(opened.st_ino,named.st_ino)
        let files = try FileManager.default.contentsOfDirectory(atPath:root.appendingPathComponent("store").path)
        XCTAssertEqual(Set(files),["profiles.json","profiles.lock"])
    }
    func testDeleteAndSelectPersistWithoutCreatingAnotherProfile() async throws {
        let root = try temporary(); defer { try? FileManager.default.removeItem(at:root) }
        let store = ExternalProfileStore(directory:root.appendingPathComponent("store"))
        let first = try await store.save(initial(),expectedRevision:nil)
        let second = try await store.save(first.replacing(.init(name:"second")),expectedRevision:first.revision)
        let chosen = try await store.save(second.selecting(first.selectedID),expectedRevision:second.revision)
        XCTAssertEqual(chosen.profiles.count,2); XCTAssertEqual(chosen.selectedID,first.selectedID)
        let removed = try await store.save(chosen.deleting(first.selectedID!),expectedRevision:chosen.revision)
        XCTAssertNil(removed.selectedID); XCTAssertEqual(removed.profiles.count,1)
        let loaded = try await store.load(); XCTAssertEqual(loaded,removed)
    }
}
