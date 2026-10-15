"""Tests for tools/unity_inspect.py using a synthetic Unity macOS IL2CPP build."""
import os
import plistlib
import shutil
import struct
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import unity_inspect as ui  # noqa: E402


def _cstr_cmd(cmd, s, extra=b""):
    """dylib-style load command with a trailing string at offset 24."""
    name = s.encode() + b"\0"
    size = (24 + len(name) + 7) & ~7
    body = struct.pack("<II", cmd, size) + struct.pack("<I", 24) + (extra or b"\0" * 12)
    return (body + name).ljust(size, b"\0")


def make_dylib(platform=1, link_appkit=True, exports=("_il2cpp_init", "_il2cpp_domain_get"),
               imports=("_malloc", "_NSApp")):
    libs = ["/usr/lib/libSystem.B.dylib"]
    if link_appkit:
        libs.append("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit")
    cmds = [_cstr_cmd(ui.LC_ID_DYLIB, "@rpath/GameAssembly.dylib"),
            struct.pack("<IIIIII", ui.LC_BUILD_VERSION, 24, platform, 11 << 16, 14 << 16, 0)]
    cmds += [_cstr_cmd(ui.LC_LOAD_DYLIB, l) for l in libs]

    strtab = b"\0"
    syms = []
    def addsym(name, ntype, desc):
        nonlocal strtab
        syms.append(struct.pack("<IBBHQ", len(strtab), ntype, 1 if ntype == 0x0F else 0, desc, 0))
        strtab += name.encode() + b"\0"
    for e in exports:
        addsym(e, 0x0F, 0)
    for i, name in enumerate(imports):
        ordinal = 1 if i == 0 or not link_appkit else 2
        addsym(name, 0x01, ordinal << 8)

    sizeofcmds = sum(len(c) for c in cmds) + 24 + 80
    symoff = 32 + sizeofcmds
    stroff = symoff + 16 * len(syms)
    cmds.append(struct.pack("<IIIIII", ui.LC_SYMTAB, 24, symoff, len(syms), stroff, len(strtab)))
    dys = [0, 0, 0, len(exports), len(exports), len(imports)] + [0] * 12
    cmds.append(struct.pack("<II", ui.LC_DYSYMTAB, 80) + struct.pack("<18I", *dys))
    hdr = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 6, len(cmds), sizeofcmds, 0, 0)
    return hdr + b"".join(cmds) + b"".join(syms) + strtab


def make_fat(*slices):
    """slices: list of (cputype, bytes)."""
    out = struct.pack(">II", 0xCAFEBABE, len(slices))
    offset = 0x4000
    table, blobs = b"", b""
    for cpu, data in slices:
        table += struct.pack(">iiIII", cpu, 0, offset, len(data), 14)
        blobs = blobs.ljust(offset - 0x4000, b"\0") + data
        offset = 0x4000 + ((len(blobs) + 0x3FFF) & ~0x3FFF)
    return (out + table).ljust(0x4000, b"\0") + blobs


def make_serialized(version_str="2021.3.16f1", fmt=22, platform=2):
    head = struct.pack(">IIII", 0, 0, fmt, 0) + b"\0\0\0\0"
    if fmt >= 22:
        head += struct.pack(">IQQQ", 1000, 5000, 4096, 0)
    return head + version_str.encode() + b"\0" + struct.pack("<i", platform) + b"\x01" + b"\0" * 400


def make_app(root, mono=False):
    c = os.path.join(root, "Sinisistar 2.app", "Contents")
    for d in ("Frameworks", "Resources/Data/il2cpp_data/Metadata", "MacOS",
              "PlugIns/steam_api.bundle/Contents/MacOS"):
        os.makedirs(os.path.join(c, d), exist_ok=True)
    with open(os.path.join(c, "Info.plist"), "wb") as fh:
        plistlib.dump({"CFBundleName": "Sinisistar 2", "CFBundleIdentifier": "com.example.sini2",
                       "CFBundleShortVersionString": "1.0", "CFBundleExecutable": "Sinisistar 2",
                       "UnityBuildNumber": "abcdef123456"}, fh)
    with open(os.path.join(c, "Resources/Data/globalgamemanagers"), "wb") as fh:
        fh.write(make_serialized())
    if mono:
        os.makedirs(os.path.join(c, "Resources/Data/Managed"), exist_ok=True)
        with open(os.path.join(c, "Resources/Data/Managed/Assembly-CSharp.dll"), "wb") as fh:
            fh.write(b"MZ")
        shutil.rmtree(os.path.join(c, "Resources/Data/il2cpp_data"))
        return root
    with open(os.path.join(c, "Resources/Data/il2cpp_data/Metadata/global-metadata.dat"), "wb") as fh:
        fh.write(struct.pack("<Ii", 0xFAB11BAF, 29) + b"\0" * 64)
    with open(os.path.join(c, "Frameworks/GameAssembly.dylib"), "wb") as fh:
        fh.write(make_fat((0x01000007, make_dylib()), (0x0100000C, make_dylib())))
    with open(os.path.join(c, "PlugIns/steam_api.bundle/Contents/MacOS/steam_api"), "wb") as fh:
        fh.write(make_dylib(link_appkit=False, exports=("_SteamAPI_Init",), imports=("_malloc",)))
    return root


