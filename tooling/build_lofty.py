#!/usr/bin/env python3
"""Rebuild Lofty for each Windows CPU; upstream package contains an x64-only DLL."""
import json,pathlib,shutil,subprocess,sys,urllib.parse
root=pathlib.Path(__file__).resolve().parents[1]
revision='1d4c7fd8e0aeab93a302d7db4ea5c92414c4d429'
source=root/'native/lofty-source'
if not source.exists(): subprocess.run(['git','clone','--no-checkout','https://github.com/AfalpHy/audio_tags_lofty.git',str(source)],check=True)
subprocess.run(['git','fetch','--depth','1','origin',revision],cwd=source,check=True)
subprocess.run(['git','checkout','--detach',revision],cwd=source,check=True)
target={'x64':'x86_64-pc-windows-msvc','arm64':'aarch64-pc-windows-msvc'}[sys.argv[1]]
manifest=source/'rust/lofty_ffi/Cargo.toml'
subprocess.run(['cargo','build','--release','--locked','--manifest-path',str(manifest),'--target',target],check=True)
config=root/'.dart_tool/package_config.json'
package=next(p for p in json.loads(config.read_text())['packages'] if p['name']=='audio_tags_lofty')
uri=urllib.parse.urlparse(package['rootUri'])
if uri.scheme=='file':
    path=urllib.parse.unquote(uri.path)
    if sys.platform=='win32' and path.startswith('/'): path=path[1:]
    directory=pathlib.Path(path)
else: directory=(config.parent/urllib.parse.unquote(package['rootUri'])).resolve()
shutil.copy2(manifest.parent/'target'/target/'release/lofty_ffi.dll',directory/'windows/lib/lofty_ffi.dll')
print('Lofty FFI rebuilt for',sys.argv[1],revision)
