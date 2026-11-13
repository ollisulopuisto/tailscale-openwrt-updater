#!/bin/sh
# run-tests.sh — runs test matrix in a sandbox.
#
# No real files/devices modified: ts-update is pointed via environment variables
# (STATE_DIR, BACKUP_DIR, SBIN_DIR, INIT_SCRIPT, TMP_DIR, BASE_URL)
# to a temporary directory, and tailscale, init script, and wget are stubs.
# "Binaries" are sh scripts that output their version.
#
#   ./tests/run-tests.sh          run all tests
#   ./tests/run-tests.sh 5 6      run only tests 5 and 6
#
# Suite is run twice if python3 is available: once without jsonfilter
# (sed fallback path) and once with a jsonfilter stub. TS_SH selects
# the shell used to execute ts-update (default: sh).

# shellcheck disable=SC2317  # helpers and test cases called indirectly
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SRC/ts-update"
WANT="$*"
# Shell used to run ts-update. On OpenWrt it is busybox ash, so
# CI runs the suite with both dash and busybox.
TS_SH="${TS_SH:-sh}"
ROOT="${TMPDIR:-/tmp}/ts-update-tests.$$"
PASS=0
FAIL=0
FAILED=""
USE_JSONFILTER=0

OLD=1.98.3
NEW=1.100.0
ARCH=arm64

cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT INT TERM

say()  { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$*"; }
bad()  { FAIL=$((FAIL + 1)); FAILED="$FAILED
  - $CASE: $*"; printf '  FAIL %s\n' "$*"; }

assert()        { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }
assert_file()   { if [ -e "$2" ]; then ok "$1"; else bad "$1 (missing: $2)"; fi; }
assert_nofile() { if [ ! -e "$2" ]; then ok "$1"; else bad "$1 (should not exist: $2)"; fi; }

# --- sandbox ------------------------------------------------------------

# fake_binary <file> <version> [BROKEN]
fake_binary() {
	cat > "$1" <<EOF
#!/bin/sh
# stub-tailscale $2 ${3:-}
V="$2"
STATE="$SB"
case "\$1 \${2:-}" in
	"version "*)
		echo "\$V"
		echo "  go version: stub"
		;;
	"status --json")
		if [ -f "\$STATE/daemon.pid" ]; then
			printf '{\n  "Version": "%s",\n  "BackendState": "Running"\n}\n' "\$V"
		else
			printf '{\n  "Version": "%s",\n  "BackendState": "Stopped"\n}\n' "\$V"
		fi
		;;
	"debug prefs")
		cat "\$STATE/prefs.json"
		;;
	"ping "*)
		[ -f "\$STATE/peer_down" ] && exit 1
		echo "pong"
		;;
	"status "*|"status")
		echo "stub status \$V"
		;;
	*) echo "stub: unknown command: \$*" >&2; exit 1 ;;
esac
EOF
	chmod 755 "$1"
}

make_tarball() {  # make_tarball <version> <arch> [BROKEN]
	_v="$1"; _a="$2"; _b="${3:-}"
	_d="$SB/build/tailscale_${_v}_${_a}"
	mkdir -p "$_d"
	fake_binary "$_d/tailscale" "$_v" "$_b"
	fake_binary "$_d/tailscaled" "$_v" "$_b"
	(cd "$SB/build" && tar czf "$SB/www/tailscale_${_v}_${_a}.tgz" "tailscale_${_v}_${_a}")
	sha256sum "$SB/www/tailscale_${_v}_${_a}.tgz" | awk '{print $1}' \
		> "$SB/www/tailscale_${_v}_${_a}.tgz.sha256"
}

write_json() {  # write_json <TarballsVersion> <architectures...>
	_v="$1"; shift
	{
		printf '{\n  "TarballsVersion": "%s",\n  "Tarballs": {\n' "$_v"
		_first=1
		for _a in "$@"; do
			[ "$_first" = 1 ] || printf ',\n'
			_first=0
			printf '    "%s": "tailscale_%s_%s.tgz"' "$_a" "$_v" "$_a"
		done
		printf '\n  },\n  "PkgsVersion": "%s"\n}\n' "$_v"
	} > "$SB/www/index.json"
}

