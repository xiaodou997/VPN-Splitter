// SPDX-License-Identifier: MIT
import Foundation
import NetworkExtension
import os

// A system extension is a daemon-style executable, not an .appex entry point.
autoreleasepool {
    PacketTunnelProvider.log.notice("S1_EXTENSION_PROCESS_STARTED")
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
