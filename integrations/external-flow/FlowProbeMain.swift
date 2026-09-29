// SPDX-License-Identifier: MIT
import Foundation
import NetworkExtension
import ExternalFlowProvider

autoreleasepool {
    _ = ExternalTransparentProbeProvider.self // Keep provider metadata linked for Info.plist lookup.
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
