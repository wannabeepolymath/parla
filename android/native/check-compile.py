#!/usr/bin/env python3
"""Check generated Android compile commands without linking, packaging, or running a model."""
import concurrent.futures, json, pathlib, shlex, subprocess, sys
root = pathlib.Path(__file__).resolve().parent.parent
entries = []
for abi in ('arm64-v8a','x86_64'):
    paths = list((root/'app/.cxx/Debug').glob('*/'+abi+'/compile_commands.json'))
    if not paths: sys.exit('Configure CMake for '+abi+' first')
    database = max(paths,key=lambda p: p.stat().st_mtime)
    for item in json.loads(database.read_text()):
        args = shlex.split(item['command']); clean = []; skip = False
        for arg in args:
            if skip: skip = False; continue
            if arg == '-o': skip = True; continue
            if arg == '-c': continue
            clean.append(arg)
        clean.append('-fsyntax-only')
        assert not any('march=native' in arg or 'mcpu=native' in arg for arg in clean)
        entries.append((abi,item,clean))
def check(entry):
    abi,item,args = entry
    result = subprocess.run(args,cwd=item['directory'],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    return abi,item['file'],result.returncode,result.stdout
failed = False
with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    for abi,file,code,output in pool.map(check,entries):
        print(abi,pathlib.Path(file).name,'PASS' if code == 0 else 'FAIL')
        if code:
            print(output); failed = True
print('Translation units checked:',len(entries))
sys.exit(1 if failed else 0)
