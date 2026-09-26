// SPDX-License-Identifier: MIT
import Foundation

public enum SplitterNativeConfigurationError: String, Error {
    case invalidConfiguration
}

/// Narrow wrapper around the pinned upstream quick-config parser, staged into the
/// SAME WireGuardKit module. Its raw-input-bearing ParseErrors never escape here.
/// Call only after the full project admission parser; this is not an authorization.
public enum SplitterNativeConfiguration {
    public static func parseAdmittedText(_ text: String) throws -> TunnelConfiguration {
        guard !text.isEmpty, text.utf8.count <= 65_536 else {
            throw SplitterNativeConfigurationError.invalidConfiguration
        }
        var normalized = text
        if normalized.first == "\u{feff}" { normalized.removeFirst() }
        normalized = normalized.replacingOccurrences(of: "\r\n", with: "\n")
        // AppCore accepts WireGuard's 'off' spelling. Upstream UInt16 parsing does
        // not. Translate ONLY that already-admitted spelling, not keys or ranges.
        normalized = normalized.components(separatedBy: "\n").map { line in
            let parts = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let field = String(parts[0])
            guard let equals = field.firstIndex(of: "="),
                  field[..<equals].trimmingCharacters(in: .whitespaces).lowercased() == "persistentkeepalive",
                  field[field.index(after: equals)...].trimmingCharacters(in: .whitespaces).lowercased() == "off" else {
                return line
            }
            return "PersistentKeepalive = 0" // Comments do not enter the protocol snapshot.
        }.joined(separator: "\n")
        do { return try TunnelConfiguration(fromWgQuickConfig: normalized, called: nil) }
        catch { throw SplitterNativeConfigurationError.invalidConfiguration }
    }
}