setup() {  # setup [current version]
	_cur="${1:-$OLD}"
	SB="$ROOT/case${CASE%% *}"
	rm -rf "$SB"
	mkdir -p "$SB/bin" "$SB/sbin" "$SB/state" "$SB/backup" "$SB/tmp" "$SB/www" "$SB/build"

	printf '{"AdvertiseRoutes":["192.168.1.0/24"],"WantRunning":true}\n' > "$SB/prefs.json"

	fake_binary "$SB/sbin/tailscale" "$_cur"
	fake_binary "$SB/sbin/tailscaled" "$_cur"
	touch "$SB/daemon.pid"

	# init stub: starts only if tailscaled is not broken
	cat > "$SB/bin/init-tailscale" <<EOF
#!/bin/sh
case "\$1" in
	stop)  rm -f "$SB/daemon.pid" ;;
	start) grep -q BROKEN "$SB/sbin/tailscaled" || touch "$SB/daemon.pid" ;;
esac
exit 0
EOF
	chmod 755 "$SB/bin/init-tailscale"

	# wget stub: serves from $SB/www, fails if $SB/netdown exists.
	# Passed to ts-update via WGET variable since busybox sh can be built
	# in standalone mode where PATH stub would not be visible.
	cat > "$SB/bin/wget" <<EOF
#!/bin/sh
out=""; url=""
while [ \$# -gt 0 ]; do
	case "\$1" in
		-O) out="\$2"; shift 2 ;;
		-T) shift 2 ;;
		-*) shift ;;
		*) url="\$1"; shift ;;
	esac
done
[ -f "$SB/netdown" ] && exit 4
case "\$url" in
	*'?mode=json') src="$SB/www/index.json" ;;
	*) src="$SB/www/\$(basename "\$url")" ;;
esac
[ -f "\$src" ] || exit 8
if [ -n "\$out" ]; then cp "\$src" "\$out"; else cat "\$src"; fi
exit 0
EOF
	chmod 755 "$SB/bin/wget"

	if [ "$USE_JSONFILTER" = 1 ]; then
		cp "$SRC/tests/jsonfilter-stub" "$SB/bin/jsonfilter"
		chmod 755 "$SB/bin/jsonfilter"
	fi

	write_json "$NEW" "$ARCH" amd64 mipsle
	make_tarball "$NEW" "$ARCH"
}

ts() {
	env -i \
		PATH="$SB/bin:$SB/sbin:/usr/bin:/bin:/sbin:/usr/sbin" \
		HOME="$SB" \
		CONFIG_FILE=/dev/null \
		STATE_DIR="$SB/state" \
		BACKUP_DIR="$SB/backup" \
		SBIN_DIR="$SB/sbin" \
		INIT_SCRIPT="$SB/bin/init-tailscale" \
		LOCK_FILE="$SB/lock" \
		TMP_DIR="${TS_TMP_DIR:-$SB/tmp}" \
		BASE_URL="http://stub/stable" \
		WGET="$SB/bin/wget" \
		ARCH="$ARCH" \
		TIMEOUT="${TS_TIMEOUT:-300}" \
		HEALTH_WAIT="${TS_HEALTH_WAIT:-6}" \
		PEER="${TS_PEER:-}" \
		CHECK_ROUTES="${TS_CHECK_ROUTES:-1}" \
		"$TS_SH" "$SCRIPT" "$@"
}

installed_version() { "$SB/sbin/tailscale" version | head -n1; }

want() { case " $WANT " in *" $1 "*) return 0 ;; esac; [ -z "$WANT" ]; }

# --- tests --------------------------------------------------------------

case1() {
	CASE="1 already on latest version"; setup "$NEW"; say "$CASE"
	out="$(ts run 2>&1)"; rc=$?
	assert "exits with code 0" "$rc" 0
	case "$out" in *"Already on latest"*) ok "reports up to date" ;;
		*) bad "unexpected output: $out" ;; esac
	assert_nofile "no backup created" "$SB/backup/tailscaled.gz"
	assert_nofile "no pending update" "$SB/state/deadline"
}

case2() {
	CASE="2 network interrupted during download"; setup; say "$CASE"
	rm -f "$SB/www/tailscale_${NEW}_${ARCH}.tgz"
	out="$(ts run 2>&1)"; rc=$?
	assert "exits with error" "$rc" 1
	case "$out" in *"download failed"*) ok "reports download error" ;;
		*) bad "unexpected output: $out" ;; esac
	assert_nofile "no backup created" "$SB/backup/tailscaled.gz"
	assert "binary not modified" "$(installed_version)" "$OLD"
	assert_file "daemon untouched" "$SB/daemon.pid"
}

