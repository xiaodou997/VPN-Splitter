// SPDX-License-Identifier: MIT
/// Network epoch view only. Raw rows remain authoritative for ownership/readback.
/// ADR-EX-INT-11 drops cloned neighbor cache rows from the comparison entirely,
/// subsuming the ADR-EX-INT-04 RTF_IFREF normalization for the same exact pattern.
public enum ExternalRouteEpoch {
    /// True only for kernel-cloned neighbor cache rows: /32 with flags exactly
    /// UP/HOST/LLINFO/WASCLONED, with or without IFREF. Static, owned (G/S/PROTO2),
    /// non-/32 and any other flag combination stay in the view.
    private static func isClonedNeighborCache(_ row: ExternalRoute) -> Bool {
        row.destination.prefixLength == 32 && (row.flags == "UHLWI" || row.flags == "UHLWIi")
    }
    public static func rows(_ routes: Set<ExternalRoute>) -> Set<ExternalRoute> {
        let retained = routes.filter { !isClonedNeighborCache($0) }
        // Ambiguity never widens the exemption: a drop that would empty a non-empty
        // table falls back to the raw set. Retained rows are unmodified, so key
        // collapse cannot occur.
        return retained.isEmpty && !routes.isEmpty ? routes : retained
    }
}
