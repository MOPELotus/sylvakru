#!/usr/bin/env python3
"""Build the pinned TuneWeave library for an application architecture."""
import argparse
import os
import pathlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parents[1]
p = argparse.ArgumentParser()
p.add_argument('platform', choices=['android', 'windows', 'linux'])
p.add_argument('arch', choices=['arm', 'arm64', 'x64'])
a = p.parse_args()
manifest = ROOT / 'native/tuneweave_runtime/Cargo.toml'
env = dict(os.environ)
if a.platform == 'android':
    target, abi, compiler = {
        'arm': ('armv7-linux-androideabi', 'armeabi-v7a', 'armv7a-linux-androideabi'),
        'arm64': ('aarch64-linux-android', 'arm64-v8a', 'aarch64-linux-android'),
    }[a.arch]
    ndk = pathlib.Path(env['ANDROID_NDK_HOME'])
    tools = ndk / 'toolchains/llvm/prebuilt/linux-x86_64/bin'
    env['CARGO_TARGET_' + target.replace('-', '_').upper() + '_LINKER'] = str(tools / (compiler + '26-clang'))
    env['CC_' + target.replace('-', '_')] = str(tools / (compiler + '26-clang'))
    env['AR_' + target.replace('-', '_')] = str(tools / 'llvm-ar')
    env['RUSTFLAGS'] = '-C link-arg=-Wl,-z,max-page-size=16384'
    output = ROOT / 'android/app/src/main/jniLibs' / abi / 'liblinsen_tuneweave.so'
else:
    target = {'windows': {'x64': 'x86_64-pc-windows-msvc', 'arm64': 'aarch64-pc-windows-msvc'}, 'linux': {'x64': 'x86_64-unknown-linux-gnu'}}[a.platform][a.arch]
    output = ROOT / 'native/libs' / ('linsen_tuneweave.dll' if a.platform == 'windows' else 'liblinsen_tuneweave.so')
subprocess.run(['rustup', 'target', 'add', target], check=True)
subprocess.run(['cargo', 'build', '--locked', '--release', '--manifest-path', str(manifest), '--target', target], env=env, check=True)
source = manifest.parent / 'target' / target / 'release' / output.name
output.parent.mkdir(parents=True, exist_ok=True)
shutil.copy2(source, output)
print(output)
