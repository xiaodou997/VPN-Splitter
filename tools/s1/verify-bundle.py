#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Read-only validation of built signatures/profiles. No signing or key export."""
import datetime
import pathlib
import plistlib
import re
import subprocess
import sys

class VerificationError(Exception):
    pass

def require(test, reason):
    if not test:
        raise VerificationError(reason)

def command(args):
    p = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=False)
    require(p.returncode == 0, 'system_check_failed')
    return p.stdout, p.stderr

def profile_check(profile, bundle_id, team, ne_value, now):
    require(profile.get('TeamIdentifier') == [team], 'profile_team_mismatch')
    expiry = profile.get('ExpirationDate')
    require(isinstance(expiry, datetime.datetime), 'profile_expiry_missing')
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=datetime.timezone.utc)
    require(expiry > now, 'profile_expired')
    ent = profile.get('Entitlements', {})
    aid = ent.get('com.apple.application-identifier', ent.get('application-identifier'))
    # Explicit identifiers only for this spike; a wildcard is not silently accepted.
    prefixes = profile.get('ApplicationIdentifierPrefix', [])
    require(any(aid == prefix+'.'+bundle_id for prefix in prefixes), 'profile_identifier_mismatch')
    require(ne_value in ent.get('com.apple.developer.networking.networkextension', []), 'profile_ne_entitlement_missing')
    return ent

def verify(app, mode):
    require(sys.platform == 'darwin', 'requires_macos')
    require(mode in ('development','developer-id'), 'invalid_mode')
    require(app.is_dir() and app.suffix == '.app', 'invalid_bundle')
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    ext_id = info.get('VPNExtensionBundleIdentifier')
    require(isinstance(ext_id,str) and ext_id.startswith(info['CFBundleIdentifier']+'.'), 'identifier_chain_invalid')
    folder = app/'Contents/Library/SystemExtensions'
    extensions = list(folder.glob('*.systemextension'))
    require(len(extensions)==1 and extensions[0].name==ext_id+'.systemextension', 'extension_layout_invalid')
    require(not (app/'Contents/PlugIns').exists(), 'unexpected_appex_layout')
    ne = 'packet-tunnel-provider'+('-systemextension' if mode=='developer-id' else '')
    team = None
    now = datetime.datetime.now(datetime.timezone.utc)
    for bundle in (app, extensions[0]):
        bi = plistlib.loads((bundle/'Contents/Info.plist').read_bytes())
        command(['/usr/bin/codesign','--verify','--strict','--deep',str(bundle)])
        _, meta = command(['/usr/bin/codesign','-d','--verbose=4',str(bundle)])
        meta = meta.decode('utf-8',errors='replace')
        matches = re.findall(r'^TeamIdentifier=([A-Z0-9]{10})$',meta,re.M)
        require(len(matches)==1, 'team_identity_missing')
        if team is None: team = matches[0]
        require(team==matches[0], 'signature_team_mismatch')
        authority = 'Authority=Developer ID Application:' if mode=='developer-id' else 'Authority=Apple Development:'
        require(authority in meta, 'signing_identity_class_mismatch')
        require('runtime' in meta, 'hardened_runtime_missing')
        stdout,_ = command(['/usr/bin/codesign','-d','--entitlements',':-',str(bundle)])
        signed = plistlib.loads(stdout)
        require(signed.get('com.apple.developer.networking.networkextension')==[ne], 'signed_ne_entitlement_mismatch')
        if mode=='developer-id':
            require(not signed.get('com.apple.security.get-task-allow',False), 'debug_entitlement_in_distribution')
        if bundle==app:
            require(signed.get('com.apple.developer.system-extension.install') is True, 'install_entitlement_missing')
        else:
            require(signed.get('com.apple.security.app-sandbox') is True, 'provider_sandbox_missing')
            classes=bi.get('NetworkExtension',{}).get('NEProviderClasses',{})
            require(classes.get('com.apple.networkextension.packet-tunnel')=='VPNPacketTunnel.PacketTunnelProvider', 'provider_class_mismatch')
        raw,_=command(['/usr/bin/security','cms','-D','-i',str(bundle/'Contents/embedded.provisionprofile')])
        pe=profile_check(plistlib.loads(raw),bi['CFBundleIdentifier'],team,ne,now)
        if bundle==app:
            require(pe.get('com.apple.developer.system-extension.install') is True, 'profile_install_entitlement_missing')
        arch,_=command(['/usr/bin/lipo','-archs',str(bundle/'Contents/MacOS'/bi['CFBundleExecutable'])])
        require(arch.decode().strip()=='arm64', 'architecture_mismatch')
    return ['schema=s1-signing-v1','signature_and_profile_checks=PASS','notarization=NOT_CHECKED','extension_loading=NOT_TESTED','vpn_connectivity=NOT_IMPLEMENTED']

if __name__=='__main__':
    try:
        require(len(sys.argv)==3, 'usage_verify_bundle_path_and_mode')
        print('\n'.join(verify(pathlib.Path(sys.argv[1]).resolve(),sys.argv[2])))
    except (VerificationError,OSError,ValueError,KeyError,plistlib.InvalidFileException,subprocess.TimeoutExpired) as exc:
        reason=str(exc) if isinstance(exc,VerificationError) else 'bundle_or_profile_parse_failed'
        print('schema=s1-signing-v1\nsignature_and_profile_checks=FAIL\nreason='+reason)
        sys.exit(1)
