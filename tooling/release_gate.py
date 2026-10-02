#!/usr/bin/env python3
"""Release requires a concrete, current acceptance record; CI cannot invent one."""
import hashlib, json, pathlib, re, subprocess, sys
root = pathlib.Path(__file__).resolve().parents[1]
record = json.loads((root / 'docs/verification.json').read_text())
tag = sys.argv[1]
version = re.search(r'^version: ([^+\n]+)', (root/'pubspec.yaml').read_text(), re.M)[1]
if tag != 'v'+version: raise SystemExit('Tag and package version differ')
required = ['windows_x64','windows_arm64','android_arm','android_arm64','coloros16_controls','coloros16_lyrics','background_audio','mixed_queue','cloud_upload','scrobble','license_audit']
missing = [key for key in required if not isinstance(record.get(key), dict) or record[key].get('passed') is not True or not record[key].get('evidence')]
if missing: raise SystemExit('Release blocked; missing actual acceptance: '+', '.join(missing))
hash = hashlib.sha256()
files = subprocess.check_output(['git','ls-files','-z'], cwd=root).split(b'\0')
for name in sorted(files):
    if not name: continue
    path = name.decode()
    if path.startswith('docs/'): continue
    hash.update(name+b'\0'); hash.update((root/path).read_bytes()); hash.update(b'\0')
if record.get('implementation_sha256') != hash.hexdigest(): raise SystemExit('Acceptance record does not match this implementation')
print('Acceptance record verified for', tag)
