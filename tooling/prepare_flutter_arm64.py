"""Select ARM64 engine artifacts on an ARM64 host running Flutter's x64 SDK.

Flutter 3.47.5 distributes a Windows x64 SDK, and its desktop command selects
the target from the Dart process ABI. The hosted ARM64 runner can execute the
x64 tool, but must use native ARM64 engine and snapshot artifacts. This narrow
patch is checked against the pinned SDK source and never applied on x64 hosts.
"""
import hashlib
import os
import sys
from pathlib import Path

if os.name != "nt" or "ARM64" not in {
    os.environ.get("PROCESSOR_ARCHITECTURE", "").upper(),
    os.environ.get("PROCESSOR_ARCHITEW6432", "").upper(),
}:
    raise SystemExit("This SDK adaptation requires an actual Windows ARM64 host")

root = Path(os.environ["FLUTTER_ROOT"])
source = root / "packages/flutter_tools/lib/src/base/os.dart"
backup = root / "bin/cache/linsen-os.dart.original"
if "--restore" in sys.argv:
    if backup.exists():
        source.write_bytes(backup.read_bytes())
        backup.unlink()
        for name in ("flutter_tools.snapshot", "flutter_tools.stamp", "windows-sdk.stamp"):
            (root / "bin/cache" / name).unlink(missing_ok=True)
        print("Restored the pinned Flutter SDK before caching")
    raise SystemExit(0)
original_bytes = source.read_bytes()
raw = original_bytes.replace(b"\r\n", b"\n")
if hashlib.sha256(raw).hexdigest() != "4ccab0a141cdf7f7d0bed5eb8c6df5f27df7a61b1ecb6c48e15faa33b7f58ba9":
    raise SystemExit("Pinned Flutter source differs; review the ARM64 adaptation")
original = b"Abi.windowsX64 => HostPlatform.windows_x64,"
assert raw.count(original) == 1
backup.write_bytes(original_bytes)
source.write_bytes(raw.replace(original, b"Abi.windowsX64 => HostPlatform.windows_arm64,"))
for name in ("flutter_tools.snapshot", "flutter_tools.stamp", "windows-sdk.stamp"):
    (root / "bin/cache" / name).unlink(missing_ok=True)
print("Flutter tools will select native Windows ARM64 artifacts on this ARM64 host")