case3() {
	CASE="3 checksum mismatch"; setup; say "$CASE"
	echo "0000000000000000000000000000000000000000000000000000000000000000" \
		> "$SB/www/tailscale_${NEW}_${ARCH}.tgz.sha256"
	out="$(ts run 2>&1)"; rc=$?
	assert "exits with error" "$rc" 1
	case "$out" in *"checksum mismatch"*) ok "reports checksum error" ;;
		*) bad "unexpected output: $out" ;; esac
	assert_nofile "download cleaned up" "$SB/tmp/tailscale_${NEW}_${ARCH}.tgz"
	assert "binary not modified" "$(installed_version)" "$OLD"
}

case4() {
	CASE="4 new binary fails to start"; setup; say "$CASE"
	make_tarball "$NEW" "$ARCH" BROKEN
	out="$(ts run 2>&1)"; rc=$?
	assert "exits with error" "$rc" 1
	case "$out" in *"rolling back"*|*"restoring"*) ok "performs immediate rollback" ;;
		*) bad "unexpected output: $out" ;; esac
	assert "old version restored" "$(installed_version)" "$OLD"
	assert_file "daemon running" "$SB/daemon.pid"
	assert_nofile "no pending deadline" "$SB/state/deadline"
}

case5() {
	CASE="5 confirmation in time"; setup; say "$CASE"
	TS_TIMEOUT=60 ts run >/dev/null 2>&1
	assert "new version installed" "$(installed_version)" "$NEW"
	assert_file "watchdog armed" "$SB/state/deadline"
	pid="$(cat "$SB/state/watchdog.pid")"
	ts confirm >/dev/null 2>&1
	sleep 8   # longer than watchdog poll interval
	if kill -0 "$pid" 2>/dev/null; then bad "watchdog remained alive"; else ok "watchdog disarmed"; fi
	assert_nofile "deadline file removed" "$SB/state/deadline"
	assert "new version remains active" "$(installed_version)" "$NEW"
}

case6() {
	CASE="6 no confirmation"; setup; say "$CASE"
	TS_TIMEOUT=5 ts run >/dev/null 2>&1
	assert "new version installed" "$(installed_version)" "$NEW"
	i=0
	while [ "$i" -lt 30 ] && [ -f "$SB/state/deadline" ]; do sleep 1; i=$((i + 1)); done
	sleep 2
	assert "rollback after timeout" "$(installed_version)" "$OLD"
	assert_file "daemon running after rollback" "$SB/daemon.pid"
	assert_nofile "state cleaned up" "$SB/state/deadline"
}

case7() {
	CASE="7 dry run"; setup; say "$CASE"
	out="$(ts run --dry-run 2>&1)"; rc=$?
	assert "exits with code 0" "$rc" 0
	case "$out" in *"Dry run complete"*) ok "reports result" ;;
		*) bad "unexpected output: $out" ;; esac
	assert "binary not modified" "$(installed_version)" "$OLD"
	assert_file "daemon not stopped" "$SB/daemon.pid"
	assert_nofile "no backup created" "$SB/backup/tailscaled.gz"
	assert_nofile "no pending update" "$SB/state/deadline"
	assert_nofile "temporary files cleaned up" "$SB/tmp/tailscale_${NEW}_${ARCH}.tgz"
}

case8() {
	CASE="8 architecture not on server"; setup; say "$CASE"
	write_json "$NEW" amd64 mipsle
	out="$(ts run 2>&1)"; rc=$?
	assert "exits with error" "$rc" 1
	case "$out" in *"does not have package"*) ok "reports missing package" ;;
		*) bad "unexpected output: $out" ;; esac
	case "$out" in *"amd64"*) ok "lists available architectures" ;;
		*) bad "does not list options: $out" ;; esac
	assert_nofile "nothing downloaded" "$SB/tmp/tailscale_${NEW}_${ARCH}.tgz"
	assert "binary not modified" "$(installed_version)" "$OLD"
}

