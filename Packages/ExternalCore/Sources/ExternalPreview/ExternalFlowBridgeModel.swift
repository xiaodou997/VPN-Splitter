// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import SwiftUI
import ExternalFlowWire

@MainActor
final class ExternalFlowBridgeModel: ObservableObject {
    @Published private(set) var snapshot: ExternalFlowProbeSnapshot?
    @Published private(set) var busy = false
    @Published private(set) var message = "尚未读取 Flow Probe 报告。"
    private let store: ExternalFlowProbeSnapshotStore?
    private var operation: Task<Void, Never>?

    init(store: ExternalFlowProbeSnapshotStore? = nil) {
        do { self.store = try store ?? ExternalFlowProbeSnapshotStore.applicationStore() }
        catch {
            self.store = nil
            message = "Flow Probe 报告存储不可用；不影响 Route Bypass。"
            return
        }
        reload()
    }

    func reload() {
        guard !busy, let store else { return }
        operation?.cancel()
        busy = true
        operation = Task { @MainActor [self] in
            defer { busy = false; operation = nil }
            do {
                let value = try await store.load()
                guard !Task.isCancelled else { return }
                snapshot = value
                if let value {
                    let age = max(0, Date().timeIntervalSince(value.capturedAt))
                    message = age > 300
                        ? "已读取旧报告（约 \(Int(age / 60)) 分钟前）；请在 Flow Probe App 重新发布。"
                        : "已读取最新 Flow Probe 脱敏快照。"
                } else {
                    message = "还没有 Flow Probe 报告；请先在签名探针 App 中显式发布。"
                }
            } catch {
                snapshot = nil
                message = "Flow Probe 报告无效或不可读；没有修改网络。"
            }
        }
    }

    func clearView() {
        operation?.cancel(); operation = nil; busy = false; snapshot = nil
        message = "已清除本窗口中的 Flow 报告显示；没有删除磁盘快照或修改网络。"
    }
}
#endif
