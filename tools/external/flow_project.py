# SPDX-License-Identifier: MIT
"""Generate isolated App + Transparent Proxy system extension project for FLOW-01B."""
from __future__ import annotations
import copy, hashlib, importlib.util, json, os
from pathlib import Path
import plistlib

def load_generator(root: Path):
    spec = importlib.util.spec_from_file_location("s1_generator", root / "tools/s1/generate-project.py")
    module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
    return module

def generate(root: Path, run: Path, generator=None) -> Path:
    root = root.resolve(); run = run.resolve(); gen = generator or load_generator(root)
    project = copy.deepcopy(gen.build_project()); objects = project["objects"]
    folder = run / "flow-project"; folder.mkdir(mode=0o700)
    xcode = folder / "VPN-Splitter-FlowProbe.xcodeproj"; xcode.mkdir(mode=0o700)
    def ident(label): return hashlib.sha256(("flow." + label).encode()).hexdigest()[:24].upper()
    def add(label, **value):
        key = ident(label)
        if key in objects: raise ValueError("E_FLOW_PROJECT_COLLISION")
        objects[key] = value; return key

    # Generated build owns its Info/entitlement files; source files stay in repo.
    app_info = {
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleName": "$(PRODUCT_NAME)", "CFBundleDisplayName": "VPN-Splitter Flow Probe",
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1",
        "LSMinimumSystemVersion": "26.0", "NSPrincipalClass": "NSApplication",
        "NSSystemExtensionUsageDescription": "Validate the VPN-Splitter transparent proxy capability probe."
    }
    ext_info = {
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)", "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleName": "$(PRODUCT_NAME)", "CFBundleDisplayName": "VPN-Splitter Flow Probe Extension",
        "CFBundlePackageType": "SYSX", "CFBundleVersion": "1", "CFBundleShortVersionString": "0.1",
        "LSMinimumSystemVersion": "26.0",
        "NetworkExtension": {"NEProviderClasses": {
            "com.apple.networkextension.app-proxy": "ExternalFlowProvider.ExternalTransparentProbeProvider"
        }}
    }
    app_plist = folder / "app-Info.plist"; app_plist.write_bytes(plistlib.dumps(app_info))
    ext_plist = folder / "extension-Info.plist"; ext_plist.write_bytes(plistlib.dumps(ext_info))
    app_ent = folder / "app.entitlements"; app_ent.write_bytes(plistlib.dumps({
        "com.apple.developer.networking.networkextension": ["app-proxy-provider"],
        "com.apple.developer.system-extension.install": True
    }))
    ext_ent = folder / "extension.entitlements"; ext_ent.write_bytes(plistlib.dumps({
        "com.apple.developer.networking.networkextension": ["app-proxy-provider"],
        "com.apple.security.app-sandbox": True,
        "com.apple.security.network.client": True
    }))

    # Remove original WG/ProviderConfiguration package graph and source files.
    objects[gen.ident("project")]["packageReferences"] = []
    for role in ("app", "tunnel"):
        objects[gen.ident(role + ".sources")]["files"] = []
        objects[gen.ident(role + ".frameworks")]["files"] = []
        objects[gen.ident(role + ".target")]["packageProductDependencies"] = []

    for role, source_name in (("app", "FlowProbeApp.swift"), ("tunnel", "FlowProbeMain.swift")):
        source = root / "integrations/external-flow" / source_name
        ref = add(role + ".source", isa="PBXFileReference", lastKnownFileType="sourcecode.swift",
                  path=str(source), sourceTree="<absolute>")
        build = add(role + ".source.build", isa="PBXBuildFile", fileRef=ref)
        objects[gen.ident("root")]["children"].append(ref)
        objects[gen.ident(role + ".sources")]["files"].append(build)

    package = add("ExternalFlow.package", isa="XCLocalSwiftPackageReference",
                  relativePath=os.path.relpath(root / "Packages/ExternalFlow", folder))
    objects[gen.ident("project")]["packageReferences"].append(package)
    dep = add("ExternalFlowProvider.dep", isa="XCSwiftPackageProductDependency",
              package=package, productName="ExternalFlowProvider")
    link = add("ExternalFlowProvider.link", isa="PBXBuildFile", productRef=dep)
    objects[gen.ident("tunnel.target")]["packageProductDependencies"].append(dep)
    objects[gen.ident("tunnel.frameworks")]["files"].append(link)

    app_product = objects[gen.ident("app.product")]
    app_product["path"] = "VPN-Splitter-FlowProbe.app"
    ext_product = objects[gen.ident("tunnel.product")]
    ext_product["path"] = "$(FLOW_EXTENSION_BUNDLE_ID).systemextension"

    for name in ("Debug", "Release", "DeveloperID"):
        app = objects[gen.ident("app." + name)]["buildSettings"]
        app.update({
            "PRODUCT_BUNDLE_IDENTIFIER": "io.github.xiaodou997.VPNSplitter.FlowProbe",
            "PRODUCT_NAME": "VPN-Splitter-FlowProbe", "PRODUCT_MODULE_NAME": "ExternalFlowProbeApp",
            "EXECUTABLE_NAME": "VPN-Splitter-FlowProbe", "INFOPLIST_FILE": str(app_plist),
            "CODE_SIGN_ENTITLEMENTS": str(app_ent), "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
            "ENABLE_APP_SANDBOX": "NO"
        })
        ext = objects[gen.ident("tunnel." + name)]["buildSettings"]
        ext.update({
            "PRODUCT_BUNDLE_IDENTIFIER": "io.github.xiaodou997.VPNSplitter.FlowProbeExtension",
            "FLOW_EXTENSION_BUNDLE_ID": "io.github.xiaodou997.VPNSplitter.FlowProbeExtension",
            "PRODUCT_NAME": "io.github.xiaodou997.VPNSplitter.FlowProbeExtension",
            "PRODUCT_MODULE_NAME": "ExternalFlowProbe", "EXECUTABLE_NAME": "ExternalFlowProbe",
            "INFOPLIST_FILE": str(ext_plist), "CODE_SIGN_ENTITLEMENTS": str(ext_ent),
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO", "ENABLE_APP_SANDBOX": "YES",
            "WRAPPER_EXTENSION": "systemextension", "SKIP_INSTALL": "YES"
        })
        app.pop("PROVISIONING_PROFILE_SPECIFIER", None); ext.pop("PROVISIONING_PROFILE_SPECIFIER", None)

    objects[gen.ident("app.target")]["name"] = "VPN-Splitter-FlowProbe"
    objects[gen.ident("app.target")]["productName"] = "VPN-Splitter-FlowProbe"
    objects[gen.ident("tunnel.target")]["name"] = "FlowProbeExtension"
    objects[gen.ident("tunnel.target")]["productName"] = "FlowProbeExtension"

    text = "// !$*UTF8*$!\n" + gen.serialize(project) + "\n"
    (xcode / "project.pbxproj").write_text(text, encoding="utf-8")
    (folder / "project-objects.json").write_text(json.dumps(project, indent=2) + "\n")
    return xcode
