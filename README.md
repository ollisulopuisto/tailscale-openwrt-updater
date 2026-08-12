# ts-update

Semi-automated Tailscale updates on OpenWrt routers using upstream static binaries ([pkgs.tailscale.com](https://pkgs.tailscale.com)). Updates are automatically rolled back unless confirmed within a configurable window — designed for remote updates where failure would sever your only connection to the device.

## Why

OpenWrt's package feed lags behind upstream releases, and Tailscale's built-in `tailscale update` command as well as the admin console's "Start update" feature do not work on OpenWrt. The feed package installs `/usr/sbin/tailscale` as a symlink to `tailscaled` because OpenWrt compiles the CLI directly into the daemon binary (`ts_include_cli`); in the upstream release tarball, they are two separate binaries, so the symlink must be replaced with the actual executable binary.

The init script, UCI configuration, and state remain managed by the package: `/etc/init.d/tailscale`, `/etc/config/tailscale`, `/var/lib/tailscale`. Only the binaries in `/usr/sbin` are replaced.

## Installation

### Directly from GitHub on the Device

Directly on the router, without needing to copy files from a workstation. Both `wget` (uclient-fetch on OpenWrt) and `curl` are supported — the script automatically detects which one is installed:

```sh
URL=https://raw.githubusercontent.com/ollisulopuisto/tailscale-openwrt-updater/main/netinstall.sh
wget -O /tmp/netinstall.sh "$URL"     # or: curl -fsSL -o /tmp/netinstall.sh "$URL"
sh /tmp/netinstall.sh
```

Or as a single line, if you do not wish to read the script first:

```sh
wget -O- "$URL" | sh
curl -fsSL "$URL" | sh
```

Avoid using `wget -q` in pipe mode: if the download fails, `sh` receives empty input and the installation completes silently without taking any action. Without `-q`, errors are visible. The installer script is written so an interrupted download won't execute a partial installation (the main logic is wrapped in `main()` called on the last line), but empty input cannot be detected from within the script.

`netinstall.sh` fetches `ts-update`, the boot check init script, and default configuration template, verifies integrity, installs them, and enables the boot check service. Existing `/etc/default/ts-update` files are preserved so reinstallations won't lose device-specific settings. If an update is pending confirmation, installation aborts to prevent interfering with an active window.

Pin version and require SHA-256 checksum:

```sh
sh /tmp/netinstall.sh --ref v1.0 --sha256 <checksum>
```

Uninstall (configuration, state, and backups remain intact):

```sh
sh /tmp/netinstall.sh --uninstall
```

If HTTPS fails, the device is usually missing `ca-bundle` or `libustream-mbedtls` (`apk add ca-bundle`).

### From a Workstation over SSH

Single device:

```sh
scp -O ts-update root@router:/usr/sbin/ts-update
scp -O ts-update-bootcheck.init root@router:/etc/init.d/ts-update-bootcheck
ssh root@router 'chmod 755 /usr/sbin/ts-update /etc/init.d/ts-update-bootcheck \
    && /etc/init.d/ts-update-bootcheck enable'
```

Multiple devices:

```sh
./install.sh root@r1 root@r2
./install.sh -f hosts.txt
```

`install.sh` deploys the main script and boot check init script, then executes `ts-update check` on each target host. Host-specific settings are loaded from `hosts.d/<host>.env` and deployed to `/etc/default/ts-update`. A common default configuration for devices without host-specific files is passed via `-e` — without `-e`, existing device configurations are preserved:

```sh
./install.sh -e ts-update.default -f hosts.txt
```

`-n` performs a dry run without modifying anything, and `-B` skips installing the boot check init script.

Note: `scp -O` (legacy SCP protocol) is required on OpenSSH 9+ as OpenWrt does not run an SFTP server by default.

## Usage

```sh
ts-update check             show current and latest versions, package availability
ts-update run               update binaries, run health check, arm watchdog
ts-update run --dry-run     download and verify checksum, do not modify system
ts-update confirm           confirm update (cancels pending rollback)
ts-update rollback          restore previous version immediately
ts-update status            show state and remaining confirmation time
ts-update boot-check        run after reboot (executed by init script)
```

Standard remote update workflow:

```sh
ssh root@router ts-update run
# TEST CONNECTION FROM THE OUTSIDE (via another tailnet node)
ssh root@router ts-update confirm
```

If confirmation is omitted, the watchdog automatically restores the previous binary version after `TIMEOUT` seconds, restoring your connection.

## Configuration

Via environment variables or config file `/etc/default/ts-update` (environment variables take precedence). Template: `ts-update.default`.

| Variable | Default | Meaning |
|---|---|---|
| `ARCH` | auto-detected | Binary architecture (`arm64`, `mipsle`, …) |
| `TIMEOUT` | 300 | Confirmation window in seconds |
| `PEER` | – | Tailnet IP to ping during health test |
| `IFACE` | `tailscale0` | Network interface to verify |
| `CHECK_ROUTES` | 1 | Verify advertised routes are preserved |
| `HEALTH_WAIT` | 90 | Seconds to wait for daemon startup |
| `WGET` | `wget` | Download tool (expects `-q`/`-T`/`-O` options) |

Path settings (`STATE_DIR`, `BACKUP_DIR`, `SBIN_DIR`, `INIT_SCRIPT`, `TMP_DIR`, `LOCK_FILE`, and `BASE_URL`) can also be overridden; used by the test suite.

## How Safety Mechanisms Work

1. **Architecture validation against server list** prior to downloading: checks `Tarballs` map in `?mode=json` to confirm the specific version/architecture package exists. Invalid guesses are caught before downloading.
2. **Disk space check** prior to downloading, backing up, and swapping binaries to prevent filling `/overlay`.
3. **Checksum verification** (`sha256sum -c`).
4. **New binary execution test** (`tailscale version`) before stopping the service: incompatible architectures won't drop active connections.
5. **Backup** of old binaries saved to `/root/ts-backup/*.gz`.
6. **Health check**: `BackendState: Running`, network interface up, advertised routes unchanged from pre-update state, and optional `tailscale ping PEER`. Failure triggers immediate rollback.
7. **Watchdog** (detached background process via `setsid`) restores previous binaries unless `confirm` is received within deadline. Deadline is measured using monotonic `/proc/uptime`, so NTP clock steps do not truncate the confirmation window; wall-clock timestamp is a fallback surviving reboots.
8. **Boot check**: pending update state saved in `/root`, and `/etc/init.d/ts-update-bootcheck` resumes watchdog for remaining time or triggers rollback if daemon failed or time expired. Prevents unconfirmed updates from persisting across reboots.
9. **Concurrency locking** (`flock`, directory lock fallback) prevents overlapping runs.

JSON parsing uses `jsonfilter` (libubox, built into OpenWrt), with a `sed` fallback if missing.

## Devices with Small Flash Storage (16 MB)

Upstream static binaries are large when unpacked. Measured on 1.102.2 / mipsle:

| File | Size |
|---|---|
| `tailscaled` | 38.7 MiB |
| `tailscale` | 31.7 MiB |
| **Total installation size** | **70.4 MiB** |
| Tarball download | 32.3 MiB |
| Unpacking + tarball simultaneously in `/tmp` | ~103 MiB |

By comparison, the feed binary on the same device is **29.1 MiB** — a single binary with CLI compiled into the daemon (`/usr/sbin/tailscale` is a symlink to `tailscaled`), compressed via squashfs in the image to ~10 MB. Therefore, the feed version fits where upstream binaries cannot.

Example device where flash storage is insufficient (ramips/mt7621, 16 MB flash, 128 MB RAM):

```
/overlay   16.0M  available 14.7M      required 70.4M
tmpfs      58.0M  available 57.6M      required 103M (download + extract)
```

**Do not try to work around this using `/tmp`.** `tmpfs` uses RAM, and its pages can only be reclaimed by swapping. When copying large files to `/tmp`, low-memory devices resort to swap. If swap resides on the same storage being read, I/O saturates, the hardware watchdog fails to respond, and the device resets. This occurred during testing: on a 128 MB board, copying 40 MB to `/tmp` rebooted the router mid-copy. Always download and extract to physical storage.

`ts-update check` reports disk space constraints directly, and `ts-update run` aborts before downloading. Options for small flash devices:

1. **Stay on feed package version** and update Tailscale by flashing a new OpenWrt image containing an updated package. This is the native path for 16 MB flash devices.
2. **Run binaries from a USB drive** and leave symlinks in `/usr/sbin`. Symlinks cost bytes in overlay, not megabytes.

### Running Binaries from USB Drive

The initial setup is done manually because `ts-update` does not alter layout structure. Afterward, `ts-update` handles updates normally.

```sh
V=1.102.2                       # ts-update check shows latest version
A=mipsle                        # ts-update check shows architecture
mkdir -p /mnt/usb/tailscale /mnt/usb/tmp
cd /mnt/usb/tmp
wget "https://pkgs.tailscale.com/stable/tailscale_${V}_${A}.tgz"
wget "https://pkgs.tailscale.com/stable/tailscale_${V}_${A}.tgz.sha256"
echo "$(cat tailscale_${V}_${A}.tgz.sha256)  tailscale_${V}_${A}.tgz" | sha256sum -c
tar xzf "tailscale_${V}_${A}.tgz"
cp tailscale_${V}_${A}/tailscale tailscale_${V}_${A}/tailscaled /mnt/usb/tailscale/
chmod 755 /mnt/usb/tailscale/tailscale*

/mnt/usb/tailscale/tailscale version    # test BEFORE modifying anything

/etc/init.d/tailscale stop
rm -f /usr/sbin/tailscale /usr/sbin/tailscaled
ln -s /mnt/usb/tailscale/tailscaled /usr/sbin/tailscaled
ln -s /mnt/usb/tailscale/tailscale  /usr/sbin/tailscale
/etc/init.d/tailscale start
tailscale status
```

Then configure `/etc/default/ts-update`:

```sh
SBIN_DIR=/mnt/usb/tailscale
BACKUP_DIR=/mnt/usb/ts-backup
TMP_DIR=/mnt/usb/tmp
# State remains on flash so boot check works even if USB drive is disconnected
STATE_DIR=/root/ts-update
```

Reverting to feed version: `/usr/sbin` is on overlayfs, so original files remain in `/rom` behind symlinks. Removing overlay entries restores original files:

```sh
/etc/init.d/tailscale stop
rm -f /overlay/upper/usr/sbin/tailscale /overlay/upper/usr/sbin/tailscaled
reboot
```

Two warnings: **The daemon binary relies on external storage:** if mount is lost, Tailscale crashes. Use this only on devices accessible via secondary paths (LAN/serial). Also, **`apk upgrade` may restore feed binaries** to `/usr/sbin`, overwriting symlinks and reverting to the feed version — verify `ls -l /usr/sbin/tailscale*` after package upgrades.

## What This Does NOT Protect Against

- **Router crashes or freezes.** Watchdog runs on the same hardware; if the entire device hangs, rollback cannot trigger before reboot — and if device fails to boot, not after either.
- **Loss of LAN connectivity or power.** Boot check only helps if the device boots up.
- **Insufficient flash storage.** On 16 MB devices, upstream binaries do not fit in `/usr/sbin`; see USB section above. `check` and `run` report this but cannot bypass hardware limits.
- **Package manager upgrades.** `apk upgrade` re-installs feed binaries to `/usr/sbin` (and `/usr/sbin/tailscale` as a symlink). Re-run `ts-update run` after package updates.
- **Tailscale configuration errors.** Health check verifies daemon status, interface, and advertised routes — not whether ACLs, DNS, or exit node routing function as expected. Always test connections externally before `confirm`.
- **Broken upstream releases** that start up and pass health check but break other functionality. Manual testing during confirmation window is essential.
- **Clock jumps.** Deadline is an absolute timestamp; boot check caps remaining time to `TIMEOUT`, but severe backward clock jumps cannot be automatically corrected.

## Development & Testing

```sh
shellcheck -s sh ts-update install.sh netinstall.sh ts-update-bootcheck.init tests/run-tests.sh
./tests/run-tests.sh
```

GitHub Actions (`.github/workflows/ci.yml`) runs `shellcheck -s sh`, `dash -n` syntax check, and test matrix across two shells on every push and pull request: `dash` (strict POSIX) and busybox ash (same shell as OpenWrt). Select local test shell with `TS_SH=dash ./tests/run-tests.sh`.

Test suite runs in a sandbox: `tailscale`, init script, and `wget` are stubs, "binaries" are sh scripts printing version strings, and paths point to temporary directories. No real hardware is required or modified. Suite runs twice if `python3` is available: once using `sed` fallback and once with `jsonfilter` stub. Run individual cases by number: `./tests/run-tests.sh 5 6`.

### Test Matrix

| Case | Expected Outcome | Test |
|---|---|---|
| Already on latest version | `run` exits with code 0, leaves system unmodified | 1 |
| Network drops during download | no backup created, binaries unchanged | 2 |
| Checksum mismatch | download removed, exits with error | 3 |
| New binary fails to start | automatic immediate rollback | 4 |
| Confirmation in time | watchdog disarmed, new version kept | 5 |
| No confirmation | rollback executed upon deadline expiry | 6 |
| Dry run | download and checksum verified, nothing changed | 7 |
| Architecture not on server | error reported before download | 8 |
| Concurrent runs | second instance rejected by lock | 9 |
| Feed version `1.98.3-1` vs `1.98.3` | normalizes version, does not report newer | 10 |
| Reboot during confirmation window, daemon healthy | watchdog resumed, rollback if unconfirmed | 11 |
| Reboot during confirmation window, daemon broken | immediate rollback | 12 |
| Advertised routes drop | health check fails, rollback executed | 13 |
| `check` and `status` | display version, package availability, and confirmation state | 14 |
| Reboot between binary swap and watchdog arming | rollback executed, incomplete update rejected | 15 |
| Confirmation during watchdog rollback | `confirm` reports actual state | 16 |
| Stale `watchdog.pid` after reboot | ignores alien process PID | 17 |
| `netinstall.sh` from GitHub | installs, preserves config, rejects broken downloads | 18 |
| Feed symlink layout | backup saved as link, rollback restores symlink | 19 |
| Installation target full | aborts prior to download | 20 |
| Clock jump during confirmation window | prevents premature rollback | 21 |
| Working directory missing | directory created automatically, errors log reason | 22 |

### Verified on Hardware

| Architecture | Device | Result |
|---|---|---|
| `arm64` | aarch64 / OpenWrt 25.12.5 | ts-update active, updates with watchdog protection |
| `mipsle` | ramips/mt7621, `DISTRIB_ARCH=mipsel_24kc` | upstream binary runs, `detect_arch` correct |

On `mipsle`, binaries run from USB drive behind symlinks (see above): storage insufficient for 16 MB flash, but binary started and joined tailnet normally (`Starting -> Running`, `--state /etc/tailscale/tailscaled.state` loaded, no re-authentication required). Memory usage 31 MiB RSS on 116 MiB board.

Untested hardware: `mips`, `mips64`, `mips64le`, `arm`, `amd64`, `386`, `riscv64`. `ts-update check` reports immediately if architecture detection matches server packages, and invalid guesses are rejected before downloading.
