"""Inspect the packaged ABI and embedded runtime, without claiming device acceptance."""
import hashlib
import struct
import sys
import zipfile

architecture = sys.argv[2]
abi, machine, elf_class = {
    'arm': ('armeabi-v7a', 40, 1),
    'arm64': ('arm64-v8a', 183, 2),
}[architecture]
required = {'liblinsen_tuneweave.so', 'libmpv.so', 'libflutter.so', 'libapp.so'}
found = set()
warnings = []
with zipfile.ZipFile(sys.argv[1]) as package:
    for name in package.namelist():
        if not name.startswith('lib/') or not name.endswith('.so'):
            continue
        if name.split('/')[1] != abi:
            raise SystemExit('Unexpected packaged ABI: ' + name)
        raw = package.read(name)
        if raw[:4] != b'\x7fELF' or raw[4] != elf_class or raw[5] != 1:
            raise SystemExit('Invalid ELF class/endian: ' + name)
        if struct.unpack_from('<H', raw, 18)[0] != machine:
            raise SystemExit('Wrong ELF machine: ' + name)
        bits64 = elf_class == 2
        offset = struct.unpack_from('<Q' if bits64 else '<I', raw, 32 if bits64 else 28)[0]
        size, count = struct.unpack_from('<HH', raw, 54 if bits64 else 42)
        alignment = []
        for i in range(count):
            at = offset + i * size
            if struct.unpack_from('<I', raw, at)[0] == 1:
                alignment.append(struct.unpack_from('<Q' if bits64 else '<I', raw, at + (48 if bits64 else 28))[0])
        if architecture == 'arm64' and min(alignment, default=0) < 16384:
            warnings.append(name + ' needs a 16 KB page-size compatibility check')
        library = name.rsplit('/', 1)[1]
        found.add(library)
        if library == 'liblinsen_tuneweave.so':
            for symbol in (b'linsen_runtime_start', b'linsen_runtime_stop', b'linsen_runtime_free'):
                if symbol not in raw:
                    raise SystemExit('Missing embedded runtime export: ' + symbol.decode())
        if library == 'libmpv.so':
            if b'nonfree and unredistributable' in raw or b'--enable-nonfree' in raw:
                raise SystemExit('Nonfree FFmpeg runtime cannot be distributed')
            if b'LGPL version 3 or later' not in raw or b'--disable-gpl' not in raw:
                raise SystemExit('Packaged FFmpeg configuration needs a new license audit')
        print(name, 'sha256=' + hashlib.sha256(raw).hexdigest(), 'load_alignment=' + str(alignment))
if required - found:
    raise SystemExit('Missing packaged libraries: ' + ', '.join(sorted(required - found)))
for warning in warnings:
    print('::warning::' + warning)
print('Verified packaged architecture and runtime:', abi)
