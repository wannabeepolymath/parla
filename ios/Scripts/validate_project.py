#!/usr/bin/env python3
"""Read-only structural/resource checks. Does not invoke an Xcode build or compile assets."""
from pathlib import Path
import subprocess,json,plistlib,struct,wave,xml.etree.ElementTree as ET,ast,re
import parlacore as core
r=Path(__file__).resolve().parents[1];out=r/'evidence/implementation';checks=[]
out.mkdir(parents=True,exist_ok=True)
def check(name, condition, detail=''):
 checks.append({'check':name,'passed':bool(condition),'detail':detail})
 if not condition:raise AssertionError(name+': '+detail)
def project():
 cmd=['plutil','-convert','json','-o','-',str(r/'Parla.xcodeproj/project.pbxproj')]
 data=json.loads(subprocess.check_output(cmd));obj=data['objects'];targets={x['name']:x for x in obj.values() if x.get('isa')=='PBXNativeTarget'}
 check('five native targets',set(targets)=={'Parla','ParlaKeyboard','ParlaWidgets','ParlaTests','ParlaCore'})
 for key,x in obj.items():
  if x.get('isa')=='PBXFileReference' and x.get('sourceTree')=='SOURCE_ROOT':check('file reference '+x['path'],(r/x['path']).exists())
  for field in ['fileRef','target','targetProxy','buildConfigurationList','productReference','mainGroup','productRefGroup','containerPortal','remoteGlobalIDString']:
   if field in x:check('resolved '+key+'.'+field,x[field] in obj)
  for field in ['children','buildPhases','dependencies','buildConfigurations','targets','files']:
   for child in x.get(field,[]):check('resolved '+key+'.'+field,child in obj)
 target_sources={};links={};configs={}
 for name,target in targets.items():
  paths=[];resources=[];linked=[]
  for phaseID in target['buildPhases']:
   phase=obj[phaseID]
   for buildID in phase.get('files',[]):
    ref=obj[obj[buildID]['fileRef']];path=ref.get('path',ref.get('name'))
    if phase['isa']=='PBXSourcesBuildPhase':paths.append(path)
    if phase['isa']=='PBXResourcesBuildPhase':resources.append(path)
    if phase['isa']=='PBXFrameworksBuildPhase':linked.append(path)
  check(name+' no duplicate sources',len(paths)==len(set(paths)))
  target_sources[name]=sorted(paths);links[name]=linked
  configs[name]=[obj[x]['buildSettings'] for x in obj[target['buildConfigurationList']]['buildConfigurations']]
  check(name+' minimum iOS '+core.DEPLOYMENT,all(x['IPHONEOS_DEPLOYMENT_TARGET']==core.DEPLOYMENT for x in configs[name]))
  if name=='Parla':check('app compile condition',all('PARLA_APP' in x['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] for x in configs[name]))
  if name in ['ParlaKeyboard','ParlaWidgets']:check(name+' extension-only APIs',all(x['APPLICATION_EXTENSION_API_ONLY']=='YES' for x in configs[name]))
  if name in ['Parla','ParlaKeyboard','ParlaWidgets']:
   kind={'Parla':'App','ParlaKeyboard':'Keyboard','ParlaWidgets':'Widgets'}[name]
   check(name+' canonical privacy resource','Configuration/'+kind+'/PrivacyInfo.xcprivacy' in resources)
   check(name+' catalog, fonts and cues','Resources/Assets.xcassets' in resources and len([p for p in resources if p.endswith('.ttf')])==5 and 'Resources/dictation-start.wav' in resources)
  check(name+' at least one source',len(paths)>0)
 # ParlaCore: exactly the shim, the listed unmodified desktop files and the whisper/ggml CPU sources.
 expected=sorted([core.SHIM]+core.core_paths()+core.native_paths())
 check('ParlaCore sources',target_sources['ParlaCore']==expected,str(set(expected)^set(target_sources['ParlaCore'])))
 check('ParlaCore static library',targets['ParlaCore']['productType']=='com.apple.product-type.library.static' and obj[targets['ParlaCore']['productReference']]['path']=='libParlaCore.a')
 check('ParlaCore excludes macOS-only files',not any(Path(p).stem in ['AudioRecorder','ClipboardDelivery','Inserter','Hotkey','ShortcutDisplay','ParakeetTrust'] for p in target_sources['ParlaCore']))
 check('no Metal/BLAS/KleidiAI/parakeet native sources',not any(re.search(r'metal|blas|kleidiai|llamafile|parakeet',p,re.I) for p in target_sources['ParlaCore'] if p.startswith(core.VENDOR)))
 for x in configs['ParlaCore']:
  flags=' '.join(x['OTHER_CFLAGS'])
  check('ParlaCore C defines',all('-D'+d.replace('"','\\"') in x['OTHER_CFLAGS'] for d in core.DEFINES) and 'GGML_USE_METAL' not in flags and 'GGML_USE_BLAS' not in flags)
  check('ParlaCore defines stay out of Swift','GCC_PREPROCESSOR_DEFINITIONS' not in x and 'OTHER_SWIFT_FLAGS' not in x)
 for name in ['Parla','ParlaTests','ParlaCore']:
  for x in configs[name]:check(name+' finds whisper module','$(SRCROOT)/'+core.MODULE_MAP_DIR in x['SWIFT_INCLUDE_PATHS'] and '$(SRCROOT)/'+core.VENDOR+'/ggml/include' in x['HEADER_SEARCH_PATHS'])
 check('app links ParlaCore',links['Parla']==['libParlaCore.a'] and all('-lc++' in x['OTHER_LDFLAGS'] and 'Accelerate' in x['OTHER_LDFLAGS'] for x in configs['Parla']))
 check('app depends on ParlaCore and extensions',{obj[obj[d]['target']]['name'] for d in targets['Parla']['dependencies']}=={'ParlaCore','ParlaKeyboard','ParlaWidgets'})
 for name in ['ParlaKeyboard','ParlaWidgets']:
  check(name+' does not link ParlaCore',not links[name] and not targets[name]['dependencies'] and not any(p.startswith('../') or '/Core/' in p or '/App/' in p for p in target_sources[name]))
 all_files={str(p.relative_to(r)) for p in (r/'Sources').rglob('*') if p.suffix in ['.swift','.c','.cpp']}
 check('all source files included',all_files==set(p for paths in target_sources.values() for p in paths if p.startswith('Sources/')))
 check('keyboard has no app/intents sources',not any(p.endswith('SystemIntents.swift') for p in target_sources['ParlaKeyboard']))
 embed=[obj[x] for x in targets['Parla']['buildPhases'] if obj[x]['isa']=='PBXCopyFilesBuildPhase']
 check('embed extensions phase',len(embed)==1 and str(embed[0]['dstSubfolderSpec'])=='13' and len(embed[0]['files'])==2)
 embedded={obj[obj[x]['fileRef']]['path'] for x in embed[0]['files']};check('both extension products embedded',embedded=={'ParlaKeyboard.appex','ParlaWidgets.appex'})
 tree=ET.parse(r/'Parla.xcodeproj/xcshareddata/xcschemes/Parla.xcscheme')
 for ref in tree.findall('.//BuildableReference'):check('scheme resolves '+ref.attrib['BlueprintName'],ref.attrib['BlueprintIdentifier'] in obj)
 check('scheme includes unit tests',len(tree.findall('.//TestableReference'))==1)
 (out/'target-sources.json').write_text(json.dumps(target_sources,indent=2)+'\n')
project()
modulemap=(r/core.MODULE_MAP_DIR/'module.modulemap').read_text();header=re.search(r'header "([^"]+)"',modulemap).group(1)
check('relative whisper module map',not header.startswith('/') and (r/core.MODULE_MAP_DIR/header).resolve()==(r/core.VENDOR/'include/whisper.h').resolve())
for p in sorted((r/'Configuration').rglob('*')):
 if p.suffix in ['.plist','.entitlements','.xcprivacy']:
  data=plistlib.loads(p.read_bytes());check('valid plist '+str(p.relative_to(r)),isinstance(data,dict))
for kind in ['App','Keyboard','Widgets']:
 info=plistlib.loads((r/f'Configuration/{kind}-Info.plist').read_bytes())
 ent=plistlib.loads((r/f'Configuration/{kind}.entitlements').read_bytes())
 check(kind+' shared configurable group',info['ParlaAppGroup']=='$(PARLA_APP_GROUP)' and ent['com.apple.security.application-groups']==['$(PARLA_APP_GROUP)'])
 check(kind+' no keychain sharing','keychain-access-groups' not in ent)
 check(kind+' display name',info['CFBundleDisplayName']=='Parla')
 check(kind+' exact font declarations',all((r/'Resources'/font).exists() for font in info['UIAppFonts']))
app=plistlib.loads((r/'Configuration/App-Info.plist').read_bytes());keyboard=plistlib.loads((r/'Configuration/Keyboard-Info.plist').read_bytes())
check('app minimum OS',app['MinimumOSVersion']==core.DEPLOYMENT)
check('app mic background and activities','audio' in app['UIBackgroundModes'] and app['NSSupportsLiveActivities'] and 'on this iPhone' in app['NSMicrophoneUsageDescription'])
check('public parla scheme',app['CFBundleURLTypes'][0]['CFBundleURLSchemes']==['parla'])
check('keyboard extension declaration',keyboard['NSExtension']['NSExtensionPointIdentifier']=='com.apple.keyboard-service' and keyboard['NSExtension']['NSExtensionAttributes']['RequestsOpenAccess'])
for p in sorted((r/'Resources/Assets.xcassets').glob('*.colorset/Contents.json')):json.loads(p.read_text())
check('color sets parse',True)
png=(r/'Resources/Assets.xcassets/AppIcon.appiconset/ParlaIcon.png').read_bytes();check('opaque RGB 1024 icon',png[:8]==b'\x89PNG\r\n\x1a\n' and struct.unpack('!2I5B',png[16:29])==(1024,1024,8,2,0,0,0))
for name in ['dictation-start.wav','dictation-stop.wav']:
 with wave.open(str(r/'Resources'/name)) as w:check('cue '+name,w.getnchannels()==1 and w.getsampwidth()==2 and 0.1<w.getnframes()/w.getframerate()<1)
for p in (r/'Scripts').glob('*.py'):ast.parse(p.read_text());check('Python parse '+p.name,True)
# Forbidden runtime patterns in iOS-owned source (the desktop core is checked by its own repository).
source='\n'.join(p.read_text() for p in (r/'Sources').rglob('*.swift'))
for forbidden in ['api.openai.com','OpenAIProvider','KeychainStore','documentContextBeforeInput','documentContextAfterInput','selectedText','UserDefaults','http://','sk-proj-','kSecAttrAccessGroup']:
 check('source boundary '+forbidden,forbidden not in source.replace('// No UserDefaults session cache','// no cached session'))
extension='\n'.join(p.read_text() for d in ['Shared','Keyboard','Widgets'] for p in (r/'Sources'/d).glob('*.swift'))
check('extensions never import ParlaCore or credentials','import ParlaCore' not in extension and 'Credential' not in extension)
# Product naming: no old product names in shipped text, lower-case "parla" only in identifiers and the URL scheme.
names=[p for d in ['Sources','Resources','Configuration','Scripts','Tests','docs'] for p in (r/d).rglob('*') if p.is_file() and p.suffix in ['.swift','.py','.md','.plist','.txt','.strings','.xcprivacy','.entitlements','.xcconfig']]+[r/'README.md']
for p in names:check('product name '+str(p.relative_to(r)),not re.search(r'wh?ispr',p.read_text(errors='ignore'),re.I))
(out/'project-validation.json').write_text(json.dumps({'passed':True,'checks':checks,'count':len(checks),'limits':'Structural/source checks only. No asset compiler, app build, linker, intent extraction, test execution or device verification.'},indent=2)+'\n')
print('PASS:',len(checks),'structural/resource checks; no build or runtime execution')
