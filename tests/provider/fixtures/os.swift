// SPDX-License-Identifier: MIT
// TEST DOUBLE ONLY. Native logging/privacy behavior is not exercised.
public struct Logger: Sendable {
    public init(subsystem: String, category: String) {}
    public func notice(_ message: Message) {}
}
public struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public init(stringLiteral value: String) {}
    public init(stringInterpolation: StringInterpolation) {}
    public struct StringInterpolation: StringInterpolationProtocol {
        public enum Privacy { case `public` }
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) {}
        public mutating func appendInterpolation(_ value: String, privacy: Privacy) {}
    }
}
