#!/usr/bin/env python3
"""SDK semantic checks only: no object code, link, build, simulator, or live calls.
ParlaCore is type-checked, then its module interface is emitted so the app (with SIL diagnostics) and tests check against it;
the whisper/ggml C/C++ sources get clang -fsyntax-only for iOS arm64."""
from pathlib import Path
import subprocess,os,json,sys
import parlacore as core
r=Path(__file__).resolve().parents[1];out=r/'evidence/implementation'
for folder in ['tmp','module-cache','modules']:(out/folder).mkdir(parents=True,exist_ok=True)
sdk=subprocess.check_output(['xcrun','--sdk','iphoneos','--show-sdk-path'],text=True).strip()
target='arm64-apple-ios'+core.DEPLOYMENT
vendor=(r/core.VENDOR).resolve()
importer=['-I',str(r/core.MODULE_MAP_DIR)]+[x for d in core.PUBLIC_INCLUDES for x in ['-Xcc','-I'+str(vendor/d)]]
base=['xcrun','swiftc','-sdk',sdk,'-target',target,'-swift-version','5','-warnings-as-errors','-module-cache-path',str(out/'module-cache')]
coreFiles=[r/core.SHIM]+[(r/p).resolve() for p in core.core_paths()]
shared=list((r/'Sources/Shared').glob('*.swift'));app=list((r/'Sources/App').glob('*.swift'))
uses_core=importer+['-I',str(out/'modules')]
jobs=[('parlacore',['-typecheck','-module-name','ParlaCore','-parse-as-library']+importer,coreFiles),
 # Interface only (desktop bodies are type-checked above, not lowered), so dependents can import ParlaCore.
 ('parlacore-interface',['-emit-module','-experimental-skip-non-inlinable-function-bodies','-emit-module-path',str(out/'modules/ParlaCore.swiftmodule'),'-module-name','ParlaCore','-parse-as-library']+importer,coreFiles),
 # Whole-module SIL diagnostics for the app's own code (escaping captures, definite initialization); the module is discarded.
 ('app',['-emit-module','-emit-module-path',str(out/'tmp/Parla.swiftmodule'),'-D','PARLA_APP','-module-name','Parla']+uses_core,shared+app),
 ('keyboard',['-typecheck','-application-extension','-module-name','ParlaKeyboard'],[p for p in shared if p.name not in ['SystemIntents.swift','RecordingActivity.swift']]+list((r/'Sources/Keyboard').glob('*.swift'))),
 ('widgets',['-typecheck','-application-extension','-module-name','ParlaWidgets'],shared+list((r/'Sources/Widgets').glob('*.swift'))),
 ('test-sources',['-typecheck','-D','PARLA_APP','-D','SOURCE_CHECK','-module-name','ParlaTestSourceCheck','-F',str(Path(sdk).parents[2]/'Developer/Library/Frameworks'),'-I',str(Path(sdk).parents[2]/'Developer/usr/lib')]+uses_core,shared+[p for p in app if p.name!='ParlaApp.swift']+list((r/'Tests').glob('*.swift')))]
results=[]
def run(name,cmd,checks):
 result=subprocess.run(cmd,text=True,capture_output=True,env={**os.environ,'TMPDIR':str(out/'tmp')})
 (out/('typecheck-'+name+'.log')).write_text(result.stdout+result.stderr)
 results.append({'target':name,'command':cmd,'exit':result.returncode,'checks':checks})
 print(name,'PASS' if result.returncode==0 else 'FAIL',flush=True)
 if result.returncode:print((result.stdout+result.stderr)[-12000:],flush=True)
 return result.returncode==0
for name,flags,files in jobs:
 if not run(name,base+flags+[str(p) for p in sorted(set(files))],'semantic Swift check; no object code or linking') and name.startswith('parlacore'):break
cflags=['-fsyntax-only','-isysroot',sdk,'-target',target,'-Werror=implicit-function-declaration']+['-I'+str(vendor/d) for d in core.PUBLIC_INCLUDES+core.PRIVATE_INCLUDES]+['-D'+d for d in core.DEFINES]
native=core.native_paths()
failed=[p for p in native if subprocess.run((['xcrun','clang','-std='+core.C_STANDARD] if p.endswith('.c') else ['xcrun','clang++','-std='+core.CXX_STANDARD])+cflags+[str((r/p).resolve())],capture_output=True,text=True).returncode]
results.append({'target':'whisper-ggml-syntax','sources':len(native),'failed':failed,'exit':int(bool(failed)),'checks':'clang -fsyntax-only for '+target+'; no object code'})
print('whisper-ggml-syntax','PASS' if not failed else 'FAIL '+' '.join(failed),f'({len(native)} sources)',flush=True)
(out/'typecheck-results.json').write_text(json.dumps(results,indent=2)+'\n')
sys.exit(0 if all(x['exit']==0 for x in results) and len(results)==len(jobs)+1 else 1)
