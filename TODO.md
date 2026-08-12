# ts-update — Status and Remaining Tasks

## Overview

`ts-update` performs semi-automated updates of Tailscale on OpenWrt routers using upstream static binaries ([pkgs.tailscale.com](https://pkgs.tailscale.com)) and automatically rolls back to the previous version unless confirmed within a configurable timeout window. Designed for remote updates where failure would disconnect the device.

Background and usage instructions: see [README.md](README.md).

## Current Status

Active on single router (aarch64, OpenWrt 25.12.5). Commands implemented:
`check`, `run [--dry-run]`, `confirm`, `rollback`, `status`, `boot-check`,
internal `_watchdog`. Backup saved at `/root/ts-backup/*.gz`, pending state
at `/root/ts-update/`, watchdog detached from session using `setsid`.

Repository includes `install.sh` (multi-host deployment), `ts-update-bootcheck.init`
(boot check init script), `ts-update.default` (config template), and `tests/run-tests.sh`
(sandboxed test matrix, no real hardware required).

## Completed Tasks

### 1. jsonfilter replacing sed parsing — completed
`latest_version()`, `tarball_list()`, `backend_state()`, and `prefs_routes()`
use `jsonfilter` (`@.TarballsVersion`, `@.Tarballs[*]`,
`@.BackendState`, `@.AdvertiseRoutes[*]`). sed fallback path remains if
`jsonfilter` is absent; test matrix executes both code paths.

### 2. Architecture validation against server list — completed
`tarball_available()` verifies against server `Tarballs` map that the exact
version/architecture exists before downloading. Error message lists available architectures. `detect_arch()` serves as initial detection, but invalid guesses are caught before downloading.

### 3. Concurrency locking — completed
`flock -n` on fd 9 in `run` and `rollback`; watchdog waits for lock up to 120s and performs rollback regardless (recovering connection takes priority). Directory lock fallback cleaned up if lock-owning process dies. Watchdog process is spawned with `9>&-` so it does not hold lock for the entire confirmation window.

### 4. Disk space check — completed
`need_space()` checked prior to download (`/tmp`), backup (`/root`), and binary replacement (`/usr/sbin`). Execution halts before any files are modified. If `df` returns no usable data, execution continues with a warning.

### 5. Watchdog survives reboots — completed
Pending state stored in `/root/ts-update/` instead of `/tmp`. `boot-check` +
`/etc/init.d/ts-update-bootcheck` evaluates on boot: if daemon fails to start or confirmation window expired → rollback; otherwise watchdog re-arms for remaining window duration. Deadline is an absolute timestamp and capped to `TIMEOUT` on boot against NTP clock jumps.

### 6. Version comparison — completed
`normalize_version()` strips `v` prefix, `-1` package suffixes, and `(OpenWrt)` suffix; `version_newer()` performs numeric comparison. Feed version `1.98.3-1 (OpenWrt)` no longer appears as a distinct version from upstream `1.98.3`.

### 7. Dry run — completed
`ts-update run --dry-run` downloads, verifies checksum, and tests new binary execution once, but does not stop service or swap binaries.

### 8. Health check scope expansion — completed
Checks `BackendState: Running`, network interface presence (`IFACE`, default `tailscale0`), advertised routes preservation (`tailscale debug prefs`, compared against pre-update snapshot), and optional `tailscale ping PEER`. Pre-update snapshot taken automatically before update, so no host-specific setup required. Failure reasons logged.

### 9. Multi-host deployment — completed
`install.sh` accepts hosts as arguments or `-f` list file, uses `scp -O` (OpenWrt lacks SFTP server), deploys boot check init script, and transfers host-specific `/etc/default/ts-update` configuration from `hosts.d/<host>.env`. Default configuration supplied via `-e`; existing target configuration preserved without `-e`. `-n` displays execution plan without modifying targets.

### 10. Verification and documentation — completed
`shellcheck -s sh` passes cleanly on all scripts. README covers installation, usage, and explicit protection boundaries.

## Remaining Tasks

- **Additional architectures untested on real hardware**: `mips`, `mips64`, `mips64le`, `arm`, `amd64`, `386`, `riscv64`.
  `detect_arch()` accuracy is visible in `ts-update check`, and invalid guesses are caught before downloading.
  - `arm64`: running, updates with watchdog protection verified.
  - `mipsle`: verified on ramips/mt7621 (`DISTRIB_ARCH=mipsel_24kc`). Upstream binary runs and connects to tailnet, but 16 MB flash storage cannot fit binaries — binaries run from USB drive via symlinks, with ts-update operating via `SBIN_DIR`. Full ts-update update cycle not yet executed on device.
- **Boot check tested only in sandbox** (tests 11 and 12).
  Real reboot mid-confirmation window pending hardware test.
- **Package manager upgrades** restore feed binaries to `/usr/sbin`.
  Currently documented in README; automatic detection (e.g., `check` detecting restored symlink) not implemented.
- **Log rotation** is simple (truncation to 500 lines when file exceeds 256 KB). Sufficient for usage, but long-term run unverified.

## Test Matrix

Execute `./tests/run-tests.sh` (sandboxed, no hardware required); per-case details documented in README.
