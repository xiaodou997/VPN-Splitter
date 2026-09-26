# SPDX-License-Identifier: MIT
"""Generate a separate integrated Xcode project; never rewrite the checked-in spike."""
from __future__ import annotations
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib

SOURCES = ("ManagedWireGuardNativeInput.swift", "ManagedUnderlayMonitor.swift", "ManagedPacketFlowSession.swift")

def load_generator(root: Path):
    spec = importlib.util.spec_from_file_location("s1_generator", root / "tools/s1/generate-project.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

def generate(root: Path, run: Path, generator=None) -> Path:
    root = root.resolve(); run = run.resolve()
    gen = generator or load_generator(root)
    project = copy.deepcopy(gen.build_project()); objects = project["objects"]
    folder = run / "runtime-project"; folder.mkdir(mode=0o700)
    project_path = folder / "VPN-Splitter.xcodeproj"; project_path.mkdir(mode=0o700)
    def ident(label): return hashlib.sha256(("runtime." + label).encode()).hexdigest()[:24].upper()
    def add(label, **value):
        key = ident(label)
        if key in objects: raise ValueError("E_RUNTIME_PROJECT_COLLISION")
        objects[key] = value; return key
    # Rebase existing source/config/package references to this isolated project root.
    for value in objects.values():
        if value["isa"] == "PBXFileReference" and value.get("path", "").startswith(("App/", "PacketTunnel/", "Config/")):
            value["path"] = str(root / "apps/macos" / value["path"]); value["sourceTree"] = "<absolute>"
        if value["isa"] == "XCLocalSwiftPackageReference":
            absolute = (root / "apps/macos" / value["relativePath"]).resolve()
            value["relativePath"] = os.path.relpath(absolute, folder)
    for role, directory in (("app", "App"), ("tunnel", "PacketTunnel")):
        info = plistlib.loads((root / "apps/macos" / directory / "Info.plist").read_bytes())
        info["VPNPacketFlowRuntime"] = True
        info["CFBundleDisplayName"] = "VPN-Splitter IPv4 Runtime" if role == "app" else "VPN-Splitter Packet Tunnel"
        info_path = folder / (role + "-Info.plist"); info_path.write_bytes(plistlib.dumps(info))
        for name in ("Debug", "Release", "DeveloperID"):
            settings = objects[gen.ident(role + "." + name)]["buildSettings"]
            settings["INFOPLIST_FILE"] = str(info_path)
            settings["CODE_SIGN_ENTITLEMENTS"] = str(root / "apps/macos" / settings["CODE_SIGN_ENTITLEMENTS"])
            settings["CODE_SIGN_INJECT_BASE_ENTITLEMENTS"] = "NO"
            if role == "tunnel":
                settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = ["$(inherited)", "VPNSPLITTER_PACKET_FLOW_RUNTIME"]
                settings["OTHER_LDFLAGS"] = ["$(inherited)", "-L" + str(run / "lib"),
                    "-force_load", str(run / "lib/libwg-go.a"), "-lresolv", "-framework", "Security",
                    "-framework", "CoreFoundation", "-framework", "SystemConfiguration"]
    for filename in SOURCES:
        source = root / "integrations/wireguard" / filename
        if source.is_symlink() or not source.is_file(): raise ValueError("E_RUNTIME_SOURCE")
        ref = add(filename, isa="PBXFileReference", lastKnownFileType="sourcecode.swift", path=str(source), sourceTree="<absolute>")
        build = add(filename + ".build", isa="PBXBuildFile", fileRef=ref)
        objects[gen.ident("root")]["children"].append(ref)
        objects[gen.ident("tunnel.sources")]["files"].append(build)
    for package, path, products in [
        ("ProviderSession", root / "Packages/ProviderSession", ["ProviderSession"]),
        ("ManagedSettings", root / "Packages/ManagedSettings", ["ManagedSettings", "ManagedSettingsApple"]),
        ("WireGuardKit", run / "wireguard-apple", ["WireGuardKit"])
    ]:
        ref = add(package, isa="XCLocalSwiftPackageReference", relativePath=os.path.relpath(path, folder))
        objects[gen.ident("project")]["packageReferences"].append(ref)
        for product in products:
            dep = add(product + ".dep", isa="XCSwiftPackageProductDependency", package=ref, productName=product)
            link = add(product + ".link", isa="PBXBuildFile", productRef=dep)
            objects[gen.ident("tunnel.target")]["packageProductDependencies"].append(dep)
            objects[gen.ident("tunnel.frameworks")]["files"].append(link)
    text = "// !$*UTF8*$!\n" + gen.serialize(project) + "\n"
    (project_path / "project.pbxproj").write_text(text, encoding="utf-8")
    (folder / "project-objects.json").write_text(json.dumps(project, indent=2) + "\n")
    return project_path
