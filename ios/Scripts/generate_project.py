#!/usr/bin/env python3
"""Deterministic project writer using only the Python standard library. Does not build."""
from pathlib import Path
import hashlib,json,plistlib
import parlacore as core
ROOT=Path(__file__).resolve().parents[1]
objects={}
def uid(name):return hashlib.sha1(name.encode()).hexdigest()[:24].upper()
def add(identity,**value):
 key=uid(identity);assert key not in objects;objects[key]=value;return key
def ref(path,kind):return add('file:'+path,isa='PBXFileReference',lastKnownFileType=kind,path=path,sourceTree='SOURCE_ROOT')
def dump(value,level=0):
 if isinstance(value,dict):return '{\n'+''.join('\t'*(level+1)+json.dumps(str(k))+' = '+dump(v,level+1)+';\n' for k,v in value.items())+'\t'*level+'}'
 if isinstance(value,list):return '('+', '.join(dump(v,level) for v in value)+')'
 return str(value) if isinstance(value,int) else json.dumps(value)
fonts=sorted(p.name for p in (ROOT/'Resources').glob('*.ttf'))
base={'CFBundleDevelopmentRegion':'en','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'$(PRODUCT_NAME)','CFBundleShortVersionString':'1.0','CFBundleVersion':'1','ParlaAppGroup':'$(PARLA_APP_GROUP)'}
app={**base,'CFBundleDisplayName':'Parla','CFBundlePackageType':'APPL','LSRequiresIPhoneOS':True,'MinimumOSVersion':core.DEPLOYMENT,'UIDeviceFamily':[1],'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait'],'UIUserInterfaceStyle':'Light','NSMicrophoneUsageDescription':'Parla records only when you start dictation. Speech is recognized on this iPhone.','UIBackgroundModes':['audio'],'NSSupportsLiveActivities':True,'UIAppFonts':fonts,'UILaunchScreen':{'UIColorName':'neutral50'},'CFBundleURLTypes':[{'CFBundleURLName':'dev.parla.ios','CFBundleURLSchemes':['parla']}],'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False}}
keyboard={**base,'CFBundleDisplayName':'Parla','CFBundlePackageType':'XPC!','UIAppFonts':fonts,'NSExtension':{'NSExtensionPointIdentifier':'com.apple.keyboard-service','NSExtensionPrincipalClass':'$(PRODUCT_MODULE_NAME).KeyboardViewController','NSExtensionAttributes':{'IsASCIICapable':True,'PrimaryLanguage':'en-US','RequestsOpenAccess':True}}}
widgets={**base,'CFBundleDisplayName':'Parla','CFBundlePackageType':'XPC!','UIAppFonts':fonts,'NSExtension':{'NSExtensionPointIdentifier':'com.apple.widgetkit-extension'}}
for name,info in [('App',app),('Keyboard',keyboard),('Widgets',widgets)]:
 (ROOT/f'Configuration/{name}-Info.plist').write_bytes(plistlib.dumps(info,sort_keys=False))
 (ROOT/f'Configuration/{name}.entitlements').write_bytes(plistlib.dumps({'com.apple.security.application-groups':['$(PARLA_APP_GROUP)']}))
 manifest={'NSPrivacyTracking':False,'NSPrivacyTrackingDomains':[],'NSPrivacyCollectedDataTypes':[],'NSPrivacyAccessedAPITypes':[]}
 if name=='App':
  # Audio never leaves the device. Optional network cleanup sends transcript text to the user's own provider.
  manifest['NSPrivacyCollectedDataTypes']=[{'NSPrivacyCollectedDataType':'NSPrivacyCollectedDataTypeOtherUserContent','NSPrivacyCollectedDataTypeLinked':False,'NSPrivacyCollectedDataTypeTracking':False,'NSPrivacyCollectedDataTypePurposes':['NSPrivacyCollectedDataTypePurposeAppFunctionality']}]
  # ParlaCore stats its own settings/model files (size+mtime cache keys) and measures elapsed time with uptime clocks.
  manifest['NSPrivacyAccessedAPITypes']=[{'NSPrivacyAccessedAPIType':'NSPrivacyAccessedAPICategoryFileTimestamp','NSPrivacyAccessedAPITypeReasons':['C617.1']},{'NSPrivacyAccessedAPIType':'NSPrivacyAccessedAPICategorySystemBootTime','NSPrivacyAccessedAPITypeReasons':['35F9.1']}]
 (ROOT/f'Configuration/{name}-PrivacyInfo.xcprivacy').write_bytes(plistlib.dumps(manifest))
if not (ROOT/'Configuration/Signing.xcconfig').exists(): (ROOT/'Configuration/Signing.xcconfig').write_text('// Set these three values for your provisioning team. All targets inherit them.\nDEVELOPMENT_TEAM =\nPARLA_BUNDLE_PREFIX = dev.parla.ios\nPARLA_APP_GROUP = group.dev.parla.ios\n')
kinds={'.swift':'sourcecode.swift','.c':'sourcecode.c.c','.cpp':'sourcecode.cpp.cpp'}
files={}
for p in sorted((ROOT/'Sources').rglob('*.swift')):files[str(p.relative_to(ROOT))]=ref(str(p.relative_to(ROOT)),'sourcecode.swift')
for p in sorted((ROOT/'Tests').glob('*.swift')):files[str(p.relative_to(ROOT))]=ref(str(p.relative_to(ROOT)),'sourcecode.swift')
for p in core.core_paths()+core.vendor_paths():files[p]=ref(p,kinds[Path(p).suffix])
modulemap=core.MODULE_MAP_DIR+'/module.modulemap';files[modulemap]=ref(modulemap,'sourcecode.module-map')
resource_paths=['Resources/Assets.xcassets']+[str(p.relative_to(ROOT)) for p in sorted((ROOT/'Resources').glob('*.ttf'))]+['Resources/dictation-start.wav','Resources/dictation-stop.wav']
resource_paths += [str(p.relative_to(ROOT)) for p in sorted((ROOT/'Resources/FontLicenses').glob('*.txt'))]
for path in resource_paths:files[path]=ref(path,'folder.assetcatalog' if path.endswith('xcassets') else 'audio.wav' if path.endswith('wav') else 'file')
for target in ['App','Keyboard','Widgets']:
 for suffix in ['-Info.plist','.entitlements','-PrivacyInfo.xcprivacy']:
  path='Configuration/'+target+suffix;files[path]=ref(path,'text.plist.xml')
config=ref('Configuration/Signing.xcconfig','text.xcconfig');files['Configuration/Signing.xcconfig']=config
paths={'Parla':'Parla.app','ParlaKeyboard':'ParlaKeyboard.appex','ParlaWidgets':'ParlaWidgets.appex','ParlaTests':'ParlaTests.xctest','ParlaCore':'libParlaCore.a'}
types={'Parla':'wrapper.application','ParlaTests':'wrapper.cfbundle','ParlaCore':'archive.ar'}
products={n:add('product:'+n,isa='PBXFileReference',explicitFileType=types.get(n,'wrapper.app-extension'),includeInIndex=0,path=paths[n],sourceTree='BUILT_PRODUCTS_DIR') for n in paths}
productsGroup=add('products',isa='PBXGroup',children=list(products.values()),name='Products',sourceTree='<group>')
rootGroup=add('root',isa='PBXGroup',children=list(files.values())+[productsGroup],sourceTree='<group>')
projectID=uid('project');targetIDs={n:uid('target:'+n) for n in products}
# The app and tests import ParlaCore, whose module imports `whisper`, so they need the module map and public headers too.
swift_includes=['$(inherited)','$(SRCROOT)/'+core.MODULE_MAP_DIR]
header_includes=['$(inherited)']+['$(SRCROOT)/'+core.VENDOR+'/'+d for d in core.PUBLIC_INCLUDES]
def depend(name,child):
 proxy=add(name+':proxy:'+child,isa='PBXContainerItemProxy',containerPortal=projectID,proxyType=1,remoteGlobalIDString=targetIDs[child],remoteInfo=child)
 return add(name+':dependency:'+child,isa='PBXTargetDependency',target=targetIDs[child],targetProxy=proxy)
for name in products:
 kind={'Parla':'App','ParlaKeyboard':'Keyboard','ParlaWidgets':'Widgets','ParlaTests':'Tests','ParlaCore':'Core'}[name]
 if kind=='Core':source=[core.SHIM]+core.core_paths()+core.vendor_paths()
 elif kind=='Tests':source=[p for p in files if p.startswith('Tests/')]
 else:
  source=[p for p in files if p.startswith('Sources/Shared/')]
  if kind=='Keyboard':source=[p for p in source if Path(p).name not in ['SystemIntents.swift','RecordingActivity.swift']]
  source += [p for p in files if p.startswith('Sources/'+kind+'/')]
 sourcePhase=add(name+':sources',isa='PBXSourcesBuildPhase',buildActionMask=2147483647,files=[add(name+':source:'+p,isa='PBXBuildFile',fileRef=files[p]) for p in (source if kind=='Core' else sorted(source))],runOnlyForDeploymentPostprocessing=0)
 resources=[]
 if kind not in ['Tests','Core']:
  resources=[add(name+':resource:'+p,isa='PBXBuildFile',fileRef=files[p]) for p in resource_paths]
  privacy=add(name+':privacy',isa='PBXFileReference',lastKnownFileType='text.xml',name='PrivacyInfo.xcprivacy',path='Configuration/'+kind+'-PrivacyInfo.xcprivacy',sourceTree='SOURCE_ROOT')
  objects[rootGroup]['children'].append(privacy)
  # PBX resource destination uses the file reference path's basename, so each target gets its own canonical PrivacyInfo.
  objects[privacy]['path']='Configuration/'+kind+'/PrivacyInfo.xcprivacy'
  location=ROOT/objects[privacy]['path'];location.parent.mkdir(exist_ok=True);location.write_bytes((ROOT/f'Configuration/{kind}-PrivacyInfo.xcprivacy').read_bytes())
  resources += [add(name+':privacy-resource',isa='PBXBuildFile',fileRef=privacy)]
 links=[add(name+':link:ParlaCore',isa='PBXBuildFile',fileRef=products['ParlaCore'])] if kind=='App' else []
 frameworks=add(name+':frameworks',isa='PBXFrameworksBuildPhase',buildActionMask=2147483647,files=links,runOnlyForDeploymentPostprocessing=0)
 phases=[sourcePhase,frameworks]+([add(name+':resources',isa='PBXResourcesBuildPhase',buildActionMask=2147483647,files=resources,runOnlyForDeploymentPostprocessing=0)] if kind!='Core' else []);dependencies=[]
 if kind=='App':
  dependencies.append(depend(name,'ParlaCore'))
  embeds=[]
  for child in ['ParlaKeyboard','ParlaWidgets']:
   dependencies.append(depend(name,child))
   embeds.append(add(name+':embed:'+child,isa='PBXBuildFile',fileRef=products[child],settings={'ATTRIBUTES':['RemoveHeadersOnCopy']}))
  phases.append(add(name+':embed',isa='PBXCopyFilesBuildPhase',buildActionMask=2147483647,dstPath='',dstSubfolderSpec=13,files=embeds,name='Embed App Extensions',runOnlyForDeploymentPostprocessing=0))
 if kind=='Tests':dependencies.append(depend(name,'Parla'))
 configs=[]
 for mode in ['Debug','Release']:
  settings={'PRODUCT_NAME':name,'PRODUCT_MODULE_NAME':name,'SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':core.DEPLOYMENT,'TARGETED_DEVICE_FAMILY':'1','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SWIFT_VERSION':'5.0','CLANG_ENABLE_MODULES':'YES','CODE_SIGN_STYLE':'Automatic','SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O','ENABLE_TESTABILITY':'YES' if mode=='Debug' else 'NO','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'$(inherited)'+(' PARLA_APP' if kind=='App' else ''),'LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks'],'PRODUCT_BUNDLE_IDENTIFIER':'$(PARLA_BUNDLE_PREFIX)'+{'App':'','Keyboard':'.keyboard','Widgets':'.widgets','Tests':'.tests','Core':'.core'}[kind],'GENERATE_INFOPLIST_FILE':'YES' if kind=='Tests' else 'NO','CODE_SIGN_ENTITLEMENTS':'Configuration/'+kind+'.entitlements' if kind in ['App','Keyboard','Widgets'] else '', 'SKIP_INSTALL':'NO' if kind=='App' else 'YES','SUPPORTS_MACCATALYST':'NO','SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD':'NO','SWIFT_EMIT_LOC_STRINGS':'NO','ENABLE_USER_SCRIPT_SANDBOXING':'YES'}
  if kind in ['App','Keyboard','Widgets']:settings['INFOPLIST_FILE']='Configuration/'+kind+'-Info.plist'
  if kind=='App':settings.update({'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon','OTHER_LDFLAGS':['$(inherited)','-lc++','-framework','Accelerate']})
  if kind in ['App','Tests','Core']:settings.update({'SWIFT_INCLUDE_PATHS':swift_includes,'HEADER_SEARCH_PATHS':header_includes})
  if kind=='Core':
   # ggml is unusable at -O0, so the C/C++ half stays optimized in Debug too. Defines/private includes never reach Swift.
   cflags=['$(inherited)']+['-I$(SRCROOT)/'+core.VENDOR+'/'+d for d in core.PRIVATE_INCLUDES]+['-D'+d.replace('"','\\"') for d in core.DEFINES]+(['-DNDEBUG'] if mode=='Release' else [])
   settings.update({'MACH_O_TYPE':'staticlib','SWIFT_INSTALL_OBJC_HEADER':'NO','GCC_C_LANGUAGE_STANDARD':core.C_STANDARD,'CLANG_CXX_LANGUAGE_STANDARD':core.CXX_STANDARD,'GCC_OPTIMIZATION_LEVEL':'3','OTHER_CFLAGS':cflags})
  if kind in ['Keyboard','Widgets']:settings['APPLICATION_EXTENSION_API_ONLY']='YES'
  if kind=='Tests':settings.update({'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/Parla.app/Parla','BUNDLE_LOADER':'$(TEST_HOST)'})
  configs.append(add(name+':config:'+mode,isa='XCBuildConfiguration',baseConfigurationReference=config,buildSettings=settings,name=mode))
 configList=add(name+':configs',isa='XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
 productType={'App':'com.apple.product-type.application','Tests':'com.apple.product-type.bundle.unit-test','Core':'com.apple.product-type.library.static'}.get(kind,'com.apple.product-type.app-extension')
 add('target:'+name,isa='PBXNativeTarget',buildConfigurationList=configList,buildPhases=phases,buildRules=[],dependencies=dependencies,name=name,productName=name,productReference=products[name],productType=productType)
projectConfigs=[]
for mode in ['Debug','Release']:
 projectConfigs.append(add('project:config:'+mode,isa='XCBuildConfiguration',buildSettings={'SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':core.DEPLOYMENT,'SWIFT_VERSION':'5.0','CLANG_ENABLE_OBJC_ARC':'YES','GCC_C_LANGUAGE_STANDARD':'gnu17'},name=mode))
projectConfigList=add('project:configs',isa='XCConfigurationList',buildConfigurations=projectConfigs,defaultConfigurationIsVisible=0,defaultConfigurationName='Release')
add('project',isa='PBXProject',attributes={'BuildIndependentTargetsInParallel':1,'LastUpgradeCheck':'2660','TargetAttributes':{targetIDs['ParlaTests']:{'TestTargetID':targetIDs['Parla']}}},buildConfigurationList=projectConfigList,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings=0,knownRegions=['en','Base'],mainGroup=rootGroup,productRefGroup=productsGroup,projectDirPath='',projectRoot='',targets=list(targetIDs.values()))
project=ROOT/'Parla.xcodeproj';project.mkdir(exist_ok=True)
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n'+dump({'archiveVersion':1,'classes':{},'objectVersion':56,'objects':objects,'rootObject':projectID})+'\n')
scheme=project/'xcshareddata/xcschemes';scheme.mkdir(parents=True,exist_ok=True)
def buildable(name):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{targetIDs[name]}" BuildableName="{paths[name]}" BlueprintName="{name}" ReferencedContainer="container:Parla.xcodeproj"/>'
(scheme/'Parla.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2660" version="1.7">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable('Parla')}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{buildable('ParlaTests')}</TestableReference></Testables><MacroExpansion>{buildable('Parla')}</MacroExpansion></TestAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{buildable('Parla')}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable('Parla')}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>\n''')
print('Wrote Parla.xcodeproj:',len(objects),'objects; five targets (app, keyboard, widgets, tests, ParlaCore static library); no build run')