case9() {
	CASE="9 concurrency lock"; say "$CASE"
	if ! command -v flock >/dev/null 2>&1; then
		say "  skipped (flock missing on host)"
		return 0
	fi
	setup
	# hold lock from another process
	sh -c "exec 9>\"$SB/lock\"; flock 9; sleep 6" &
	holder=$!
	sleep 1
	out="$(ts run 2>&1)"; rc=$?
	assert "concurrent run rejected" "$rc" 1
	case "$out" in *"Another ts-update instance"*) ok "reports reason" ;;
		*) bad "unexpected output: $out" ;; esac
	assert "binary not modified" "$(installed_version)" "$OLD"
	kill "$holder" 2>/dev/null
	wait "$holder" 2>/dev/null
}

case10() {
	CASE="10 feed version does not look newer"; setup "1.98.3-1 (OpenWrt)"; say "$CASE"
	write_json 1.98.3 "$ARCH"
	out="$(ts run 2>&1)"; rc=$?
	assert "exits with code 0" "$rc" 0
	case "$out" in *"Already on latest"*) ok "normalizes version comparison" ;;
		*) bad "unexpected output: $out" ;; esac
	assert_nofile "no pending update" "$SB/state/deadline"
}

case11() {
	CASE="11 boot during confirmation window, daemon healthy"; setup; say "$CASE"
	TS_TIMEOUT=120 ts run >/dev/null 2>&1
	# simulate boot: kill watchdog, state remains on disk
	kill "$(cat "$SB/state/watchdog.pid")" 2>/dev/null
	sleep 1
	assert_file "deadline preserved on disk" "$SB/state/deadline"
	# On boot uptime resets, causing monotonic deadline from previous session to be discarded.
	echo "$(( $(awk '{print int($1)}' /proc/uptime) + 100000 ))" \
		> "$SB/state/deadline.uptime"
	# set wall-clock deadline near present to allow rollback in test
	echo "$(( $(date +%s) + 5 ))" > "$SB/state/deadline"
	TS_TIMEOUT=120 ts boot-check >/dev/null 2>&1
	assert_file "watchdog re-armed" "$SB/state/watchdog.pid"
	i=0
	while [ "$i" -lt 30 ] && [ -f "$SB/state/deadline" ]; do sleep 1; i=$((i + 1)); done
	sleep 2
	assert "rollback executed after reboot" "$(installed_version)" "$OLD"
}

case12() {
	CASE="12 boot during confirmation window, daemon broken"; setup; say "$CASE"
	TS_TIMEOUT=120 ts run >/dev/null 2>&1
	kill "$(cat "$SB/state/watchdog.pid")" 2>/dev/null
	sleep 1
	rm -f "$SB/daemon.pid"          # daemon failed to start on boot
	sed -i '' 's/^# stub-tailscale.*/# stub-tailscale BROKEN/' "$SB/sbin/tailscaled" 2>/dev/null || \
		sed -i 's/^# stub-tailscale.*/# stub-tailscale BROKEN/' "$SB/sbin/tailscaled"
	out="$(TS_TIMEOUT=120 ts boot-check 2>&1)"
	case "$out" in *"rolling back"*|*"failed"*) ok "boot-check executes rollback" ;;
		*) bad "unexpected output: $out" ;; esac
	assert "old version restored" "$(installed_version)" "$OLD"
	assert_nofile "state cleaned up" "$SB/state/deadline"
}

case13() {
	CASE="13 advertised routes disappear"; setup; say "$CASE"
	# new version drops routes: prefs cleared when new daemon starts
	cat > "$SB/bin/init-tailscale" <<EOF
#!/bin/sh
case "\$1" in
	stop)  rm -f "$SB/daemon.pid" ;;
	start)
		touch "$SB/daemon.pid"
		grep -q "$NEW" "$SB/sbin/tailscaled" && \
			printf '{"AdvertiseRoutes":[],"WantRunning":true}\n' > "$SB/prefs.json"
		;;
esac
exit 0
EOF
	chmod 755 "$SB/bin/init-tailscale"
	out="$(TS_HEALTH_WAIT=6 ts run 2>&1)"; rc=$?
	assert "exits with error" "$rc" 1
	case "$out" in *"advertised routes"*) ok "detects lost routes" ;;
		*) bad "unexpected output: $out" ;; esac
	assert "old version restored" "$(installed_version)" "$OLD"
}

