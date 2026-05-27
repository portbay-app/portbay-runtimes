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

`bcmath,bz2,calendar,ctype,curl,dom,exif,fileinfo,filter,gd,iconv,intl,mbstring,mysqli,mysqlnd,opcache,openssl,pcntl,pdo,pdo_mysql,pdo_pgsql,pdo_sqlite,phar,posix,session,simplexml,soap,sockets,sodium,sqlite,sqlite3,tokenizer,xml,xmlreader,xmlwriter,zip,zlib`

## Release

Run the `release-runtimes` workflow manually with the PHP version to publish.
The workflow builds both macOS architectures, signs/notarizes the binaries when
Apple credentials are configured, packages archives, generates `manifest.json`,
signs it with the Tauri updater private key, and publishes the release.

Required repository secrets:

- `TAURI_SIGNING_PRIVATE_KEY`
- `TAURI_SIGNING_PRIVATE_KEY_PASSWORD`
- `APPLE_SIGNING_IDENTITY`
- `APPLE_API_ISSUER`
- `APPLE_API_KEY`
- `APPLE_API_KEY_P8`

