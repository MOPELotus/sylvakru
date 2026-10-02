#!/usr/bin/env python3
"""Fetch a fixed LGPL-only libmpv and verify its hash before packaging."""
import hashlib,json,pathlib,sys,urllib.request,zipfile,io,time
root=pathlib.Path(__file__).resolve().parents[1]
arch=sys.argv[1]; entry=json.loads((root/'tooling/mpv-lock.json').read_text())[arch]
output=root/'native/mpv'/arch; output.mkdir(parents=True,exist_ok=True)
for attempt in range(4):
    try:
        with urllib.request.urlopen(entry['url'], timeout=90) as response: raw=response.read()
        break
    except Exception:
        if attempt==3: raise
        time.sleep(2)
if hashlib.sha256(raw).hexdigest()!=entry['sha256']: raise SystemExit('libmpv checksum mismatch')
with zipfile.ZipFile(io.BytesIO(raw)) as archive:
    dlls=[name for name in archive.namelist() if name.lower().endswith('.dll')]
    if not any(pathlib.PurePosixPath(name).name=='libmpv-2.dll' for name in dlls): raise SystemExit('Missing libmpv DLL')
    for name in dlls:
        data=archive.read(name)
        if b'--enable-nonfree' in data or b'nonfree and unredistributable' in data: raise SystemExit('Unredistributable runtime rejected')
        (output/pathlib.PurePosixPath(name).name).write_bytes(data)
print('Verified',arch,entry['sha256'])