case14() {
	CASE="14 status and check"; setup; say "$CASE"
	out="$(ts check 2>&1)"
	case "$out" in *"$NEW"*) ok "check shows latest version" ;;
		*) bad "check fails to show latest: $out" ;; esac
	case "$out" in *"tailscale_${NEW}_${ARCH}.tgz"*) ok "check confirms package presence" ;;
		*) bad "check does not verify package: $out" ;; esac
	out="$(ts status 2>&1)"
	case "$out" in *"no pending update"*) ok "status: no pending update" ;;
		*) bad "status incorrect: $out" ;; esac
	TS_TIMEOUT=60 ts run >/dev/null 2>&1
	out="$(ts status 2>&1)"
	case "$out" in *"PENDING CONFIRMATION"*) ok "status: pending confirmation" ;;
		*) bad "status incorrect: $out" ;; esac
	case "$out" in *"watchdog:     running"*) ok "status: watchdog running" ;;
		*) bad "status fails to detect watchdog: $out" ;; esac
	ts confirm >/dev/null 2>&1
}

case15() {
	CASE="15 boot between binary swap and watchdog setup"; setup; say "$CASE"
	TS_TIMEOUT=120 ts run >/dev/null 2>&1
	# simulate: watchdog and deadline didn't reach disk, only pending
	kill "$(cat "$SB/state/watchdog.pid")" 2>/dev/null
	rm -f "$SB/state/deadline" "$SB/state/watchdog.pid"
	sleep 1
	assert_file "pending update recorded" "$SB/state/pending"
	out="$(ts status 2>&1)"
	case "$out" in *"without watchdog"*) ok "status reports incomplete state" ;;
		*) bad "status fails to detect state: $out" ;; esac
	out="$(TS_TIMEOUT=120 ts boot-check 2>&1)"
	case "$out" in *"interrupted before watchdog setup"*) ok "boot-check identifies situation" ;;
		*) bad "unexpected output: $out" ;; esac
	assert "old version restored" "$(installed_version)" "$OLD"
	assert_nofile "state cleaned up" "$SB/state/pending"
}

case16() {
	CASE="16 confirm occurs simultaneously with watchdog rollback"; setup; say "$CASE"
	TS_TIMEOUT=5 ts run >/dev/null 2>&1
	assert "new version installed" "$(installed_version)" "$NEW"
	# wait until watchdog completes rollback, confirm only then
	i=0
	while [ "$i" -lt 30 ] && [ -f "$SB/state/deadline" ]; do sleep 1; i=$((i + 1)); done
	sleep 3
	out="$(ts confirm 2>&1)"; rc=$?
	assert "confirm does not report false success" "$rc" 0
	case "$out" in *"Nothing is pending confirmation"*|*"rollback occurred"*)
			ok "confirm reports true state" ;;
		*) bad "unexpected output: $out" ;; esac
	assert "old version active" "$(installed_version)" "$OLD"
}

case17() {
	CASE="17 stale watchdog.pid does not kill alien process"; setup; say "$CASE"
	TS_TIMEOUT=120 ts run >/dev/null 2>&1
	kill "$(cat "$SB/state/watchdog.pid")" 2>/dev/null
	sleep 1
	# post-boot PID points to another unrelated process
	sleep 300 &
	victim=$!
	echo "$victim" > "$SB/state/watchdog.pid"
	out="$(ts status 2>&1)"
	case "$out" in *"watchdog:     NOT RUNNING"*) ok "status rejects alien PID as watchdog" ;;
		*) bad "status assumed alien PID was watchdog: $out" ;; esac
	ts confirm >/dev/null 2>&1
	sleep 1
	if kill -0 "$victim" 2>/dev/null; then ok "alien process spared"; else bad "disarm killed wrong process"; fi
	kill "$victim" 2>/dev/null
	wait "$victim" 2>/dev/null
}

# netinstall.sh run with stub download command and --prefix sandbox:
# nothing fetched from net nor installed into host root filesystem.
netinstall() {
	env -i \
		PATH="$SB/bin:/usr/bin:/bin:/sbin" \
		HOME="$SB" \
		BASE_URL="http://stub/repo" \
		sh "$SRC/netinstall.sh" --prefix "$SB/fakeroot" -w "$SB/bin/wget" "$@"
}

