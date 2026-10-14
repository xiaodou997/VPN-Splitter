// SPDX-License-Identifier: MIT
/// Network epoch view only. Raw rows remain authoritative for ownership/readback.
/// ADR-EX-INT-04 excludes only RTF_IFREF on known scoped cloned neighbor rows.
public enum ExternalRouteEpoch {
    public static func rows(_ routes: Set<ExternalRoute>) -> Set<ExternalRoute> {
        let normalized = Set(routes.map { row in
            guard row.destination.prefixLength == 32, row.flags == "UHLWIi" else { return row }
            return ExternalRoute(destination: row.destination, gateway: row.gateway, interface: row.interface,
                                 flags: "UHLWI", isExpired: row.isExpired)
        })
        // Never collapse multiple raw rows into one comparison key.
        return normalized.count == routes.count ? normalized : routes
    }
}
