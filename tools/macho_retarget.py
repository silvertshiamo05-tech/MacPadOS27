#!/usr/bin/env python3
"""macho_retarget - make a macOS arm64 Mach-O loadable by dyld on iOS/iPadOS.

The zorrobyte "macos-on-ios" technique: extract the arm64 slice and rewrite
its platform load command (LC_BUILD_VERSION platform macOS -> iOS, or
LC_VERSION_MIN_MACOSX -> LC_VERSION_MIN_IPHONEOS). The existing code signature
becomes invalid; re-sign afterwards (LiveContainer does this on install, or
`codesign -f -s -` in CI).

Usage: python3 tools/macho_retarget.py IN OUT [--minos 15.0] [--sdk 18.0]
"""
import argparse
import struct
import sys

LC_BUILD_VERSION = 0x32
LC_VERSION_MIN_MACOSX = 0x24
LC_VERSION_MIN_IPHONEOS = 0x25
PLATFORM_MACOS, PLATFORM_IOS = 1, 2
CPU_ARM64 = 0x0100000C


def encode_version(s):
    parts = [int(p) for p in s.split(".")] + [0, 0]
    return (parts[0] << 16) | (parts[1] << 8) | parts[2]


def arm64_slice(data):
    magic = struct.unpack_from(">I", data)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        n = struct.unpack_from(">I", data, 4)[0]
        is64 = magic == 0xCAFEBABF
        for i in range(n):
            if is64:
                cpu, sub, off, size = struct.unpack_from(">iiQQ", data, 8 + i * 32)
            else:
                cpu, sub, off, size = struct.unpack_from(">iiII", data, 8 + i * 20)
            if cpu & 0xFFFFFFFF == CPU_ARM64 and (sub & 0xFF) != 2:
                return bytearray(data[off:off + size])
        raise SystemExit("no arm64 slice in fat file")
    if struct.unpack_from("<I", data)[0] == 0xFEEDFACF:
        if struct.unpack_from("<I", data, 4)[0] != CPU_ARM64:
            raise SystemExit("thin file is not arm64")
        return bytearray(data)
    raise SystemExit("not a Mach-O file")


def retarget(buf, minos, sdk):
    """Patch in place. Returns a list of human-readable changes."""
    ncmds, sizeofcmds = struct.unpack_from("<II", buf, 16)
    p, changes = 32, []
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", buf, p)
        if cmd == LC_BUILD_VERSION:
            plat, old_min, old_sdk = struct.unpack_from("<III", buf, p + 8)
            struct.pack_into("<III", buf, p + 8, PLATFORM_IOS, minos, sdk)
            changes.append(f"LC_BUILD_VERSION platform {plat}->{PLATFORM_IOS}, minos {old_min:#x}->{minos:#x}, sdk {old_sdk:#x}->{sdk:#x}")
        elif cmd == LC_VERSION_MIN_MACOSX:
            struct.pack_into("<IIII", buf, p, LC_VERSION_MIN_IPHONEOS, size, minos, sdk)
            changes.append("LC_VERSION_MIN_MACOSX -> LC_VERSION_MIN_IPHONEOS")
        p += size
    if not changes:
        raise SystemExit("no platform load command found")
    return changes


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--minos", default="15.0")
    ap.add_argument("--sdk", default="18.0")
    a = ap.parse_args(argv)
    with open(a.input, "rb") as fh:
        buf = arm64_slice(fh.read())
    for c in retarget(buf, encode_version(a.minos), encode_version(a.sdk)):
        print(c)
    with open(a.output, "wb") as fh:
        fh.write(buf)
    print(f"wrote {a.output} ({len(buf)} bytes, arm64 thin)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
