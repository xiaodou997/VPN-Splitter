// SPDX-License-Identifier: MIT
import Foundation

/// Safe to display or paste: only a fixed code/field and integer positions.
/// Never stores raw network output, hostnames, addresses, interface names or tokens.
public struct ExternalRouteParseDiagnostic: Error, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public enum Field: String, Sendable {
        case inputSize, encoding, controlCharacter, lineSize, section, header, columns
        case rowCount, interface, flags, gateway, counters, expiry, destination, emptyTable
    }
    public let code: ExternalError
    /// Original 1-based output line; zero for whole-input failures before line parsing.
    public let line: Int
    public let field: Field
    public let columns: Int
    internal init(code: ExternalError, line: Int, field: Field, columns: Int) {
        self.code = code; self.line = line; self.field = field; self.columns = columns
    }
    public var description: String {
        "route_parse_schema=external-route-parse-v1 code=\(code.rawValue) line=\(line) field=\(field.rawValue) columns=\(columns)"
    }
    public var debugDescription: String { description }
    public var message: String { code.message + "（" + description + "）" }
    public var customMirror: Mirror { Mirror(self, children: EmptyCollection<(label: String?, value: Any)>()) }
}
