// SPDX-License-Identifier: MIT
#if os(macOS)
import ExternalCore

/// Keep preview reads on their original actor; the foreground executor shares the
/// same read-only collector, never a writable UI or an unprivileged supplied plan.
actor ExternalSystemReader {
    func capture() throws -> ExternalObservation {
        try ExternalSystemSnapshotReader().capture()
    }
}
#endif
