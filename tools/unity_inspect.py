#!/usr/bin/env python3
"""unity_inspect - identify a Unity macOS build and check it against the
MacPadOS27 iPad loader's requirements (step 1 of the project).

Reads only headers / load commands; never modifies anything.

Accepts any of:
  * a macOS .app bundle folder        (Game.app)
  * a folder that contains the .app   (e.g. a Steam depot download)
  * a .zip of either of the above
  * a loose folder holding just the key files
    (GameAssembly.dylib, global-metadata.dat, globalgamemanagers, Info.plist)

Usage:
  python3 tools/unity_inspect.py PATH                 # human-readable report
  python3 tools/unity_inspect.py PATH --json out.json # also write report JSON

Pure standard library, Python 3.8+. Runs in Termux on Android, on GitHub
Actions, or anywhere else.
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import struct
import sys
import zipfile
from typing import Callable, Dict, List, Optional

SCHEMA = 1

# --------------------------------------------------------------------------
# File sources: a directory or a zip, addressed by '/'-separated paths
# --------------------------------------------------------------------------


class Source:
    def paths(self) -> List[str]:
        raise NotImplementedError

    def size(self, path: str) -> int:
        raise NotImplementedError

    def read(self, path: str, offset: int, length: int) -> bytes:
        raise NotImplementedError

    def reader(self, path: str) -> Callable[[int, int], bytes]:
        return lambda off, n: self.read(path, off, n)


class DirSource(Source):
    def __init__(self, root: str):
        self.root = root
        self._paths = []
        for dirpath, dirnames, filenames in os.walk(root):
            for f in filenames:
                full = os.path.join(dirpath, f)
                self._paths.append(os.path.relpath(full, root).replace(os.sep, "/"))

    def paths(self):
        return self._paths

    def size(self, path):
        return os.path.getsize(os.path.join(self.root, path))

    def read(self, path, offset, length):
        with open(os.path.join(self.root, path), "rb") as fh:
            fh.seek(offset)
            return fh.read(length)


class ZipSource(Source):
    def __init__(self, zpath: str):
        self.zf = zipfile.ZipFile(zpath)
        self._info = {i.filename: i for i in self.zf.infolist() if not i.is_dir()}
        self._cache: Dict[str, bytes] = {}

    def paths(self):
        return list(self._info)

    def size(self, path):
        return self._info[path].file_size

    def read(self, path, offset, length):
        info = self._info[path]
        if info.compress_type == zipfile.ZIP_STORED:
            with self.zf.open(info) as fh:
                fh.seek(offset)
                return fh.read(length)
        # Deflated: inflate once and cache (only a handful of files are read).
        if path not in self._cache:
            self._cache[path] = self.zf.read(info)
        return self._cache[path][offset:offset + length]


def open_source(path: str) -> Source:
    if os.path.isdir(path):
        return DirSource(path)
    if zipfile.is_zipfile(path):
        return ZipSource(path)
    # A single file: wrap its parent folder but only expose that file.
    parent, name = os.path.split(os.path.abspath(path))
    src = DirSource.__new__(DirSource)
    src.root = parent
    src._paths = [name]
    return src


# --------------------------------------------------------------------------
# Mach-O
# --------------------------------------------------------------------------

CPU_TYPES = {
    0x01000007: "x86_64",
    0x0100000C: "arm64",
    0x0200000C: "arm64_32",
    7: "i386",
    12: "arm",
}
PLATFORMS = {
    1: "macOS", 2: "iOS", 3: "tvOS", 4: "watchOS", 5: "bridgeOS",
    6: "macCatalyst", 7: "iOSSimulator", 8: "tvOSSimulator",
    9: "watchOSSimulator", 10: "driverKit", 11: "visionOS",
}
FILETYPES = {1: "object", 2: "execute", 6: "dylib", 8: "bundle", 7: "dylinker"}

LC_REQ_DYLD = 0x80000000
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xB
LC_LOAD_DYLIB = 0xC
LC_ID_DYLIB = 0xD
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_RPATH = 0x1C | LC_REQ_DYLD
LC_REEXPORT_DYLIB = 0x1F | LC_REQ_DYLD
LC_LAZY_LOAD_DYLIB = 0x20
LC_LOAD_UPWARD_DYLIB = 0x23 | LC_REQ_DYLD
LC_CODE_SIGNATURE = 0x1D
LC_VERSION_MIN_MACOSX = 0x24
LC_VERSION_MIN_IPHONEOS = 0x25
LC_ENCRYPTION_INFO_64 = 0x2C
LC_BUILD_VERSION = 0x32
LC_DYLD_CHAINED_FIXUPS = 0x34 | LC_REQ_DYLD

DYLIB_CMDS = {
    LC_LOAD_DYLIB: "load", LC_LOAD_WEAK_DYLIB: "weak", LC_REEXPORT_DYLIB: "reexport",
    LC_LAZY_LOAD_DYLIB: "lazy", LC_LOAD_UPWARD_DYLIB: "upward",
}

# Libraries a macOS binary may link that have no iOS counterpart (or only a
# private one). 'missing' = dyld will refuse to load; 'private' = exists in
# the iOS shared cache but not the public SDK, usually loads.
MAC_ONLY_LIBS = {
    "AppKit": "missing", "Cocoa": "missing", "Carbon": "missing",
    "ApplicationServices": "missing", "OpenGL": "missing", "AGL": "missing",
    "ForceFeedback": "missing", "DiskArbitration": "missing",
    "IOBluetooth": "missing", "CoreWLAN": "missing", "Quartz": "missing",
    "ScreenCaptureKit": "missing", "SystemExtensions": "missing",
    "IOKit": "private", "CoreServices": "private",
}


def fmt_version(v: int) -> str:
    return f"{v >> 16}.{(v >> 8) & 0xff}.{v & 0xff}"


def lib_short_name(install_name: str) -> str:
    m = re.search(r"/([^/]+)\.framework/", install_name)
    if m:
        return m.group(1)
    return install_name.rsplit("/", 1)[-1]


def macho_slices(read: Callable[[int, int], bytes], size: int) -> List[dict]:
    """Return [{arch, cputype, cpusubtype, offset, size}] for thin or fat files."""
    head = read(0, 8)
    if len(head) < 8:
        return []
    magic_be = struct.unpack(">I", head[:4])[0]
    if magic_be in (0xCAFEBABE, 0xCAFEBABF):
        is64 = magic_be == 0xCAFEBABF
        nfat = struct.unpack(">I", head[4:8])[0]
        if nfat == 0 or nfat > 32:  # also rejects Java class files
            return []
        ent = 32 if is64 else 20
        table = read(8, nfat * ent)
        out = []
        for i in range(nfat):
            e = table[i * ent:(i + 1) * ent]
            if is64:
                cpu, sub, off, sz = struct.unpack(">iiQQ", e[:24])
            else:
                cpu, sub, off, sz = struct.unpack(">iiII", e[:16])
            out.append(_slice(cpu, sub, off, sz))
        return out
    magic_le = struct.unpack("<I", head[:4])[0]
    if magic_le in (0xFEEDFACF, 0xFEEDFACE):
        cpu, sub = struct.unpack("<ii", head[4:8] + read(8, 4))
        return [_slice(cpu, sub, 0, size)]
    return []


def _slice(cpu: int, sub: int, off: int, sz: int) -> dict:
    cpu &= 0xFFFFFFFF
    arch = CPU_TYPES.get(cpu, hex(cpu))
    if arch == "arm64" and (sub & 0xFF) == 2:
        arch = "arm64e"
    return {"arch": arch, "cputype": cpu, "cpusubtype": sub & 0xFFFFFFFF,
            "offset": off, "size": sz}


def parse_macho_slice(read: Callable[[int, int], bytes], base: int,
                      want_symbols: bool = True) -> dict:
    hdr = read(base, 32)
    magic, cpu, sub, ftype, ncmds, sizeofcmds, flags = struct.unpack("<IiiIIII", hdr[:28])
    if magic != 0xFEEDFACF:
        return {"error": "not a 64-bit Mach-O slice"}
    cmds = read(base + 32, sizeofcmds)
    info = {
        "filetype": FILETYPES.get(ftype, ftype),
        "platform": None, "minos": None, "sdk": None,
        "id": None, "dylibs": [], "rpaths": [],
        "encrypted": False, "code_signature": False, "chained_fixups": False,
    }
    symtab = dysym = None
    p = 0
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", cmds, p)
        body = cmds[p:p + cmdsize]
        if cmd == LC_BUILD_VERSION:
            plat, minos, sdk = struct.unpack_from("<III", body, 8)
            info.update(platform=PLATFORMS.get(plat, plat), minos=fmt_version(minos),
                        sdk=fmt_version(sdk))
        elif cmd in (LC_VERSION_MIN_MACOSX, LC_VERSION_MIN_IPHONEOS):
            ver, sdk = struct.unpack_from("<II", body, 8)
            info.update(platform="macOS" if cmd == LC_VERSION_MIN_MACOSX else "iOS",
                        minos=fmt_version(ver), sdk=fmt_version(sdk))
        elif cmd in DYLIB_CMDS or cmd == LC_ID_DYLIB:
            name_off = struct.unpack_from("<I", body, 8)[0]
            name = body[name_off:].split(b"\0", 1)[0].decode("utf-8", "replace")
            if cmd == LC_ID_DYLIB:
                info["id"] = name
            else:
                info["dylibs"].append({"path": name, "kind": DYLIB_CMDS[cmd]})
        elif cmd == LC_RPATH:
            off = struct.unpack_from("<I", body, 8)[0]
            info["rpaths"].append(body[off:].split(b"\0", 1)[0].decode("utf-8", "replace"))
        elif cmd == LC_ENCRYPTION_INFO_64:
            info["encrypted"] = struct.unpack_from("<I", body, 16)[0] != 0
        elif cmd == LC_CODE_SIGNATURE:
            info["code_signature"] = True
        elif cmd == LC_DYLD_CHAINED_FIXUPS:
            info["chained_fixups"] = True
        elif cmd == LC_SYMTAB:
            symtab = struct.unpack_from("<IIII", body, 8)  # symoff nsyms stroff strsize
        elif cmd == LC_DYSYMTAB:
            dysym = struct.unpack_from("<IIIIII", body, 8)  # ilocal nlocal iext next iundef nundef
        p += cmdsize

    if want_symbols and symtab:
        info.update(_symbols(read, base, symtab, dysym, info["dylibs"]))
    return info


def _symbols(read, base, symtab, dysym, dylibs) -> dict:
    symoff, nsyms, stroff, strsize = symtab
    if dysym:
        _, _, iext, next_, iundef, nundef = dysym
    else:
        iext, next_, iundef, nundef = 0, nsyms, 0, nsyms
    lo = min(iext, iundef)
    hi = max(iext + next_, iundef + nundef)
    raw = read(base + symoff + lo * 16, (hi - lo) * 16)
    strtab = read(base + stroff, strsize)

    def name_at(i):
        end = strtab.find(b"\0", i)
        return strtab[i:end if end >= 0 else None].decode("utf-8", "replace")

    exports, imports, weak = [], {}, []
    for idx in range(lo, hi):
        strx, ntype, nsect, ndesc, nvalue = struct.unpack_from("<IBBHQ", raw, (idx - lo) * 16)
        if ntype & 0xE0:  # stab
            continue
        if not ntype & 0x01:  # not external
            continue
        name = name_at(strx)
        if (ntype & 0x0E) == 0x0:  # N_UNDF
            ordinal = (ndesc >> 8) & 0xFF
            if 1 <= ordinal <= len(dylibs):
                lib = dylibs[ordinal - 1]["path"]
            elif ordinal == 0xFE:
                lib = "<dynamic lookup>"
            else:
                lib = "<flat/self>"
            imports.setdefault(lib, []).append(name)
            if ndesc & 0x40:  # N_WEAK_REF
                weak.append(name)
        elif (ntype & 0x0E) == 0x0E:  # N_SECT
            exports.append(name)
    for v in imports.values():
        v.sort()
    return {"exports_count": len(exports),
            "il2cpp_exports": sorted(n for n in exports if n.startswith("_il2cpp_")),
            "imports": imports, "weak_imports": sorted(weak)}


def inspect_macho(src: Source, path: str, want_symbols: bool = True) -> dict:
    read = src.reader(path)
    slices = macho_slices(read, src.size(path))
    out = {"path": path, "slices": []}
    for s in slices:
        entry = dict(s)
        if s["arch"] in ("arm64", "arm64e", "x86_64"):
            entry.update(parse_macho_slice(read, s["offset"],
                                           want_symbols and s["arch"] == "arm64"))
        out["slices"].append(entry)
    return out


# --------------------------------------------------------------------------
# Unity data files
# --------------------------------------------------------------------------

BUILD_TARGETS = {
    2: "StandaloneOSX", 4: "StandaloneOSXIntel", 5: "StandaloneWindows",
    9: "iOS", 13: "Android", 19: "StandaloneWindows64", 20: "WebGL",
    21: "WSAPlayer", 24: "StandaloneLinux64", 27: "StandaloneOSXIntel64",
    31: "PS4", 33: "XboxOne", 37: "tvOS", 38: "Switch", 44: "PS5",
}

VERSION_RE = re.compile(rb"(20[1-9][0-9]|[56])\.[0-9]{1,2}\.[0-9]{1,3}[abfpx][0-9]{1,3}")


def parse_serialized_header(head: bytes) -> Optional[dict]:
    """Unity SerializedFile header (globalgamemanagers, level0, *.assets)."""
    if len(head) < 48:
        return None
    _msize, _fsize, version, _doff = struct.unpack_from(">IIII", head, 0)
    if not 9 <= version <= 64:
        return None
    endian = head[16]
    pos = 20
    if version >= 22:
        pos += 4 + 8 + 8 + 8
    end = head.find(b"\0", pos)
    if end < 0:
        return None
    unity_version = head[pos:end].decode("ascii", "replace")
    if not re.match(r"^\d+\.\d+", unity_version):
        return None
    pos = end + 1
    target = None
    if version >= 8 and pos + 4 <= len(head):
        target = struct.unpack_from("<i" if endian == 0 else ">i", head, pos)[0]
    return {"format": "SerializedFile", "serialized_version": version,
            "unity_version": unity_version, "target_platform": target,
            "target_platform_name": BUILD_TARGETS.get(target, str(target))}


def parse_unityfs_header(head: bytes) -> Optional[dict]:
    """UnityFS bundle header (data.unity3d with LZ4 builds)."""
    for sig in (b"UnityFS\0", b"UnityRaw\0", b"UnityWeb\0"):
        if head.startswith(sig):
            p = len(sig) + 4
            parts = head[p:].split(b"\0", 2)
            if len(parts) >= 2:
                return {"format": sig.rstrip(b"\0").decode(),
                        "unity_version": parts[1].decode("ascii", "replace"),
                        "target_platform": None, "target_platform_name": None}
    return None


IL2CPP_METADATA_HINTS = {
    16: "Unity 5.3-5.4", 19: "Unity 5.5", 20: "Unity 5.6", 21: "Unity 2017.1",
    22: "Unity 2017.x", 23: "Unity 2017.x-2018.2", 24: "Unity 2018.3-2020.1",
    27: "Unity 2020.2-2021.1", 29: "Unity 2021.2-2022.3", 31: "Unity 2022.3 (late)/2023.x",
}


def parse_global_metadata(head: bytes) -> dict:
    if len(head) < 8:
        return {"magic_ok": False}
    magic, version = struct.unpack_from("<Ii", head, 0)
    ok = magic == 0xFAB11BAF
    return {"magic_ok": ok, "version": version if ok else None,
            "unity_range_hint": IL2CPP_METADATA_HINTS.get(version, "newer/unknown") if ok else None}


def scan_for_version(read, size, limit=96 * 1024 * 1024) -> Optional[str]:
    """Fallback: look for a Unity version string inside a binary."""
    chunk, overlap, off = 4 * 1024 * 1024, 32, 0
    counts: Dict[str, int] = {}
    while off < min(size, limit):
        data = read(off, chunk + overlap)
        for m in VERSION_RE.finditer(data):
            v = m.group(0).decode()
            counts[v] = counts.get(v, 0) + 1
        off += chunk
    return max(counts, key=counts.get) if counts else None


# --------------------------------------------------------------------------
# Locating files inside an arbitrary game folder layout
# --------------------------------------------------------------------------

DATA_PRIORITY = ["globalgamemanagers", "data.unity3d", "mainData", "level0",
                 "sharedassets0.assets", "resources.assets"]


def locate(src: Source) -> dict:
    found: dict = {"plugins": [], "data_candidates": []}
    by_base: Dict[str, List[str]] = {}
    for p in src.paths():
        if "__MACOSX/" in p:
            continue
        by_base.setdefault(p.rsplit("/", 1)[-1], []).append(p)

    def first(name):
        c = by_base.get(name)
        return sorted(c, key=len)[0] if c else None

    found["game_assembly"] = first("GameAssembly.dylib")
    found["unity_player"] = first("UnityPlayer.dylib")
    found["metadata"] = first("global-metadata.dat")
    found["assembly_csharp"] = first("Assembly-CSharp.dll")
    found["mono_runtime"] = next((p for p in src.paths() if "/MonoBleedingEdge/" in p or
                                  p.endswith("libmonobdwgc-2.0.dylib")), None)
    for name in DATA_PRIORITY:
        if first(name):
            found["data_candidates"].append(first(name))

    plists = [p for p in by_base.get("Info.plist", []) if p.endswith("Contents/Info.plist")
              and ".bundle/" not in p and "Frameworks/" not in p]
    loose = by_base.get("Info.plist", [])
    found["info_plist"] = sorted(plists, key=len)[0] if plists else (
        sorted(loose, key=len)[0] if loose else None)

    seen = set()
    for p in src.paths():
        low = "/" + p.lower()
        if "/plugins/" in low and (".bundle/contents/macos/" in low or low.endswith(".dylib")):
            if p not in seen:
                seen.add(p)
                found["plugins"].append(p)
    return found


PLUGIN_NOTES = [
    (r"steam_api|steamworks", "Steamworks. If the game refuses to start without Steam this is a hard blocker; "
                               "optional Steam features (achievements) can be stubbed."),
    (r"fmod", "FMOD native audio. Needs the iOS FMOD build of the same version."),
    (r"wwise|aksoundengine", "Wwise native audio. Needs the iOS Wwise build of the same version."),
    (r"rewired", "Rewired input native helper. Rewired falls back to Unity input on iOS."),
    (r"discord", "Discord RPC. Safe to stub."),
    (r"galaxy", "GOG Galaxy SDK. Safe to stub if optional."),
    (r"eos|epic", "Epic Online Services. Safe to stub if optional."),
]


def plugin_note(path: str) -> str:
    low = path.lower()
    for pat, note in PLUGIN_NOTES:
        if re.search(pat, low):
            return note
    return "Unknown native plugin. Needs an iOS arm64 build, a re-targeted copy, or a stub."


# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------


def arm64_slice(binfo: Optional[dict]) -> Optional[dict]:
    if not binfo:
        return None
    return next((s for s in binfo["slices"] if s["arch"] == "arm64"), None)


def build_report(src: Source, label: str) -> dict:
    loc = locate(src)
    report: dict = {
        "tool": "unity-inspect", "schema": SCHEMA, "input": label,
        "game": {}, "unity": {}, "backend": "unknown", "il2cpp": None,
        "binaries": {}, "plugins": [], "findings": [], "located": loc,
    }
    F = report["findings"]

    def add(level, fid, msg):
        F.append({"level": level, "id": fid, "message": msg})

    # Info.plist
    if loc["info_plist"]:
        try:
            raw = src.read(loc["info_plist"], 0, src.size(loc["info_plist"]))
            pl = plistlib.loads(raw)
            report["game"] = {
                "name": pl.get("CFBundleName") or pl.get("CFBundleExecutable"),
                "bundle_id": pl.get("CFBundleIdentifier"),
                "version": pl.get("CFBundleShortVersionString"),
                "executable": pl.get("CFBundleExecutable"),
                "min_macos": pl.get("LSMinimumSystemVersion"),
            }
            if pl.get("UnityBuildNumber"):
                report["unity"]["changeset"] = pl["UnityBuildNumber"]
        except Exception as e:  # noqa: BLE001
            add("info", "plist-unreadable", f"Could not parse {loc['info_plist']}: {e}")

    # Unity version from data files
    for cand in loc["data_candidates"]:
        head = src.read(cand, 0, 512)
        hdr = parse_unityfs_header(head) or parse_serialized_header(head)
        if hdr and hdr["unity_version"] and not hdr["unity_version"].startswith("0.0"):
            report["unity"].update(version=hdr["unity_version"], source=cand,
                                   target_platform=hdr["target_platform"],
                                   target_platform_name=hdr["target_platform_name"],
                                   container=hdr["format"],
                                   serialized_version=hdr.get("serialized_version"))
            break
    if not report["unity"].get("version"):
        for cand in (loc["unity_player"], loc["game_assembly"]):
            if cand:
                v = scan_for_version(src.reader(cand), src.size(cand))
                if v:
                    report["unity"].update(version=v, source=cand + " (string scan)")
                    break

    # Scripting backend
    if loc["game_assembly"] or loc["metadata"]:
        report["backend"] = "il2cpp"
    elif loc["assembly_csharp"] or loc["mono_runtime"]:
        report["backend"] = "mono"

    if loc["metadata"]:
        report["il2cpp"] = parse_global_metadata(src.read(loc["metadata"], 0, 8))

    # Binaries
    for key, name in (("game_assembly", "GameAssembly.dylib"), ("unity_player", "UnityPlayer.dylib")):
        if loc[key]:
            report["binaries"][name] = inspect_macho(src, loc[key], want_symbols=(key == "game_assembly"))

    for p in loc["plugins"]:
        b = inspect_macho(src, p, want_symbols=False)
        report["plugins"].append({
            "path": p,
            "archs": [s["arch"] for s in b["slices"]],
            "note": plugin_note(p),
        })

    _findings(report, add)
    return report


def _findings(report, add):
    u = report["unity"]
    if u.get("version"):
        add("ok", "unity-version", f"Unity {u['version']} (from {u['source']})"
            + (f", changeset {u['changeset']}" if u.get("changeset") else ""))
        if u.get("target_platform_name"):
            add("info", "data-target", f"Data was built for {u['target_platform_name']}. The iOS player will be "
                "loading data that it did not build; this is the main thing Phase 0 must prove works.")
        major = int(re.match(r"(\d+)", u["version"]).group(1))
        if major < 2019:
            add("warn", "old-unity", "Unity older than 2019.3 has no separate UnityPlayer.dylib and its "
                "iOS toolchain may not build with current Xcode on GitHub runners.")
    else:
        add("blocker", "unity-version", "Could not determine the Unity version. Add globalgamemanagers "
            "(or level0 / data.unity3d) from Contents/Resources/Data.")

    if report["backend"] == "mono":
        add("blocker", "backend-mono", "This is a Mono build, not IL2CPP. There is no GameAssembly.dylib to load; "
            "Mono needs a JIT and a different loader design. Not supported by this pipeline.")
    elif report["backend"] == "unknown":
        add("warn", "backend-unknown", "Could not tell IL2CPP from Mono. Include GameAssembly.dylib and "
            "global-metadata.dat.")

    md = report["il2cpp"]
    if md is not None:
        if md["magic_ok"]:
            add("ok", "metadata", f"global-metadata.dat version {md['version']} ({md['unity_range_hint']}).")
        else:
            add("warn", "metadata-obfuscated", "global-metadata.dat has a non-standard header (encrypted or "
                "obfuscated). The game's own GameAssembly decrypts it, so loading may still work, but tooling "
                "that reads metadata will not.")
    elif report["backend"] == "il2cpp":
        add("warn", "metadata-missing", "global-metadata.dat not found (expected under "
            "Contents/Resources/Data/il2cpp_data/Metadata/).")

    ga = report["binaries"].get("GameAssembly.dylib")
    if report["backend"] == "il2cpp" and not ga:
        add("blocker", "gameassembly-missing", "GameAssembly.dylib not found (expected in Contents/Frameworks/).")
    if ga:
        archs = [s["arch"] for s in ga["slices"]]
        s = arm64_slice(ga)
        if not archs:
            add("blocker", "gameassembly-format", "GameAssembly.dylib is not a Mach-O file.")
        elif not s:
            add("blocker", "gameassembly-arch", f"GameAssembly.dylib has no arm64 slice ({', '.join(archs)}). "
                "An x86_64-only game cannot run on the iPad's A14.")
        else:
            add("ok", "gameassembly-arch", f"GameAssembly.dylib slices: {', '.join(archs)}; arm64 slice "
                f"targets {s.get('platform')} {s.get('minos')} (SDK {s.get('sdk')}).")
            if s.get("encrypted"):
                add("blocker", "gameassembly-encrypted", "arm64 slice is FairPlay-encrypted.")
            n = len(s.get("il2cpp_exports", []))
            if n:
                add("ok", "il2cpp-api", f"{n} il2cpp_* API functions exported (the loader forwards to these).")
            else:
                add("warn", "il2cpp-api", "No il2cpp_* exports found in the symbol table.")
            for d in s.get("dylibs", []):
                short = lib_short_name(d["path"])
                kind = MAC_ONLY_LIBS.get(short)
                if kind == "missing":
                    level = "warn" if d["kind"] == "weak" else "blocker"
                    add(level, "dep-" + short, f"GameAssembly links {short} which does not exist on iPadOS "
                        f"({d['kind']} link). A shim library with that install name is required.")
                elif kind == "private":
                    add("info", "dep-" + short, f"GameAssembly links {short}: present on iPadOS but not in "
                        "the public SDK; run the CI symbol check to confirm each symbol.")
    up = report["binaries"].get("UnityPlayer.dylib")
    if up:
        archs = [s["arch"] for s in up["slices"]]
        add("info", "unityplayer", f"UnityPlayer.dylib slices: {', '.join(archs)}. It is NOT used on the iPad "
            "(the iOS engine replaces it); only relevant for the zorrobyte-style fallback.")
    for p in report["plugins"]:
        level = "warn" if "arm64" in p["archs"] else "blocker"
        add(level, "plugin", f"Native plugin {p['path']} ({', '.join(p['archs']) or 'not Mach-O'}): {p['note']}")


ICON = {"ok": "[ OK ]", "info": "[INFO]", "warn": "[WARN]", "blocker": "[STOP]"}


def print_report(r: dict, out=sys.stdout):
    g = r.get("game") or {}
    print(f"== unity-inspect: {g.get('name') or r['input']} ==", file=out)
    if g:
        print(f"   bundle id {g.get('bundle_id')}  version {g.get('version')}  min macOS {g.get('min_macos')}", file=out)
    print(f"   backend   {r['backend']}", file=out)
    print(f"   unity     {r['unity'].get('version', '?')}", file=out)
    print("", file=out)
    for f in r["findings"]:
        print(f"{ICON[f['level']]} {f['message']}", file=out)
    s = arm64_slice(r["binaries"].get("GameAssembly.dylib"))
    if s and s.get("dylibs"):
        print("\nGameAssembly.dylib (arm64) links:", file=out)
        for d in s["dylibs"]:
            n = len(s.get("imports", {}).get(d["path"], []))
            print(f"   {d['path']}  [{d['kind']}, {n} symbols]", file=out)
    blockers = [f for f in r["findings"] if f["level"] == "blocker"]
    print("\nVerdict:", "BLOCKED - see [STOP] lines" if blockers else
          "candidate for the iPad loader (next: Phase 0 + CI symbol check)", file=out)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("path", help=".app folder, game folder, .zip, or folder of key files")
    ap.add_argument("--json", metavar="FILE", help="write the full report as JSON")
    a = ap.parse_args(argv)
    src = open_source(a.path)
    rep = build_report(src, os.path.basename(os.path.normpath(a.path)))
    print_report(rep)
    if a.json:
        with open(a.json, "w") as fh:
            json.dump(rep, fh, indent=1, sort_keys=False)
        print(f"\nWrote {a.json}")
    return 2 if any(f["level"] == "blocker" for f in rep["findings"]) else 0


if __name__ == "__main__":
    sys.exit(main())
