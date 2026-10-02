#!/usr/bin/env python3
"""Reject accidental x64 native dependencies in Windows ARM64 packages."""
import pathlib, struct, sys
expected = {'x64': 0x8664, 'arm64': 0xAA64}[sys.argv[2]]
for file in pathlib.Path(sys.argv[1]).rglob('*'):
    if file.suffix.lower() not in {'.exe', '.dll'}: continue
    raw = file.read_bytes()
    pe = struct.unpack_from('<I', raw, 0x3C)[0]
    machine = struct.unpack_from('<H', raw, pe + 4)[0]
    if raw[pe:pe+4] != b'PE\0\0' or machine != expected:
        raise SystemExit(f'Wrong architecture: {file.name}: {machine:x}, expected {expected:x}')
    print(f'{file.name}: {sys.argv[2]}')