case18() {
	CASE="18 netinstall from GitHub"; setup; say "$CASE"
	cp "$SRC/ts-update" "$SRC/ts-update.default" "$SRC/ts-update-bootcheck.init" "$SB/www/"

	out="$(netinstall 2>&1)"; rc=$?
	assert "installation succeeds" "$rc" 0
	assert_file "ts-update installed" "$SB/fakeroot/usr/sbin/ts-update"
	if [ -x "$SB/fakeroot/usr/sbin/ts-update" ]; then ok "ts-update is executable"; else bad "lacks execute permission"; fi
	assert_file "boot check script installed" "$SB/fakeroot/etc/init.d/ts-update-bootcheck"
	assert_file "config file created" "$SB/fakeroot/etc/default/ts-update"
	case "$out" in *sha256*) ok "reports checksum" ;; *) bad "missing checksum: $out" ;; esac

	# device settings must not be lost on reinstall
	echo "PEER=100.64.0.1" >> "$SB/fakeroot/etc/default/ts-update"
	netinstall >/dev/null 2>&1
	if grep -q '^PEER=100.64.0.1' "$SB/fakeroot/etc/default/ts-update"; then
		ok "settings preserved"
	else
		bad "config file was overwritten"
	fi

	# correct checksum accepted, incorrect rejected
	sum="$(sha256sum "$SRC/ts-update" | awk '{print $1}')"
	netinstall -c "$sum" >/dev/null 2>&1
	assert "correct checksum accepted" "$?" 0
	out="$(netinstall -c 0000000000000000000000000000000000000000000000000000000000000000 2>&1)"; rc=$?
	assert "incorrect checksum rejected" "$rc" 1
	case "$out" in *"checksum mismatch"*) ok "reports checksum mismatch" ;; *) bad "unexpected output: $out" ;; esac

	# pending update prevents install without --force
	mkdir -p "$SB/fakeroot/root/ts-update"
	echo "1.98.3 -> 1.100.0" > "$SB/fakeroot/root/ts-update/pending"
	out="$(netinstall 2>&1)"; rc=$?
	assert "pending update blocks install" "$rc" 1
	case "$out" in *"still pending confirmation"*) ok "reports reason" ;; *) bad "unexpected output: $out" ;; esac
	netinstall --force >/dev/null 2>&1
	assert "--force overrides block" "$?" 0
	rm -f "$SB/fakeroot/root/ts-update/pending"

	# truncated download must not be installed
	cp "$SB/fakeroot/usr/sbin/ts-update" "$SB/ts-update.good"
	head -c 400 "$SRC/ts-update" > "$SB/www/ts-update"
	out="$(netinstall 2>&1)"; rc=$?
	assert "download truncated in header rejected" "$rc" 1
	case "$out" in *truncated*) ok "reports reason" ;; *) bad "unexpected output: $out" ;; esac
	head -c 9000 "$SRC/ts-update" > "$SB/www/ts-update"
	out="$(netinstall 2>&1)"; rc=$?
	assert "download truncated mid-file rejected" "$rc" 1
	if cmp -s "$SB/ts-update.good" "$SB/fakeroot/usr/sbin/ts-update"; then
		ok "previous version left untouched"
	else
		bad "corrupted version was installed"
	fi

	# uninstall preserves config and state
	netinstall --uninstall >/dev/null 2>&1
	assert_nofile "ts-update uninstalled" "$SB/fakeroot/usr/sbin/ts-update"
	assert_nofile "boot check script uninstalled" "$SB/fakeroot/etc/init.d/ts-update-bootcheck"
	assert_file "config preserved" "$SB/fakeroot/etc/default/ts-update"
}

case19() {
	CASE="19 feed symlink layout"; setup; say "$CASE"
	# feed package installs tailscale as symlink to tailscaled
	rm -f "$SB/sbin/tailscale"
	ln -s tailscaled "$SB/sbin/tailscale"

	TS_TIMEOUT=120 ts run >/dev/null 2>&1
	assert "new version installed" "$(installed_version)" "$NEW"
	assert_file "symlink target saved" "$SB/backup/tailscale.link"
	assert_nofile "binary not gzipped twice" "$SB/backup/tailscale.gz"
	assert "link target preserved" "$(cat "$SB/backup/tailscale.link")" "tailscaled"
	if [ -L "$SB/sbin/tailscale" ]; then
		bad "after update target should be an actual binary"
	else
		ok "update replaced symlink with binary"
	fi

	ts rollback >/dev/null 2>&1
	if [ -L "$SB/sbin/tailscale" ]; then
		ok "rollback restored symlink"
	else
		bad "rollback left real binary instead of symlink"
	fi
	assert "link points to correct binary" "$(readlink "$SB/sbin/tailscale")" "tailscaled"
	assert "old version restored" "$(installed_version)" "$OLD"
}

