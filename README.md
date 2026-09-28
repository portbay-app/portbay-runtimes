# PortBay Runtimes

Self-built runtime artifacts consumed by PortBay's managed-runtime installer.

The app downloads `manifest.json` and `manifest.json.sig` from this repository's
latest GitHub Release. It verifies the manifest with the same minisign updater
public key embedded in `portbay/src-tauri/tauri.conf.json`, then downloads the
arch-specific `.tar.zst` archive listed for the requested runtime.

## Runtime Strategy

- Default PHP line: **8.4.x**. This is current enough for modern Laravel/Symfony
  while avoiding a newest-major default for first-run compatibility.
- Archive format: `.tar.zst` only.
- Architectures: separate `aarch64` and `x86_64` archives.
- PHP layout:
  - `bin/php`
  - `sbin/php-fpm`
  - `etc/php.ini`
  - `lib/`
  - `extensions/`

## PHP Extension Set

The first PHP runtime is intentionally broad enough for Laravel, WordPress, and
common PHP apps without shipping every PECL module:

`bcmath,bz2,calendar,ctype,curl,dom,exif,fileinfo,filter,gd,iconv,intl,mbstring,mysqli,mysqlnd,opcache,openssl,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,phar,posix,session,simplexml,soap,sockets,sodium,sqlite3,tokenizer,xml,xmlreader,xmlwriter,zip,zlib`

## Node

- Default line: **22.x LTS**. Fetched from the official `nodejs.org/dist`
  tarball and repacked — **not compiled**; the SHA-256 is verified against
  Node's published `SHASUMS256.txt` before repacking.
- Layout: `bin/{node,npm,npx,corepack}` + `lib/node_modules/{npm,corepack}`.

## Ollama

- Fetched from the official GitHub release (`ollama-darwin.tgz`) and repacked —
  **not compiled**; the SHA-256 is verified against the `sha256sum.txt` Ollama
  publishes with each release (`build-ollama-runtime.sh`).
- Layout: the whole flat tarball lands under `bin/` (`bin/ollama` plus
  `llama-server`, `llama-quantize`, and the `libggml-*.so` runners) — Ollama
  discovers its runner libraries relative to the executable, so the siblings
  must stay next to `bin/ollama`.
- Installed on demand from the AI page (not registered as a language runtime);
  the app prefers it over any Homebrew/system/Ollama.app copy.

## Database engines

Installed on demand by the app and preferred over any Homebrew/system copy.
Every binary the app needs lives under `bin/` so it resolves relative to the
install root. arm64-only, like PHP.

- **PostgreSQL** (`build-postgres-runtime.sh`, source build):
  - `bin/postgres` (daemon), `bin/psql`, `bin/initdb`, `bin/pg_dump`, `bin/pg_dumpall`, …
  - `lib/libpq.*.dylib`, `share/postgresql/` (located relative to `bin/`)
  - Built `--without-icu/readline/zlib`; macOS dylib load paths rewritten to
    `@rpath`/`@loader_path` so the tree is relocatable.
- **MySQL** (`build-mysql-runtime.sh`, official macOS tarball, repacked):
  - `bin/mysqld` (daemon), `bin/mysql`, `bin/mysqldump`, … + `lib/`, `share/`
  - The macOS build tag in the upstream filename changes per release
    (8.4.4/8.4.5 → `macos15`); set via the `mysql_macos_tag` input.
- **Redis** (`build-redis-runtime.sh`, source build):
  - `bin/redis-server` (daemon), `bin/redis-cli`
  - `BUILD_TLS=no` → links only system libraries (nothing to relocate).

The manifest `lang` for an engine equals the app's `DatabaseEngine::id()`
(`postgres`/`mysql`/`redis`); `generate-manifest.mjs` maps archive prefixes to it.

## Web servers

Per-project PHP backends behind PortBay's Caddy edge, installed on demand from
the Web Servers page and preferred over any Homebrew/system copy. No TLS: the
edge terminates it. Both are source builds from pinned, checksum-verified
tarballs, relocatable, and smoke-tested from a copy outside the build tree
with the build tree deleted.

- **nginx** (`build-nginx-runtime.sh`, manifest lang `nginx`):
  - `sbin/nginx`, `conf/{mime.types,fastcgi_params,fastcgi.conf}`
  - PCRE2 and zlib are compiled in statically; the binary links only
    libSystem. rewrite, fastcgi, gzip and realip are built in.
  - Every compiled-in runtime path is relative to `-p`, and the pre-config
    error log is stderr, so it runs from wherever it is unpacked.
- **Apache httpd 2.4** (`build-httpd-runtime.sh`, archive `httpd-*`, manifest
  lang `apache`):
  - `bin/httpd`, `modules/mod_*.so`, `lib/libapr-1.0.dylib`,
    `lib/libaprutil-1.0.dylib`, `conf/mime.types`
  - Modules, all shared: mpm_event, unixd, authz_core, authz_host, dir, mime,
    rewrite, setenvif, log_config, proxy, proxy_fcgi, headers. This is the set
    PortBay's generated `httpd.conf` loads, plus mod_headers.
  - dylib load paths are rewritten to `@rpath` with an `@loader_path/../lib`
    rpath. `HTTPD_ROOT` is `/opt/portbay/httpd`, which is never used: the app
    sets `ServerRoot` and every path itself, and resolves modules from
    `<bin>/../modules`.
- Licence texts for each component (and the Apache NOTICE files) ship in
  `share/licenses/`: nginx BSD-2-Clause, httpd/APR/APR-util Apache-2.0, PCRE2
  BSD-3-Clause WITH PCRE2-exception, zlib Zlib.
- x86_64: both scripts cross-build from an arm64 host by compiling universal
  and thinning. A cross-built archive is not smoke-tested, so run it on Intel
  or Rosetta before publishing it.

`drafts/webservers-manifest-entries.json` holds manifest entries for archives
built locally and not yet published. The release workflow regenerates the real
entries, so its hashes will differ once CI signs and repacks.

## Release

Run the `release-runtimes` workflow manually with the runtime versions to
publish (PHP, Node, PostgreSQL, MySQL, Redis, nginx, Apache httpd). The workflow builds each runtime
(arm64), signs/notarizes the binaries when Apple credentials are configured,
packages archives, generates `manifest.json`, signs it with the Tauri updater
private key, and publishes the release.

The `runtimes` input picks what to build: `all` (default) or a comma list of
`php,node,ollama,postgres,redis,mysql,nginx,httpd`. Unselected build jobs are
skipped. The new release becomes `releases/latest`, so its manifest replaces
the one every installed app reads: `generate-manifest.mjs --live` starts from
the current live manifest and keeps every entry this run did not rebuild, with
its URL into the release that published it. Deleting an older release
therefore breaks the entries still pointing at it. The publish job refuses to
sign or publish a manifest without PHP 8.4.21 (`--require php@8.4.21`).

Because their upstreams ship no fetchable checksum sidecar, **Redis and MySQL
require pinned SHA-256 inputs when selected** (`redis_sha256`,
`mysql_sha256_aarch64`); MySQL also needs the upstream `mysql_macos_tag`. PostgreSQL verifies against its
upstream-published checksum automatically.

Required repository secrets:

- `TAURI_SIGNING_PRIVATE_KEY`
- `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_API_ISSUER`
- `APPLE_API_KEY`
- `APPLE_API_KEY_P8`
