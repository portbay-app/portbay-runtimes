#!/usr/bin/env node
// usage: generate-manifest.mjs <dist> <base-url>
//          [--live <manifest.json>] [--selected <id,id,...>] [--require <lang>@<version>]...
//
// A release REPLACES the manifest every installed app reads, so anything this
// run leaves out stops being installable. With --live, every entry of the
// current live manifest is carried over unless this run rebuilt the same
// (lang, version, arch); carried entries keep their URLs into the release that
// published them. --selected fails the run when a runtime it names produced no
// archive. --require fails it when <lang>@<version> is absent, or missing an
// arch the live manifest has it for. Nothing is written unless every check passes.
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const positional = [];
const flags = { live: null, selected: null, require: [] };
for (let i = 2; i < process.argv.length; i++) {
  const arg = process.argv[i];
  if (arg === "--live") flags.live = process.argv[++i];
  else if (arg === "--selected") flags.selected = process.argv[++i];
  else if (arg === "--require") flags.require.push(process.argv[++i]);
  else positional.push(arg);
}
const dist = positional[0] ?? "dist";
const baseUrl = positional[1];
if (!baseUrl) {
  console.error(
    "usage: generate-manifest.mjs <dist> <base-url> [--live <manifest.json>] [--selected <ids>] [--require <lang>@<version>]",
  );
  process.exit(2);
}

function fail(message) {
  console.error(`generate-manifest: ${message}`);
  process.exit(1);
}

const entries = [];
for (const name of readdirSync(dist)) {
  // Archive prefix → the manifest `lang` the app filters on:
  //   php-fpm-*  → "php"  (the PHP build ships php + php-fpm)
  //   node-*     → "node"
  //   ollama-*   → "ollama" (AI page managed install)
  //   <engine>-* → "<engine>" for database engines, matching DatabaseEngine::id()
  //                ("mysql"/"mariadb"/"postgres"/"redis"/"mongo"/"memcached")
  //   nginx-*    → "nginx"  (web server, `managed_web_server_binary`)
  //   httpd-*    → "apache" (web server; the app's WebServer id, not the binary name)
  const match =
    /^(php-fpm|node|ollama|mysql|mariadb|postgres|redis|mongo|memcached|nginx|httpd)-(.+)-(aarch64|x86_64)\.tar\.zst$/.exec(
      name,
    );
  if (!match) continue;
  const [, prefix, version, arch] = match;
  const LANG = { "php-fpm": "php", httpd: "apache" };
  const lang = LANG[prefix] ?? prefix;
  const archive = join(dist, name);
  entries.push({
    lang,
    version,
    arch,
    url: `${baseUrl}/${name}`,
    sha256: readFileSync(`${archive}.sha256`, "utf8").trim(),
    size: statSync(archive).size,
    compression: "zstd",
  });
}

if (flags.selected !== null) {
  // Workflow runtime id → manifest lang; only httpd differs.
  const RUNTIME_LANG = { httpd: "apache" };
  for (const id of flags.selected.split(",").filter(Boolean)) {
    const lang = RUNTIME_LANG[id] ?? id;
    if (!entries.some((e) => e.lang === lang)) {
      fail(`runtime '${id}' was selected but no ${lang} archive is in ${dist}`);
    }
  }
}

const key = (e) => `${e.lang}\0${e.version}\0${e.arch}`;
let live = [];
if (flags.live !== null) {
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(flags.live, "utf8"));
  } catch (err) {
    fail(`cannot read live manifest ${flags.live}: ${err.message}`);
  }
  if (parsed.schemaVersion !== 1 || !Array.isArray(parsed.entries)) {
    fail(`live manifest ${flags.live} is not a schemaVersion 1 manifest with an entries array`);
  }
  live = parsed.entries;
  const built = new Set(entries.map(key));
  for (const e of live) {
    const label = `${e.lang} ${e.version} ${e.arch}`;
    if (built.has(key(e))) {
      console.log(`replaced  ${label} (rebuilt this run)`);
    } else {
      console.log(`carried   ${label} -> ${e.url}`);
      entries.push(e);
    }
  }
}

for (const spec of flags.require) {
  const at = spec.lastIndexOf("@");
  if (at <= 0) fail(`--require wants <lang>@<version>, got '${spec}'`);
  const lang = spec.slice(0, at);
  const version = spec.slice(at + 1);
  const archesIn = (list) =>
    new Set(list.filter((e) => e.lang === lang && e.version === version).map((e) => e.arch));
  const have = archesIn(entries);
  if (have.size === 0) {
    fail(`refusing to publish: the manifest has no ${lang} ${version} entry (--require ${spec})`);
  }
  const missing = [...archesIn(live)].filter((arch) => !have.has(arch));
  if (missing.length > 0) {
    fail(
      `refusing to publish: the manifest lacks ${lang} ${version} for ${missing.join(", ")}, which the live manifest has`,
    );
  }
  console.log(`required  ${lang} ${version} present for ${[...have].sort().join(", ")}`);
}

entries.sort((a, b) =>
  a.lang.localeCompare(b.lang) ||
  a.version.localeCompare(b.version) ||
  a.arch.localeCompare(b.arch)
);

writeFileSync(
  join(dist, "manifest.json"),
  `${JSON.stringify({
    schemaVersion: 1,
    generatedAt: new Date().toISOString(),
    entries,
  }, null, 2)}\n`
);

