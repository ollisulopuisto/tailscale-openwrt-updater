#!/bin/sh
# netinstall.sh — install ts-update on OpenWrt directly from GitHub.
#
# Runs on the router itself (unlike install.sh which pushes files from a
# workstation over SSH). Downloads ts-update, boot check init script, and
# default config template, verifies integrity, installs, and enables them.
#
# Recommended usage — download, inspect script, then execute:
#   URL=https://raw.githubusercontent.com/ollisulopuisto/tailscale-openwrt-updater/main/netinstall.sh
#   wget -O /tmp/netinstall.sh "$URL"   # or: curl -fsSL -o /tmp/netinstall.sh "$URL"
#   sh /tmp/netinstall.sh
#
# One-liner usage (either fetcher works):
#   wget -O- "$URL" | sh
#   curl -fsSL "$URL" | sh
#
# OpenWrt's built-in wget is uclient-fetch; that works too. The script
# automatically detects available HTTP fetchers (wget, uclient-fetch, or curl).
#
# Options:
#   -r, --ref REF        branch, tag, or commit (default: main)
#   -R, --repo OWNER/REPO target repository
#   -c, --sha256 SUM     require this sha256 checksum for ts-update
#   -p, --prefix DIR     install under prefix directory DIR (testing)
#   -w, --wget CMD       download command (wget, uclient-fetch, curl)
#   -B, --no-boot-hook   do not install boot check init script
#   -f, --force          install even if update confirmation is pending
#   -u, --uninstall      remove installation (state and backups are preserved)
#   -n, --dry-run        show what would be done without making changes
#   -h, --help           show this help text
#
# Environment: WGET=uclient-fetch overrides download command selection.

set -u

