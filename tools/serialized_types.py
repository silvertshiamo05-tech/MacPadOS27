#!/usr/bin/env python3
"""serialized_types - list the types inside a Unity SerializedFile and compare
two builds of the same data (e.g. a macOS build vs an iOS build).

Player builds carry no type trees, only a 16-byte layout hash per class. If the
hash of a class differs between two platforms, the engine of one platform
would read that class's objects with the wrong layout. That is the
data-compatibility question for loading macOS data in the iOS player.

Usage:
  python3 tools/serialized_types.py FILE
  python3 tools/serialized_types.py --compare MAC_DATA_DIR IOS_DATA_DIR
  python3 tools/serialized_types.py --set-platform 9 FILE...   (9 = iOS, 2 = macOS)
"""
import os
import struct
import sys

# Common Unity class IDs (subset, for readable output).
CLASS_NAMES = {
    1: "GameObject", 4: "Transform", 6: "LevelGameManager", 8: "Behaviour", 11: "AudioManager",
    12: "ParticleAnimator", 13: "InputManager", 19: "Physics2DSettings", 20: "Camera", 21: "Material",
    23: "MeshRenderer", 28: "Texture2D", 29: "OcclusionCullingSettings", 30: "GraphicsSettings",
    33: "MeshFilter", 41: "OcclusionPortal", 43: "Mesh", 47: "QualitySettings", 48: "Shader",
    49: "TextAsset", 54: "Rigidbody", 55: "PhysicsManager", 56: "Collider", 64: "MeshCollider",
    65: "BoxCollider", 74: "AnimationClip", 78: "TagManager", 81: "AudioListener", 83: "AudioClip",
    84: "RenderTexture", 89: "Cubemap", 90: "Avatar", 91: "AnimatorController", 92: "GUILayer",
    94: "ScriptMapper", 104: "RenderSettings", 108: "Light", 114: "MonoBehaviour", 115: "MonoScript",
    116: "MonoManager", 117: "Texture3D", 119: "Projector", 120: "LineRenderer", 121: "Flare",
    124: "Halo", 126: "NavMeshProjectSettings", 128: "Font", 129: "PlayerSettings", 130: "NamedObject",
    134: "PhysicMaterial", 135: "SphereCollider", 136: "CapsuleCollider", 137: "SkinnedMeshRenderer",
    141: "BuildSettings", 142: "AssetBundle", 147: "ResourceManager", 150: "PreloadData",
    157: "LightmapSettings", 159: "EditorSettings", 171: "SampleClip", 180: "AudioReverbZone",
    184: "WindZone", 196: "NavMeshSettings", 198: "ParticleSystem", 199: "ParticleSystemRenderer",
    205: "LODGroup", 212: "SpriteRenderer", 213: "Sprite", 218: "Terrain", 220: "LightProbeGroup",
    222: "CanvasRenderer", 223: "Canvas", 224: "RectTransform", 258: "LightProbes",
    272: "AudioMixerController", 290: "AssetBundleManifest", 300: "RuntimeInitializeOnLoadManager",
    310: "UnityConnectSettings", 319: "AvatarMask", 328: "VideoPlayer", 329: "VideoClip",
    331: "SpriteMask", 363: "OcclusionCullingData", 687078895: "SpriteAtlas", 1050: "?",
}


class Reader:
    def __init__(self, data, pos=0, little=True):
        self.d, self.p, self.e = data, pos, "<" if little else ">"

    def u8(self):
        v = self.d[self.p]; self.p += 1; return v

    def i16(self):
        v = struct.unpack_from(self.e + "h", self.d, self.p)[0]; self.p += 2; return v

    def i32(self):
        v = struct.unpack_from(self.e + "i", self.d, self.p)[0]; self.p += 4; return v

    def raw(self, n):
        v = self.d[self.p:self.p + n]; self.p += n; return v

    def cstr(self):
        e = self.d.index(b"\0", self.p); v = self.d[self.p:e].decode("latin1"); self.p = e + 1; return v


