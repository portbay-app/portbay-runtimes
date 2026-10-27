#!/usr/bin/env node
// Manifest history tools for the release workflow. Needs `gh` (authenticated
// via GH_TOKEN in CI).
//
//   merge-manifest.mjs base --repo <owner/name> [--out <file>]
//     Merges the manifest.json of every published release, oldest first, so a
//     newer release's (lang, version, arch) entry replaces an older one. The
//     latest manifest alone is not trusted: a release that published a partial
//     manifest would otherwise erase everything before it. Entries whose
//     archive is no longer attached to the release they point into are left
//     out and reported. Prints the result; writes it with --out. Read-only.
//
//   merge-manifest.mjs drop --in <file> --out <file> [--allow-drop <list>]
//     Copies <in> without the entries --allow-drop names, so the release can
//     leave them out on purpose. Without --allow-drop it is a plain copy.
//
//   merge-manifest.mjs guard --base <file> --new <file> [--allow-drop <list>]
//     Fails when <new> lacks a (lang, arch) that <base> has, unless
//     --allow-drop names it as "lang/arch" or "lang" (every arch).
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";

const [mode, ...rest] = process.argv.slice(2);
const opts = {};
for (let i = 0; i < rest.length; i += 2) {
  if (!rest[i]?.startsWith("--")) usage();
  opts[rest[i].slice(2)] = rest[i + 1] ?? "";
}

function usage() {
  console.error(
    "usage: merge-manifest.mjs base --repo <owner/name> [--out <file>]\n" +
      "       merge-manifest.mjs guard --base <file> --new <file> [--allow-drop <lang[/arch],...>]",
  );
  process.exit(2);
}

function fail(message) {
  console.error(`merge-manifest: ${message}`);
  process.exit(1);
}

function gh(args) {
  return execFileSync("gh", args, { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
}

function readManifest(path) {
  let parsed;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch (err) {
    fail(`cannot read ${path}: ${err.message}`);
  }
  if (parsed.schemaVersion !== 1 || !Array.isArray(parsed.entries)) {
    fail(`${path} is not a schemaVersion 1 manifest with an entries array`);
  }
  return parsed.entries;
}

const key = (e) => `${e.lang}\0${e.version}\0${e.arch}`;
const sortEntries = (list) =>
  list.sort(
    (a, b) =>
      a.lang.localeCompare(b.lang) ||
      a.version.localeCompare(b.version, undefined, { numeric: true }) ||
      a.arch.localeCompare(b.arch),
  );

function base() {
  const repo = opts.repo || usage();
  const releases = gh([
    "api", "--paginate", `repos/${repo}/releases`,
    "--jq", ".[] | select(.draft | not) | select(.prerelease | not) | " +
      "{tag: .tag_name, published: .published_at, assets: [.assets[] | {id, name}]}",
  ])
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line))
    .sort((a, b) => a.published.localeCompare(b.published));

  const attached = new Set();
  for (const r of releases) for (const a of r.assets) attached.add(`${r.tag}/${a.name}`);

  const merged = new Map();
  for (const r of releases) {
    const asset = r.assets.find((a) => a.name === "manifest.json");
    if (!asset) {
      console.log(`release ${r.tag}: no manifest.json, skipped`);
      continue;
    }
    const raw = gh([
      "api", "-H", "Accept: application/octet-stream", `repos/${repo}/releases/assets/${asset.id}`,
    ]);
    let parsed;
    try {
      parsed = JSON.parse(raw);
    } catch (err) {
      fail(`release ${r.tag}: manifest.json is not JSON: ${err.message}`);
    }
    if (parsed.schemaVersion !== 1 || !Array.isArray(parsed.entries)) {
      fail(`release ${r.tag}: manifest.json is not a schemaVersion 1 manifest`);
    }
    console.log(`release ${r.tag} (${r.published}): ${parsed.entries.length} entries`);
    for (const e of parsed.entries) merged.set(key(e), e);
  }

  const entries = [];
  for (const e of merged.values()) {
    const m = /\/releases\/download\/([^/]+)\/([^/]+)$/.exec(e.url);
    if (m && !attached.has(`${decodeURIComponent(m[1])}/${decodeURIComponent(m[2])}`)) {
      console.log(`dangling  ${e.lang} ${e.version} ${e.arch}: ${e.url} is not attached to its release, left out`);
      continue;
    }
    entries.push(e);
  }
  sortEntries(entries);

  console.log(`\nmerged manifest (${entries.length} entries):`);
  for (const e of entries) console.log(`  ${e.lang.padEnd(10)} ${e.version.padEnd(12)} ${e.arch.padEnd(8)} ${e.url}`);

  if (opts.out) {
    writeFileSync(
      opts.out,
      `${JSON.stringify({ schemaVersion: 1, generatedAt: new Date().toISOString(), entries }, null, 2)}\n`,
    );
    console.log(`wrote ${opts.out}`);
  }
}

function allowedDrops() {
  return new Set((opts["allow-drop"] || "").split(",").map((s) => s.trim()).filter(Boolean));
}
const isAllowed = (allowed, e) => allowed.has(`${e.lang}/${e.arch}`) || allowed.has(e.lang);

function drop() {
  if (!opts.in || !opts.out) usage();
  const allowed = allowedDrops();
  const entries = readManifest(opts.in).filter((e) => {
    if (!isAllowed(allowed, e)) return true;
    console.log(`left out  ${e.lang} ${e.version} ${e.arch} (allow_drop)`);
    return false;
  });
  writeFileSync(
    opts.out,
    `${JSON.stringify({ schemaVersion: 1, generatedAt: new Date().toISOString(), entries }, null, 2)}\n`,
  );
}

function guard() {
  if (!opts.base || !opts.new) usage();
  const pairs = (list) => new Set(list.map((e) => `${e.lang}/${e.arch}`));
  const before = pairs(readManifest(opts.base));
  const after = pairs(readManifest(opts.new));
  const allowed = allowedDrops();
  const dropped = [...before].filter((p) => !after.has(p)).sort();
  const refused = dropped.filter((p) => {
    const [lang, arch] = p.split("/");
    return !isAllowed(allowed, { lang, arch });
  });
  for (const p of dropped) {
    console.log(`${refused.includes(p) ? "dropped " : "allowed "} ${p}`);
  }
  if (refused.length > 0) {
    fail(
      `refusing to publish: the new manifest drops ${refused.join(", ")}, which earlier releases ship. ` +
        "Name each in allow_drop to remove it on purpose.",
    );
  }
  console.log(`guard: ok, ${after.size} lang/arch pairs, ${dropped.length} dropped by allow_drop`);
}

if (mode === "base") base();
else if (mode === "drop") drop();
else if (mode === "guard") guard();
else usage();
