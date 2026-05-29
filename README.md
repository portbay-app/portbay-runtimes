# PortBay Runtimes

Self-built runtime artifacts consumed by PortBay's managed-runtime installer.

The app downloads `manifest.json` and `manifest.json.sig` from this repository's
latest GitHub Release. It verifies the manifest with the same minisign updater
public key embedded in `portbay/src-tauri/tauri.conf.json`, then downloads the
arch-specific `.tar.zst` archive listed for the requested runtime.

## Runtime Strategy

- Archive format: `.tar.zst` only.
- Architectures: separate `aarch64` and `x86_64` archives.
- PHP layout:
  - `bin/php`
  - `sbin/php-fpm`
  - `etc/php.ini`
  - `lib/`
  - `extensions/`
- Default PHP line: **8.4.x**. Current enough for modern Laravel/Symfony
  while avoiding a newest-major default for first-run compatibility.
- Node layout:
  - `bin/node`
  - `bin/npm`
  - `bin/npx`
  - `bin/corepack`
  - `lib/node_modules/npm/`
  - `lib/node_modules/corepack/`
- Default Node line: **22.x LTS** (`22.14.0` at time of writing). Node is
  fetched from the official `nodejs.org/dist` tarball and repacked — it is
  **not compiled from source**. The SHA-256 is verified against Node's
  published `SHASUMS256.txt` before repacking. The extracted binaries are
  Developer-ID signed via `sign-notarize-runtime.sh` (ad-hoc fallback when
  `APPLE_SIGNING_IDENTITY` is unset).

### Database engines

Database engines are managed runtimes too — the app installs them on demand and
prefers them over any Homebrew/system copy. Every binary the app needs lives
under `bin/` so it resolves relative to the install root.

- **PostgreSQL** (`build-postgres-runtime.sh`, source build):
  - `bin/postgres` (daemon), `bin/psql`, `bin/initdb`, `bin/pg_dump`,
    `bin/pg_dumpall`, `bin/pg_ctl`, …
  - `lib/libpq.*.dylib`, `share/postgresql/` (located relative to `bin/`)
  - Built with `--without-icu/readline/zlib`; macOS dylib load paths are
    rewritten to `@rpath`/`@loader_path` so the tree is relocatable.
- **MySQL** (`build-mysql-runtime.sh`, official macOS tarball, repacked):
  - `bin/mysqld` (daemon), `bin/mysql`, `bin/mysqldump`, …
  - `lib/`, `share/` (errmsg + system schema for `--initialize`)
  - The macOS build tag in the upstream filename (`macos14`, …) and per-arch
    SHA-256 are workflow inputs.
- **Redis** (`build-redis-runtime.sh`, source build):
  - `bin/redis-server` (daemon), `bin/redis-cli`
  - `BUILD_TLS=no`, so it links only system libraries — no bundled dylibs,
    nothing to relocate.

The manifest `lang` for an engine equals the app's `DatabaseEngine::id()`
(`postgres`/`mysql`/`mariadb`/`redis`/`mongo`/`memcached`); `generate-manifest.mjs`
maps archive prefixes to that `lang` (and `php-fpm-*` → `php`).

## PHP Extension Set

The first PHP runtime is intentionally broad enough for Laravel, WordPress, and
common PHP apps without shipping every PECL module:

`bcmath,bz2,calendar,ctype,curl,dom,exif,fileinfo,filter,gd,iconv,intl,mbstring,mysqli,mysqlnd,opcache,openssl,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,phar,posix,session,simplexml,soap,sockets,sodium,sqlite3,tokenizer,xml,xmlreader,xmlwriter,zip,zlib`

## Release

Run the `release-runtimes` workflow manually with the runtime versions to
publish (PHP, Node, PostgreSQL, MySQL, Redis). The workflow builds both macOS
architectures for each runtime, signs/notarizes the binaries when Apple
credentials are configured, packages archives, generates a unified
`manifest.json`, signs it with the Tauri updater private key, and publishes the
release.

Because their upstreams ship no fetchable checksum sidecar, **Redis and MySQL
require pinned SHA-256 inputs** when dispatching (`redis_sha256`, and per-arch
`mysql_sha256_aarch64` / `mysql_sha256_x86_64`); MySQL also needs the upstream
`mysql_macos_tag` (e.g. `macos14`). PostgreSQL and Node verify against their
upstream-published checksums automatically.

Required repository secrets:

- `TAURI_SIGNING_PRIVATE_KEY`
- `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_API_ISSUER`
- `APPLE_API_KEY`
- `APPLE_API_KEY_P8`
