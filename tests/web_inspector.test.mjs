// Runs the core <script> from web/inspector.html under Node and checks that it
// produces the same findings as tools/unity_inspect.py for the synthetic build
// in tests/test_unity_inspect.py (as a folder and as a zip).
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, statSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import vm from "node:vm";
import assert from "node:assert/strict";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const html = readFileSync(join(root, "web/inspector.html"), "utf8");
const core = html.match(/<script id="core">([\s\S]*?)<\/script>/)[1];
const ctx = { module: { exports: null }, TextDecoder, Response, DecompressionStream, Blob, console };
vm.runInNewContext(core, ctx);
const Core = ctx.module.exports;

const tmp = mkdtempSync(join(tmpdir(), "inspector-"));
const py = (code) => execFileSync("python3", ["-c", code], { cwd: root, encoding: "utf8" });

function walk(dir) {
  return readdirSync(dir).flatMap((n) => {
    const p = join(dir, n);
    return statSync(p).isDirectory() ? walk(p) : [p];
  });
}

const key = (r) => JSON.parse(JSON.stringify({
  backend: r.backend,
  unity: r.unity.version,
  changeset: r.unity.changeset,
  findings: r.findings.map((f) => `${f.level}:${f.id}:${f.message}`).sort(),
  exports: Core.arm64Slice(r.binaries["GameAssembly.dylib"])?.il2cpp_exports,
  imports: Core.arm64Slice(r.binaries["GameAssembly.dylib"])?.imports,
}));

try {
  for (const mono of [false, true]) {
    const dir = join(tmp, mono ? "mono" : "il2cpp");
    py(`import sys; sys.path.insert(0,'tests'); import test_unity_inspect as t, os; os.makedirs('${dir}'); t.make_app('${dir}', mono=${mono ? "True" : "False"})`);
    const pyRep = JSON.parse(py(
      `import sys, json; sys.path.insert(0,'tools'); import unity_inspect as u; print(json.dumps(u.build_report(u.open_source('${dir}'), 't')))`));

    const files = walk(dir).map((p) => Core.blobEntry(relative(dir, p), new Blob([readFileSync(p)])));
    const jsDir = await Core.buildReport(files, "t");
    assert.deepEqual(key(jsDir), key(pyRep), `folder mismatch (mono=${mono})`);

    const zip = join(tmp, (mono ? "mono" : "il2cpp") + ".zip");
    py(`import zipfile, os
d='${dir}'
with zipfile.ZipFile('${zip}', 'w', zipfile.ZIP_DEFLATED) as z:
    for dp, _, fs in os.walk(d):
        for f in fs:
            p = os.path.join(dp, f); z.write(p, os.path.relpath(p, d))`);
    const jsZip = await Core.buildReport(await Core.zipEntries(new Blob([readFileSync(zip)])), "t");
    assert.deepEqual(key(jsZip), key(pyRep), `zip mismatch (mono=${mono})`);
    console.log(`ok - ${mono ? "mono" : "il2cpp"} build: web and python agree (${pyRep.findings.length} findings)`);
  }
} finally {
  rmSync(tmp, { recursive: true, force: true });
}