# Entire body resides in main() and is invoked on the last line.
# When run from a pipe (wget ... | sh), sh reads and executes line by line;
# an interrupted download would otherwise execute a partial script.
# With main(), a partial script does nothing: main is either completely read or not called.
main() {

	REPO="${REPO:-ollisulopuisto/tailscale-openwrt-updater}"
	REF="${REF:-main}"
	PREFIX="${PREFIX:-}"
	WGET="${WGET:-}"
	WANT_SHA=""
	WITH_BOOTHOOK=1
	FORCE=0
	DRY=0
	UNINSTALL=0

	SBIN=/usr/sbin
	INITD=/etc/init.d
	DEFAULTS=/etc/default
	STATE_DIR=/root/ts-update

	die() { echo "netinstall: $*" >&2; exit 1; }
	say() { echo "$*"; }

	usage() {
		cat <<-'EOF'
	netinstall.sh — install ts-update on OpenWrt directly from GitHub.

	Runs on the router itself (unlike install.sh which pushes files over SSH).

	  URL=https://raw.githubusercontent.com/ollisulopuisto/tailscale-openwrt-updater/main/netinstall.sh
	  wget -O /tmp/netinstall.sh "$URL"    # or: curl -fsSL -o /tmp/netinstall.sh "$URL"
	  sh /tmp/netinstall.sh

	One-liner usage:                         wget -O- "$URL" | sh
	                                         curl -fsSL "$URL" | sh

	Options:
	  -r, --ref REF        branch, tag, or commit (default: main)
	  -R, --repo OWNER/REPO target repository
	  -c, --sha256 SUM     require this sha256 checksum for ts-update
	  -p, --prefix DIR     install under prefix directory DIR (testing)
	  -w, --wget CMD       download command (wget, uclient-fetch, curl)
	  -B, --no-boot-hook   do not install boot check init script
	  -f, --force          install even if update confirmation is pending
	  -u, --uninstall      remove installation (state and backups are preserved)
	  -n, --dry-run        show what would be done without making changes
	  -h, --help           show this help text
	EOF
	}

	while [ $# -gt 0 ]; do
		case "$1" in
			-r|--ref)      [ $# -ge 2 ] || die "$1 requires a value"; REF="$2"; shift 2 ;;
			-R|--repo)     [ $# -ge 2 ] || die "$1 requires a value"; REPO="$2"; shift 2 ;;
			-c|--sha256)   [ $# -ge 2 ] || die "$1 requires a value"; WANT_SHA="$2"; shift 2 ;;
			-p|--prefix)   [ $# -ge 2 ] || die "$1 requires a value"; PREFIX="$2"; shift 2 ;;
			-w|--wget)     [ $# -ge 2 ] || die "$1 requires a value"; WGET="$2"; shift 2 ;;
			-B|--no-boot-hook) WITH_BOOTHOOK=0; shift ;;
			-f|--force)    FORCE=1; shift ;;
			-u|--uninstall) UNINSTALL=1; shift ;;
			-n|--dry-run)  DRY=1; shift ;;
			-h|--help)     usage; exit 0 ;;
			*)             die "unknown option: $1 (-h for help)" ;;
		esac
	done

	BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/$REPO/$REF}"

	run() {
		if [ "$DRY" = 1 ]; then
			echo "  + $*"
			return 0
		fi
		"$@"
	}

	# --- uninstall ----------------------------------------------------------

	if [ "$UNINSTALL" = 1 ]; then
		if [ -x "$PREFIX$INITD/ts-update-bootcheck" ] && [ -z "$PREFIX" ]; then
			run "$INITD/ts-update-bootcheck" disable 2>/dev/null || true
		fi
		run rm -f "$PREFIX$INITD/ts-update-bootcheck" "$PREFIX$SBIN/ts-update"
		say "ts-update uninstalled."
		say "Left untouched: $PREFIX$DEFAULTS/ts-update, $PREFIX$STATE_DIR, $PREFIX/root/ts-backup"
		exit 0
	fi

	# --- download command ---------------------------------------------------

	if [ -z "$WGET" ]; then
		for _c in wget uclient-fetch curl; do
			if command -v "$_c" >/dev/null 2>&1; then WGET="$_c"; break; fi
		done
	fi
	[ -n "$WGET" ] || die "no wget, uclient-fetch, or curl found"

	# curl requires different flags than wget/uclient-fetch
	fetch() {  # fetch <url> <target>
		case "$WGET" in
			*curl)  "$WGET" -fsSL -o "$2" "$1" ;;
			*)      "$WGET" -q -O "$2" "$1" ;;
		esac
	}

	# --- pending update check -----------------------------------------------

	# Installing new script during confirmation window interferes with active watchdog,
	# so it is blocked unless --force is passed.
	if [ -r "$PREFIX$DEFAULTS/ts-update" ]; then
		# shellcheck disable=SC1090  # device config file
		STATE_DIR="$(. "$PREFIX$DEFAULTS/ts-update" 2>/dev/null; echo "${STATE_DIR:-/root/ts-update}")"
	fi
	if [ "$FORCE" = 0 ] && { [ -f "$PREFIX$STATE_DIR/deadline" ] || [ -f "$PREFIX$STATE_DIR/pending" ]; }; then
		echo "netinstall: an update is still pending confirmation." >&2
		echo "  Run first: ts-update confirm  (or ts-update rollback)" >&2
		echo "  Override with --force if needed" >&2
		exit 1
	fi

	# --- download -----------------------------------------------------------

	TMP="${TMPDIR:-/tmp}/ts-update-netinstall.$$"
	cleanup() { rm -rf "$TMP"; }
	trap cleanup EXIT
	trap 'cleanup; exit 130' INT
	trap 'cleanup; exit 143' TERM
	mkdir -p "$TMP" || die "cannot create temporary directory"

	say "source: $BASE_URL"

	get() {  # get <filename>
		if ! fetch "$BASE_URL/$1" "$TMP/$1"; then
			echo "netinstall: download failed: $BASE_URL/$1" >&2
			echo "  If HTTPS fails, the device is likely missing" >&2
			echo "  ca-bundle or libustream-mbedtls (apk add ca-bundle)." >&2
			exit 1
		fi
		[ -s "$TMP/$1" ] || die "empty file: $1"
	}

	get ts-update
	get ts-update.default
	[ "$WITH_BOOTHOOK" = 1 ] && get ts-update-bootcheck.init

	# Interrupted download is detected before anything is installed:
	# last line of scripts must be end marker, and ts-update must parse cleanly.
	# Simple sh -n is insufficient since file header is comments that parse cleanly.
	complete_file() {  # complete_file <filename>
		tail -n 5 "$1" | grep -q '^# ts-update-eof$'
	}

	complete_file "$TMP/ts-update" || die "downloaded ts-update is truncated"
	sh -n "$TMP/ts-update" || die "downloaded ts-update is corrupted"
	if [ "$WITH_BOOTHOOK" = 1 ]; then
		complete_file "$TMP/ts-update-bootcheck.init" \
			|| die "downloaded ts-update-bootcheck.init is truncated"
	fi

	SUM=""
	if command -v sha256sum >/dev/null 2>&1; then
		SUM="$(sha256sum "$TMP/ts-update" | awk '{print $1}')"
	fi
	if [ -n "$WANT_SHA" ]; then
		[ -n "$SUM" ] || die "sha256sum is missing, cannot verify checksum"
		[ "$SUM" = "$WANT_SHA" ] || die "checksum mismatch: $SUM"
		say "checksum ok"
	fi

	# --- installation -------------------------------------------------------

	run mkdir -p "$PREFIX$SBIN" "$PREFIX$DEFAULTS" || die "cannot create directories"
	run cp "$TMP/ts-update" "$PREFIX$SBIN/ts-update.new" || die "copy failed"
	run chmod 755 "$PREFIX$SBIN/ts-update.new"
	run mv "$PREFIX$SBIN/ts-update.new" "$PREFIX$SBIN/ts-update" || die "installation failed"
	say "installed: $PREFIX$SBIN/ts-update"
	[ -n "$SUM" ] && say "sha256:    $SUM"

	# Config file is preserved: device-specific PEER/TIMEOUT values remain intact across updates.
	if [ -e "$PREFIX$DEFAULTS/ts-update" ]; then
		say "settings:  $PREFIX$DEFAULTS/ts-update (kept untouched)"
	else
		run cp "$TMP/ts-update.default" "$PREFIX$DEFAULTS/ts-update"
		say "settings:  $PREFIX$DEFAULTS/ts-update (new default configuration)"
	fi

	if [ "$WITH_BOOTHOOK" = 1 ]; then
		run mkdir -p "$PREFIX$INITD"
		run cp "$TMP/ts-update-bootcheck.init" "$PREFIX$INITD/ts-update-bootcheck"
		run chmod 755 "$PREFIX$INITD/ts-update-bootcheck"
		if [ -z "$PREFIX" ] && [ "$DRY" = 0 ]; then
			if "$INITD/ts-update-bootcheck" enable 2>/dev/null; then
				say "boot check: enabled"
			else
				say "boot check: installed, but enable failed —"
				say "  enable manually: $INITD/ts-update-bootcheck enable"
			fi
		else
			say "boot check: $PREFIX$INITD/ts-update-bootcheck"
		fi
	fi

	if [ -z "$PREFIX" ] && [ "$DRY" = 0 ]; then
		say ""
		"$SBIN/ts-update" check || true
		say ""
		say "Update: ts-update run   (followed by ts-update confirm)"
	fi

}

main "$@"