class HeaderTests(unittest.TestCase):
    def test_serialized_v22(self):
        h = ui.parse_serialized_header(make_serialized("2022.3.10f1", 22, 2))
        self.assertEqual(h["unity_version"], "2022.3.10f1")
        self.assertEqual(h["target_platform_name"], "StandaloneOSX")

    def test_serialized_v17(self):
        h = ui.parse_serialized_header(make_serialized("2018.4.36f1", 17, 9))
        self.assertEqual(h["unity_version"], "2018.4.36f1")
        self.assertEqual(h["target_platform_name"], "iOS")

    def test_unityfs(self):
        h = ui.parse_unityfs_header(b"UnityFS\0" + struct.pack(">I", 7) + b"5.x.x\x002020.3.1f1\0rest")
        self.assertEqual(h["unity_version"], "2020.3.1f1")

    def test_metadata(self):
        self.assertEqual(ui.parse_global_metadata(struct.pack("<Ii", 0xFAB11BAF, 27))["version"], 27)
        self.assertFalse(ui.parse_global_metadata(b"\x01" * 8)["magic_ok"])

    def test_macho_thin(self):
        data = make_dylib(platform=2)
        read = lambda off, n: data[off:off + n]
        sl = ui.macho_slices(read, len(data))
        self.assertEqual([s["arch"] for s in sl], ["arm64"])
        info = ui.parse_macho_slice(read, 0)
        self.assertEqual(info["platform"], "iOS")
        self.assertEqual(info["minos"], "11.0.0")
        self.assertEqual(info["il2cpp_exports"], ["_il2cpp_domain_get", "_il2cpp_init"])
        self.assertIn("_NSApp", info["imports"]["/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"])


class AppTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def _ids(self, rep):
        return {(f["level"], f["id"]) for f in rep["findings"]}

    def test_il2cpp_app_dir(self):
        make_app(self.tmp)
        rep = ui.build_report(ui.open_source(self.tmp), "t")
        self.assertEqual(rep["backend"], "il2cpp")
        self.assertEqual(rep["unity"]["version"], "2021.3.16f1")
        self.assertEqual(rep["unity"]["changeset"], "abcdef123456")
        self.assertEqual(rep["game"]["name"], "Sinisistar 2")
        ids = self._ids(rep)
        self.assertIn(("ok", "gameassembly-arch"), ids)
        self.assertIn(("ok", "il2cpp-api"), ids)
        self.assertIn(("blocker", "dep-AppKit"), ids)
        self.assertEqual(len(rep["plugins"]), 1)
        self.assertIn("Steamworks", rep["plugins"][0]["note"])

    def test_zip_matches_dir(self):
        make_app(self.tmp)
        zpath = os.path.join(self.tmp, "game.zip")
        with zipfile.ZipFile(zpath, "w", zipfile.ZIP_DEFLATED) as z:
            for dp, _, fs in os.walk(self.tmp):
                for f in fs:
                    full = os.path.join(dp, f)
                    if full != zpath:
                        z.write(full, os.path.relpath(full, self.tmp))
        a = ui.build_report(ui.open_source(self.tmp), "t")
        b = ui.build_report(ui.open_source(zpath), "t")
        self.assertEqual(a["findings"], b["findings"])

    def test_mono(self):
        make_app(self.tmp, mono=True)
        rep = ui.build_report(ui.open_source(self.tmp), "t")
        self.assertEqual(rep["backend"], "mono")
        self.assertIn(("blocker", "backend-mono"), self._ids(rep))

    def test_cli_json(self):
        make_app(self.tmp)
        out = os.path.join(self.tmp, "r.json")
        with open(os.devnull, "w") as dn:
            old, sys.stdout = sys.stdout, dn
            try:
                code = ui.main([self.tmp, "--json", out])
            finally:
                sys.stdout = old
        self.assertEqual(code, 2)  # AppKit link is a blocker in the synthetic app
        self.assertTrue(os.path.getsize(out) > 100)


if __name__ == "__main__":
    unittest.main()
