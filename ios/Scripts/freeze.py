#!/usr/bin/env python3
"""Snapshot the iOS-owned source plus hashes of the referenced desktop/whisper inputs. Writes only under evidence/."""
from pathlib import Path
import hashlib,json,zipfile
import parlacore as core
r=Path(__file__).resolve().parents[1];out=r/'evidence/implementation';out.mkdir(parents=True,exist_ok=True)
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
paths=[r/'README.md',r/'.gitignore']
for directory in ['Sources','Resources','Configuration','Tests','Scripts','Parla.xcodeproj','docs']:
 paths.extend(p for p in (r/directory).rglob('*') if p.is_file() and '__pycache__' not in p.parts and 'xcuserdata' not in p.parts and p.name!='.DS_Store')
rows=[{'path':str(p.relative_to(r)),'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(set(paths),key=lambda p:str(p.relative_to(r)))]
inputs=[{'path':p,'sha256':sha(r/p)} for p in core.core_paths()+core.vendor_paths()]
fingerprint=hashlib.sha256(''.join(f"{x['path']}\0{x['sha256']}\0{x.get('bytes','')}\n" for x in rows+inputs).encode()).hexdigest()
with zipfile.ZipFile(out/'ios-source.zip','w',compression=zipfile.ZIP_DEFLATED,compresslevel=9) as archive:
 for item in rows:
  info=zipfile.ZipInfo(item['path'],date_time=(1980,1,1,0,0,0));info.compress_type=zipfile.ZIP_DEFLATED;info.external_attr=0o100644<<16
  archive.writestr(info,(r/item['path']).read_bytes())
(out/'freeze.json').write_text(json.dumps({'files':rows,'referenced_inputs':inputs,'fingerprint':fingerprint,'source_zip_sha256':sha(out/'ios-source.zip')},indent=2)+'\n')
print(json.dumps({'files':len(rows),'referenced_inputs':len(inputs),'fingerprint':fingerprint},indent=2))
