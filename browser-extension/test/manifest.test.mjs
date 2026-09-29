import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const manifest = JSON.parse(readFileSync(join(root, "manifest.json"), "utf8"));

test("manifest is MV3 1.1.0 and asks for no new permissions", () => {
  assert.equal(manifest.manifest_version, 3);
  assert.equal(manifest.version, "1.1.0");
  assert.deepEqual([...manifest.permissions].sort(), ["activeTab", "contextMenus"]);
  assert.equal(manifest.host_permissions, undefined);
  assert.equal(manifest.optional_permissions, undefined);
  assert.equal(manifest.content_scripts, undefined);
});

test("background is an ES-module service worker and its imports exist", () => {
  assert.equal(manifest.background.type, "module");
  const worker = join(root, manifest.background.service_worker);
  assert.ok(existsSync(worker));
  const source = readFileSync(worker, "utf8");
  for (const [, spec] of source.matchAll(/from\s+"(\.[^"]+)"/g)) {
    assert.ok(existsSync(join(root, spec)), `missing import ${spec}`);
  }
});

test("icons are real PNGs at the declared sizes and wired into the toolbar action", () => {
  const sizes = ["16", "32", "48", "128"];
  assert.deepEqual(Object.keys(manifest.icons), sizes);
  assert.deepEqual(manifest.action.default_icon, manifest.icons);
  for (const size of sizes) {
    const file = join(root, manifest.icons[size]);
    assert.ok(existsSync(file), file);
    const png = readFileSync(file);
    assert.equal(png.subarray(1, 4).toString(), "PNG");
    assert.equal(png.readUInt32BE(16), Number(size), `${file} width`);
    assert.equal(png.readUInt32BE(20), Number(size), `${file} height`);
  }
});

test("keyboard shortcut is the toolbar action", () => {
  const command = manifest.commands._execute_action;
  assert.ok(command);
  assert.equal(command.suggested_key.default, "Alt+Shift+P");
});
