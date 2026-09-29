// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import Security
import SwiftUI

struct ExternalInstalledApplication: Identifiable, Hashable, Sendable {
    var id: String { signingIdentifier }
    let displayName: String
    let signingIdentifier: String
    let bundleIdentifier: String?
}

enum ExternalApplicationCatalogError: Error {
    case scanFailed
}

/// Read-only app discovery for rule authoring. It scans only standard Applications
/// roots, never app containers/data, and returns no filesystem path to the rule store.
actor ExternalApplicationCatalog {
    static let shared = ExternalApplicationCatalog()

    func scan() throws -> [ExternalInstalledApplication] {
        let manager = FileManager.default
        var roots = [URL(fileURLWithPath: "/Applications", isDirectory: true),
                     URL(fileURLWithPath: "/System/Applications", isDirectory: true)]
        if let home = manager.urls(for: .applicationDirectory, in: .userDomainMask).first {
            roots.append(home)
        }
        var bySigningID: [String: ExternalInstalledApplication] = [:]
        for root in roots where manager.fileExists(atPath: root.path) {
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            while let item = enumerator.nextObject() as? URL {
                guard item.pathExtension.caseInsensitiveCompare("app") == .orderedSame,
                      let candidate = Self.inspect(item) else { continue }
                let old = bySigningID[candidate.signingIdentifier]
                if old == nil || candidate.displayName.localizedStandardCompare(old!.displayName) == .orderedAscending {
                    bySigningID[candidate.signingIdentifier] = candidate
                }
            }
        }
        return bySigningID.values.sorted {
            let order = $0.displayName.localizedStandardCompare($1.displayName)
            return order == .orderedSame ? $0.signingIdentifier < $1.signingIdentifier : order == .orderedAscending
        }
    }

    private static func inspect(_ url: URL) -> ExternalInstalledApplication? {
        guard let bundle = Bundle(url: url) else { return nil }
        let display = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
            (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
            url.deletingPathExtension().lastPathComponent
        let name = display.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 128 else { return nil }

        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: 0), nil) == errSecSuccess else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let identifier = values[kSecCodeInfoIdentifier as String] as? String,
              valid(identifier) else { return nil }
        return .init(displayName: name, signingIdentifier: identifier, bundleIdentifier: bundle.bundleIdentifier)
    }

    private static func valid(_ value: String) -> Bool {
        (1...255).contains(value.utf8.count) && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) ||
                byte == 45 || byte == 46 || byte == 95
        }
    }
}

@MainActor
final class ExternalApplicationSearchModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var applications: [ExternalInstalledApplication] = []
    @Published private(set) var loading = false
    @Published private(set) var message = "正在读取本机应用列表…"

    var results: [ExternalInstalledApplication] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return Array(applications.prefix(80)) }
        return Array(applications.filter {
            $0.displayName.localizedCaseInsensitiveContains(needle) ||
            $0.signingIdentifier.localizedCaseInsensitiveContains(needle) ||
            ($0.bundleIdentifier?.localizedCaseInsensitiveContains(needle) ?? false)
        }.prefix(80))
    }

    func load() {
        guard !loading, applications.isEmpty else { return }
        loading = true
        Task { @MainActor [self] in
            defer { loading = false }
            do {
                applications = try await ExternalApplicationCatalog.shared.scan()
                message = applications.isEmpty ? "没有找到可用的已签名应用。" : "找到 \(applications.count) 个可选择应用。"
            } catch {
                message = "无法读取应用列表；没有修改规则或网络。"
            }
        }
    }
}

struct ExternalApplicationPicker: View {
    @StateObject private var search = ExternalApplicationSearchModel()
    let selected: (ExternalInstalledApplication) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("选择应用").font(.title2).bold()
                Spacer()
                Button("取消") { dismiss() }
            }
            TextField("搜索应用名称、Bundle ID 或 Signing ID", text: $search.query)
                .textFieldStyle(.roundedBorder)
            Text(search.message).font(.caption).foregroundStyle(.secondary)
            List(search.results) { app in
                Button {
                    selected(app); dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.displayName)
                        Text(app.signingIdentifier).font(.caption.monospaced()).foregroundStyle(.secondary)
                        if let bundle = app.bundleIdentifier, bundle != app.signingIdentifier {
                            Text(bundle).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.buttonStyle(.plain)
            }
            if search.loading { ProgressView() }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 520)
        .task { search.load() }
    }
}
#endif
