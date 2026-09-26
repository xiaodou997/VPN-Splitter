# SPDX-License-Identifier: MIT
"""Exact-revision build-only patch. It does not activate a provider or run code."""
from __future__ import annotations
import hashlib

ADAPTER_BLOB = "f7be19b15f5cbe39fd0e6496cdf0b2d426d83b6b"
PATCHED_ADAPTER_BLOB = "ecce2a45f1136eab99ebfd423577de2ccce543f7"


def git_blob(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def transform_adapter(text: str) -> str:
    """Bounded contextual replacements; no fuzzy patching or default policy fallback."""
    edits = [
        ("    case setNetworkSettings(Error)\n",
         "    case setNetworkSettings(Error)\n\n"
         "    /// The caller must supply policy-derived settings; no AllowedIPs fallback.\n"
         "    case policyNetworkSettings(Error)\n", 1),
        ("    private let logHandler: LogHandler\n",
         "    private let logHandler: LogHandler\n\n"
         "    /// Mandatory for start, update and resume. Protocol configuration is unchanged.\n"
         "    private let networkSettingsProvider: (TunnelConfiguration) throws -> NEPacketTunnelNetworkSettings\n", 1),
        ("    public init(with packetTunnelProvider: NEPacketTunnelProvider, logHandler: @escaping LogHandler) {\n",
         "    public init(with packetTunnelProvider: NEPacketTunnelProvider,\n"
         "                networkSettingsProvider: @escaping (TunnelConfiguration) throws -> NEPacketTunnelNetworkSettings,\n"
         "                logHandler: @escaping LogHandler) {\n", 1),
        ("        self.logHandler = logHandler\n",
         "        self.logHandler = logHandler\n"
         "        self.networkSettingsProvider = networkSettingsProvider\n", 1),
        ("try self.setNetworkSettings(settingsGenerator.generateNetworkSettings())",
         "try self.setNetworkSettings(self.policyNetworkSettings(settingsGenerator))", 3),
        ("    private func setNetworkSettings(_ networkSettings: NEPacketTunnelNetworkSettings) throws {\n",
         "    private func policyNetworkSettings(_ generator: PacketTunnelSettingsGenerator) throws -> NEPacketTunnelNetworkSettings {\n"
         "        do { return try networkSettingsProvider(generator.tunnelConfiguration) }\n"
         "        catch { throw WireGuardAdapterError.policyNetworkSettings(error) }\n"
         "    }\n\n"
         "    private func setNetworkSettings(_ networkSettings: NEPacketTunnelNetworkSettings) throws {\n", 1),
    ]
    for before, after, count in edits:
        if text.count(before) != count:
            raise ValueError("E_WG_PATCH_CONTEXT")
        text = text.replace(before, after)
    if ".generateNetworkSettings()" in text:
        raise ValueError("E_WG_POLICY_FALLBACK")
    return text


def patch_adapter(data: bytes) -> bytes:
    if git_blob(data) != ADAPTER_BLOB:
        raise ValueError("E_WG_UPSTREAM_ADAPTER_CHANGED")
    result = transform_adapter(data.decode("utf-8")).encode("utf-8")
    if git_blob(result) != PATCHED_ADAPTER_BLOB:
        raise ValueError("E_WG_PATCH_RESULT_CHANGED")
    return result


MANIFEST_BLOB = "5d15a1b0dd840942a03219034e17c8b5a3d2db38"
PATCHED_MANIFEST_BLOB = "47618ff08764067d623428d749594167a14032cf"


def patch_manifest(data: bytes) -> bytes:
    """Fix the pinned manifest API level, without changing platforms or targets."""
    if git_blob(data) != MANIFEST_BLOB:
        raise ValueError("E_WG_UPSTREAM_MANIFEST_CHANGED")
    # .macOS(.v12) and .iOS(.v15) require PackageDescription 5.5. This does
    # not select Swift 6 language mode or change the app's macOS 26 minimum.
    result = data.replace(b"// swift-tools-version:5.3\n", b"// swift-tools-version:5.5\n", 1)
    if git_blob(result) != PATCHED_MANIFEST_BLOB:
        raise ValueError("E_WG_MANIFEST_RESULT_CHANGED")
    return result
