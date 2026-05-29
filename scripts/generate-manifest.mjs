#!/usr/bin/env node
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const dist = process.argv[2] ?? "dist";
const baseUrl = process.argv[3];
if (!baseUrl) {
  console.error("usage: generate-manifest.mjs <dist> <base-url>");
  process.exit(2);
}

const entries = [];
for (const name of readdirSync(dist)) {
  // Archive prefix → the manifest `lang` the app filters on:
  //   php-fpm-*  → "php"  (the PHP build ships php + php-fpm)
  //   <engine>-* → "<engine>" for database engines, matching DatabaseEngine::id()
  //                ("mysql"/"mariadb"/"postgres"/"redis"/"mongo"/"memcached")
  const match =
    /^(php-fpm|mysql|mariadb|postgres|redis|mongo|memcached)-(.+)-(aarch64|x86_64)\.tar\.zst$/.exec(
      name,
    );
  if (!match) continue;
  const [, prefix, version, arch] = match;
  const lang = prefix === "php-fpm" ? "php" : prefix;
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

