#!/usr/bin/env python3
"""Check whether every symbol GameAssembly.dylib imports exists in the iPadOS SDK.

Input: one or more report JSON files written by tools/unity_inspect.py (or the
web inspector). Runs on a macOS GitHub Actions runner with Xcode.

For each library GameAssembly links, a stub C file referencing every imported
symbol is linked against the iPhoneOS SDK. Whatever the linker reports as
undefined is a symbol dyld would also fail to bind on the iPad (unless it lives
in a private framework, which the public SDK does not describe).

Usage: python3 ci/ios_symbol_check.py reports/*.json [--min-ios 16.0] [--out DIR]
"""
import argparse
import json
import os
import re
import subprocess
import sys

UNDEF_RE = re.compile(r'^\s+"(.+?)", referenced from:')
SKIP_LIBS = ("<dynamic lookup>", "<flat/self>")


def sh(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def sdk_path():
    return sh("xcrun", "--sdk", "iphoneos", "--show-sdk-path").stdout.strip()


def link_flags(install_name, sdk):
    """Map a macOS install name to iOS linker flags. Returns (flags, status)."""
    if install_name.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
        return None, "bundled with the game (must be shipped/shimmed separately)"
    m = re.match(r"/System/Library/(Private)?Frameworks/([^/]+)\.framework/", install_name)
    if m:
        if m.group(1):
            return None, "private framework"
        fw = m.group(2)
        if not os.path.isdir(os.path.join(sdk, "System/Library/Frameworks", fw + ".framework")):
            return None, f"framework {fw} does not exist in the iPadOS SDK"
        return ["-framework", fw], "ok"
    m = re.match(r"/usr/lib/lib(.+?)(\.[0-9A-Z]+)*\.dylib$", install_name)
    if m:
        name = m.group(1)
        if name == "System":
            return [], "ok"
        return ["-l" + name], "ok"
    return None, "unrecognised install name"


def c_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def check_lib(lib, symbols, flags, sdk, min_ios, workdir, idx):
    src = os.path.join(workdir, f"refs{idx}.c")
    with open(src, "w") as fh:
        for i, s in enumerate(symbols):
            fh.write(f'extern char s{i} __asm__("{c_escape(s)}");\n')
        fh.write("void *refs[] = {" + ",".join(f"&s{i}" for i in range(len(symbols))) + "};\n")
    out = os.path.join(workdir, f"refs{idx}.dylib")
    r = sh("xcrun", "--sdk", "iphoneos", "clang", "-target", f"arm64-apple-ios{min_ios}",
           "-isysroot", sdk, "-dynamiclib", src, "-o", out, *flags)
    missing = [m.group(1) for line in r.stderr.splitlines() if (m := UNDEF_RE.match(line))]
    if r.returncode != 0 and not missing:
        return None, r.stderr.strip()[-2000:]
    return missing, None


def ga_slice(report):
    ga = (report.get("binaries") or {}).get("GameAssembly.dylib")
    if not ga:
        return None
    return next((s for s in ga["slices"] if s.get("arch") == "arm64"), None)


def run(report_path, sdk, min_ios, workdir):
    with open(report_path) as fh:
        rep = json.load(fh)
    name = (rep.get("game") or {}).get("name") or os.path.basename(report_path)
    lines = [f"## {name}", "",
             f"Unity `{(rep.get('unity') or {}).get('version', '?')}`, report `{report_path}`", ""]
    s = ga_slice(rep)
    if not s:
        lines.append("No arm64 GameAssembly.dylib in this report - nothing to check.")
        return lines, False
    weak = set(s.get("weak_imports") or [])
    hard_fail = False
    lines += ["| Library | Symbols | Result |", "|---|---|---|"]
    details = []
    for idx, (lib, syms) in enumerate(sorted((s.get("imports") or {}).items())):
        if lib in SKIP_LIBS:
            continue
        flags, status = link_flags(lib, sdk)
        if flags is None:
            strong = [x for x in syms if x not in weak]
            bad = "private" not in status and "bundled" not in status and strong
            hard_fail |= bool(bad)
            lines.append(f"| `{lib}` | {len(syms)} | {'**FAIL**' if bad else 'note'}: {status} |")
            if bad:
                details.append((lib, strong))
            continue
        missing, err = check_lib(lib, syms, flags, sdk, min_ios, workdir, idx)
        if err:
            lines.append(f"| `{lib}` | {len(syms)} | link error (see log) |")
            print(f"--- {lib}\n{err}", file=sys.stderr)
            continue
        strong = [x for x in missing if x not in weak]
        if strong:
            hard_fail = True
            details.append((lib, strong))
        lines.append(f"| `{lib}` | {len(syms)} | " +
                     (f"**{len(strong)} missing**" if strong else "all present") +
                     (f" ({len(missing) - len(strong)} weak missing, ok)" if len(missing) > len(strong) else "") + " |")
    for lib, syms in details:
        lines += ["", f"<details><summary>Missing from <code>{lib}</code> ({len(syms)})</summary>", "", "```"]
        lines += syms[:400] + (["..."] if len(syms) > 400 else [])
        lines += ["```", "</details>"]
    lines += ["", "**Verdict:** " + ("symbols missing on iPadOS - these need shims before dyld will load "
                                     "GameAssembly.dylib." if hard_fail else
                                     "every imported symbol resolves against the iPadOS SDK.")]
    return lines, hard_fail


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("reports", nargs="+")
    ap.add_argument("--min-ios", default="16.0")
    ap.add_argument("--out", default="symbol-check")
    a = ap.parse_args()
    os.makedirs(a.out, exist_ok=True)
    sdk = sdk_path()
    if not sdk:
        sys.exit("iPhoneOS SDK not found (needs macOS + Xcode)")
    all_lines, failed = [f"# iPadOS symbol check (SDK `{os.path.basename(sdk)}`)", ""], False
    for rp in a.reports:
        lines, f = run(rp, sdk, a.min_ios, a.out)
        all_lines += lines + [""]
        failed |= f
    text = "\n".join(all_lines)
    print(text)
    with open(os.path.join(a.out, "summary.md"), "w") as fh:
        fh.write(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as fh:
            fh.write(text + "\n")
    return 0  # informational: missing symbols are a finding, not a CI failure


if __name__ == "__main__":
    sys.exit(main())
