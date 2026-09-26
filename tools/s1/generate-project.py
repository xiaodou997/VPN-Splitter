#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Deterministic, dependency-free generation of the checked-in Xcode project."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()

def build_project():
    objects = {}
    def add(label, **values):
        key = ident(label)
        assert key not in objects
        objects[key] = values
        return key
    def file(name, path, typ, tree='<group>'):
        return add(name, isa='PBXFileReference', lastKnownFileType=typ, path=path, sourceTree=tree)
    app_files = [file('app.'+n, 'App/'+n, 'sourcecode.swift') for n in ('VPNSplitterApp.swift','SpikeController.swift','ManagedTunnelLaunchClient.swift')]
    tunnel_files = [file('tunnel.'+n, 'PacketTunnel/'+n, 'sourcecode.swift') for n in ('main.swift','PacketTunnelProvider.swift')]
    plist_files = [file('plist.'+n,n+'/Info.plist','text.plist.xml') for n in ('App','PacketTunnel')]
    config_files = {n:file('config.'+n,'Config/'+n+'.xcconfig','text.xcconfig') for n in ('Debug','Release','DeveloperID')}
    extra_config = [file('config.'+n,'Config/'+n,'text.xcconfig' if n.endswith('xcconfig') else 'text.plist.entitlements') for n in ('Base.xcconfig','App.Development.entitlements','App.DeveloperID.entitlements','PacketTunnel.Development.entitlements','PacketTunnel.DeveloperID.entitlements')]
    app_product = add('app.product', isa='PBXFileReference', explicitFileType='wrapper.application', includeInIndex='0', path='VPN-Splitter.app', sourceTree='BUILT_PRODUCTS_DIR')
    tunnel_product = add('tunnel.product', isa='PBXFileReference', explicitFileType='wrapper.system-extension', includeInIndex='0', path='$(VPN_EXTENSION_BUNDLE_ID).systemextension', sourceTree='BUILT_PRODUCTS_DIR')
    products = add('products', isa='PBXGroup', children=[app_product,tunnel_product], name='Products', sourceTree='<group>')
    group = add('root', isa='PBXGroup', children=app_files+tunnel_files+plist_files+list(config_files.values())+extra_config+[products], sourceTree='<group>')
    package = add('package',isa='XCLocalSwiftPackageReference',relativePath='../../Packages/PolicyCore')
    managed_package = add('managed.package',isa='XCLocalSwiftPackageReference',relativePath='../../Packages/ProviderConfiguration')
    for role, files, product in [('app',app_files,app_product),('tunnel',tunnel_files,tunnel_product)]:
        src=[add(role+'.source.'+str(i),isa='PBXBuildFile',fileRef=f) for i,f in enumerate(files)]
        sources=add(role+'.sources',isa='PBXSourcesBuildPhase',buildActionMask='2147483647',files=src,runOnlyForDeploymentPostprocessing='0')
        dep=add(role+'.package',isa='XCSwiftPackageProductDependency',package=package,productName='PolicyCore')
        link=add(role+'.link',isa='PBXBuildFile',productRef=dep)
        managed_dep=add(role+'.managed.package',isa='XCSwiftPackageProductDependency',package=managed_package,productName='ProviderConfiguration')
        managed_link=add(role+'.managed.link',isa='PBXBuildFile',productRef=managed_dep)
        frameworks=add(role+'.frameworks',isa='PBXFrameworksBuildPhase',buildActionMask='2147483647',files=[link,managed_link],runOnlyForDeploymentPostprocessing='0')
        configs=[]
        for name in config_files:
            settings={'PRODUCT_BUNDLE_IDENTIFIER':'$(VPN_APP_BUNDLE_ID)' if role=='app' else '$(VPN_EXTENSION_BUNDLE_ID)',
                'PRODUCT_NAME':'VPN-Splitter' if role=='app' else '$(VPN_EXTENSION_BUNDLE_ID)',
                'PRODUCT_MODULE_NAME':'VPNSplitterMac' if role=='app' else 'VPNPacketTunnel',
                'INFOPLIST_FILE':('App' if role=='app' else 'PacketTunnel')+'/Info.plist',
                'CODE_SIGN_ENTITLEMENTS':'Config/'+('App' if role=='app' else 'PacketTunnel')+'.'+('DeveloperID' if name=='DeveloperID' else 'Development')+'.entitlements',
                'SKIP_INSTALL':'NO' if role=='app' else 'YES',
                'LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/../Frameworks']}
            if role=='tunnel':
                settings.update({'EXECUTABLE_NAME':'VPNPacketTunnel','WRAPPER_EXTENSION':'systemextension','ENABLE_APP_SANDBOX':'YES'})
            else:
                settings['ENABLE_APP_SANDBOX']='NO'
            if name=='DeveloperID':
                settings['PROVISIONING_PROFILE_SPECIFIER']='$(VPN_APP_PROFILE_SPECIFIER)' if role=='app' else '$(VPN_EXTENSION_PROFILE_SPECIFIER)'
            configs.append(add(role+'.'+name,isa='XCBuildConfiguration',baseConfigurationReference=config_files[name],buildSettings=settings,name=name))
        configlist=add(role+'.configs',isa='XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible='0',defaultConfigurationName='Debug')
        phases=[sources,frameworks]
        dependencies=[]
        if role=='app':
            embedfile=add('embed.file',isa='PBXBuildFile',fileRef=tunnel_product,settings={'ATTRIBUTES':['CodeSignOnCopy','RemoveHeadersOnCopy']})
            phases.append(add('embed',isa='PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='$(CONTENTS_FOLDER_PATH)/Library/SystemExtensions',dstSubfolderSpec='16',files=[embedfile],name='Embed System Extensions',runOnlyForDeploymentPostprocessing='0'))
            proxy=add('proxy',isa='PBXContainerItemProxy',containerPortal=ident('project'),proxyType='1',remoteGlobalIDString=ident('tunnel.target'),remoteInfo='PacketTunnel')
            dependencies.append(add('target.dep',isa='PBXTargetDependency',target=ident('tunnel.target'),targetProxy=proxy))
        add(role+'.target',isa='PBXNativeTarget',buildConfigurationList=configlist,buildPhases=phases,buildRules=[],dependencies=dependencies,name='VPN-Splitter' if role=='app' else 'PacketTunnel',packageProductDependencies=[dep,managed_dep],productName='VPN-Splitter' if role=='app' else 'PacketTunnel',productReference=product,productType='com.apple.product-type.application' if role=='app' else 'com.apple.product-type.system-extension')
    configs=[add('project.'+n,isa='XCBuildConfiguration',baseConfigurationReference=config_files[n],buildSettings={},name=n) for n in config_files]
    configlist=add('project.configs',isa='XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible='0',defaultConfigurationName='Debug')
    add('project',isa='PBXProject',attributes={'BuildIndependentTargetsInParallel':'YES','LastUpgradeCheck':'2600','TargetAttributes':{ident('app.target'):{'CreatedOnToolsVersion':'26.0','SystemCapabilities':{'com.apple.NetworkExtensions':{'enabled':'1'},'com.apple.SystemExtension':{'enabled':'1'}}},ident('tunnel.target'):{'CreatedOnToolsVersion':'26.0','SystemCapabilities':{'com.apple.NetworkExtensions':{'enabled':'1'},'com.apple.Sandbox':{'enabled':'1'}}}}},buildConfigurationList=configlist,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings='0',knownRegions=['en','Base'],mainGroup=group,packageReferences=[package,managed_package],productRefGroup=products,projectDirPath='',projectRoot='',targets=[ident('app.target'),ident('tunnel.target')])
    return {'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':ident('project')}

def serialize(value, level=0):
    if isinstance(value,dict):
        return '{ '+''.join(json.dumps(k)+' = '+serialize(v,level+1)+'; ' for k,v in value.items())+'}'
    if isinstance(value,list):
        return '( '+''.join(serialize(v,level+1)+', ' for v in value)+')'
    return json.dumps(value,ensure_ascii=False)

def render():
    p=build_project()
    entries='\n'.join(json.dumps(k)+' = '+serialize(v)+';' for k,v in p['objects'].items())
    return '// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56;\nobjects = {\n'+entries+'\n}; rootObject = '+p['rootObject']+'; }\n'

if __name__=='__main__':
    path=ROOT/'apps/macos/VPN-Splitter.xcodeproj/project.pbxproj'
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(render(),encoding='utf-8')