def read_types(path):
    with open(path, "rb") as fh:
        data = fh.read(4 * 1024 * 1024)
    _, _, version, _ = struct.unpack_from(">IIII", data, 0)
    endian = data[16]
    pos = 20 + (28 if version >= 22 else 0)
    r = Reader(data, pos, little=(endian == 0))
    unity = r.cstr()
    platform = r.i32()
    typetree = bool(r.u8()) if version >= 13 else True
    count = r.i32()
    types = []
    for _ in range(count):
        cid = r.i32()
        stripped = bool(r.u8()) if version >= 16 else False
        script_index = r.i16() if version >= 17 else -1
        script_hash = b""
        if version >= 13:
            if (version < 16 and cid < 0) or (version >= 16 and cid == 114):
                script_hash = r.raw(16)
            type_hash = r.raw(16)
        if typetree:
            raise SystemExit(f"{path}: has type trees; this tool only handles stripped player data")
        if version >= 21:
            pass  # type dependencies only exist for ref types / with typetree
        types.append({"class_id": cid, "name": CLASS_NAMES.get(cid, f"class {cid}"),
                      "stripped": stripped, "script_index": script_index,
                      "script_hash": script_hash.hex(), "type_hash": type_hash.hex()})
    return {"version": version, "unity": unity, "platform": platform, "types": types}


def platform_offset(data):
    """Byte offset and byte order of the BuildTarget field in a SerializedFile."""
    _, _, version, _ = struct.unpack_from(">IIII", data, 0)
    if not 9 <= version <= 64:
        raise ValueError("not a SerializedFile")
    pos = 20 + (28 if version >= 22 else 0)
    end = data.index(b"\0", pos)
    return end + 1, "<" if data[16] == 0 else ">"


def set_platform(path, platform):
    with open(path, "r+b") as fh:
        head = fh.read(256)
        off, e = platform_offset(head)
        old = struct.unpack_from(e + "i", head, off)[0]
        fh.seek(off)
        fh.write(struct.pack(e + "i", platform))
    return old


def compare(mac_dir, ios_dir):
    names = sorted(set(os.listdir(mac_dir)) & set(os.listdir(ios_dir)))
    files = [n for n in names if n in ("globalgamemanagers", "level0") or n.endswith(".assets")]
    for sub in ("Resources/unity_builtin_extra",):
        if os.path.exists(os.path.join(mac_dir, sub)) and os.path.exists(os.path.join(ios_dir, sub)):
            files.append(sub)
    any_diff = False
    for n in files:
        m, i = read_types(os.path.join(mac_dir, n)), read_types(os.path.join(ios_dir, n))
        mt = {(t["class_id"], t["script_hash"]): t for t in m["types"]}
        it = {(t["class_id"], t["script_hash"]): t for t in i["types"]}
        diffs = []
        for k in sorted(set(mt) | set(it), key=lambda k: (k[0], k[1])):
            a, b = mt.get(k), it.get(k)
            name = (a or b)["name"]
            if a and b and a["type_hash"] != b["type_hash"]:
                diffs.append(f"  DIFFERENT LAYOUT  {k[0]:>5} {name}")
            elif not a or not b:
                diffs.append(f"  only in {'mac' if a else 'iOS'}       {k[0]:>5} {name}")
        print(f"{n}: mac platform {m['platform']}, iOS platform {i['platform']}, {len(mt)}/{len(it)} types, "
              f"{len(diffs)} differences")
        print("\n".join(diffs))
        any_diff |= bool(diffs)
    return 1 if any_diff else 0


def main(argv):
    if len(argv) == 3 and argv[0] == "--compare":
        return compare(argv[1], argv[2])
    if len(argv) >= 3 and argv[0] == "--set-platform":
        for f in argv[2:]:
            print(f"{f}: platform {set_platform(f, int(argv[1]))} -> {argv[1]}")
        return 0
    if len(argv) == 1:
        info = read_types(argv[0])
        print(f"format {info['version']}, Unity {info['unity']}, platform {info['platform']}")
        for t in info["types"]:
            print(f"  {t['class_id']:>10} {t['name']:<28} {t['type_hash']}")
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