case20() {
	CASE="20 low space at target location"; setup; say "$CASE"
	# df stub: target path looks full, other paths use host df
	cat > "$SB/bin/df" <<EOF
#!/bin/sh
[ "\$1" = --stub-check ] && { echo stub; exit 0; }
for a in "\$@"; do
	case "\$a" in
		"$SB/sbin"*)
			printf 'Filesystem 1K-blocks Used Available Use%%%% Mounted on\ntmpfs 16384 16384 0 100%%%% %s\n' "\$a"
			exit 0 ;;
	esac
done
exec /bin/df "\$@"
EOF
	chmod 755 "$SB/bin/df"

	if [ "$(env -i PATH="$SB/bin:/usr/bin:/bin" "$TS_SH" -c 'df --stub-check' 2>/dev/null)" != stub ]; then
		say "  skipped (shell executes own df applet overriding PATH)"
		return 0
	fi

	out="$(ts run 2>&1)"; rc=$?
	assert "exits with error" "$rc" 1
	case "$out" in *"no space in target location"*) ok "reports reason" ;;
		*) bad "unexpected output: $out" ;; esac
	assert_nofile "nothing downloaded" "$SB/tmp/tailscale_${NEW}_${ARCH}.tgz"
	assert_nofile "no backup created" "$SB/backup/tailscaled.gz"
	assert "binary not modified" "$(installed_version)" "$OLD"
	assert_file "daemon untouched" "$SB/daemon.pid"
}

case21() {
	CASE="21 clock jump does not interrupt confirmation window"; setup; say "$CASE"
	TS_TIMEOUT=60 ts run >/dev/null 2>&1
	assert "new version installed" "$(installed_version)" "$NEW"
	assert_file "monotonic deadline recorded" "$SB/state/deadline.uptime"

	# simulate 1-hour NTP forward jump: wall clock deadline passed
	echo "$(( $(date +%s) - 3600 ))" > "$SB/state/deadline"
	sleep 12
	assert "watchdog did not rollback" "$(installed_version)" "$NEW"
	assert_file "confirmation window still active" "$SB/state/deadline"

	# without monotonic counter, fallback to wall clock triggers rollback
	rm -f "$SB/state/deadline.uptime"
	i=0
	while [ "$i" -lt 30 ] && [ -f "$SB/state/deadline" ]; do sleep 1; i=$((i + 1)); done
	sleep 2
	assert "wall clock serves as fallback" "$(installed_version)" "$OLD"
}

case22() {
	CASE="22 missing work directory"; setup; say "$CASE"
	# configured path directory not created yet
	rm -rf "$SB/tmp"
	out="$(ts check 2>&1)"
	case "$out" in *"$NEW"*) ok "check creates work directory" ;;
		*) bad "check failed to recover from missing directory: $out" ;; esac
	assert_file "directory created" "$SB/tmp"

	# uncreateable directory: error must report reason
	out="$(TS_TMP_DIR=/proc/ts-update-uncreateable ts check 2>&1)"
	case "$out" in *"cannot write to working directory"*) ok "reports reason" ;;
		*) bad "unexpected output: $out" ;; esac
	case "$out" in *"FAILED TO FETCH"*) ok "check does not claim to know version" ;;
		*) bad "check reported unexpected text: $out" ;; esac

	out="$(TS_TMP_DIR=/proc/ts-update-uncreateable ts run 2>&1)"; rc=$?
	assert "run aborts" "$rc" 1
	assert "binary not modified" "$(installed_version)" "$OLD"
}

run_suite() {
	for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22; do
		want "$n" || continue
		"case$n"
	done
}

for _need in sha256sum tar gzip awk sed; do
	command -v "$_need" >/dev/null 2>&1 || { say "missing dependency: $_need"; exit 1; }
done

mkdir -p "$ROOT"

say "== suite: sed fallback path (no jsonfilter)"
USE_JSONFILTER=0
run_suite

if command -v python3 >/dev/null 2>&1; then
	say ""
	say "== suite: jsonfilter stub path"
	USE_JSONFILTER=1
	run_suite
else
	say ""
	say "(python3 missing — jsonfilter path not tested)"
fi

say ""
say "passed: $PASS, failed: $FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf '%s\n' "$FAILED"
	exit 1
fi
exit 0
