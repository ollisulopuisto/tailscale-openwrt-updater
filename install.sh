#!/bin/sh
# install.sh — copies ts-update to one or more OpenWrt devices over SSH.

set -u

usage() {
	cat <<'EOF'
install.sh — copy ts-update to one or more OpenWrt devices over SSH.

  ./install.sh root@r1 root@r2
  ./install.sh -f hosts.txt

Options:
  -f FILE     read target hosts from file (one per line, # = comment)
  -u USER     default SSH user for hosts without '@' (default: root)
  -d DIR      device-specific config directory (default: ./hosts.d). If
              DIR/<host>.env exists, it is deployed as /etc/default/ts-update.
  -e FILE     default config file for devices that lack a host-specific env file.
              Without this option, existing /etc/default/ts-update is preserved.
  -B          do not install the boot-check init script
  -n          dry-run: show what would be done without making changes

OpenWrt lacks an sftp server by default, so OpenSSH 9 scp requires -O
(legacy SCP protocol). Without it, copy fails with "subsystem request failed".
EOF
}

SRC_DIR="$(dirname "$0")"
HOSTS=""
USER_DEFAULT=root
CONF_DIR="$SRC_DIR/hosts.d"
CONF_DEFAULT=""
WITH_BOOTHOOK=1
DRY=0

die() { echo "install.sh: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
	case "$1" in
		-f) [ $# -ge 2 ] || die "-f requires a file argument"
		    [ -r "$2" ] || die "cannot read: $2"
		    HOSTS="$HOSTS $(sed 's/#.*//' "$2")"
		    shift 2 ;;
		-u) [ $# -ge 2 ] || die "-u requires a user argument"
		    USER_DEFAULT="$2"; shift 2 ;;
		-d) [ $# -ge 2 ] || die "-d requires a directory argument"
		    CONF_DIR="$2"; shift 2 ;;
		-e) [ $# -ge 2 ] || die "-e requires a file argument"
		    [ -r "$2" ] || die "cannot read: $2"
		    CONF_DEFAULT="$2"; shift 2 ;;
		-B) WITH_BOOTHOOK=0; shift ;;
		-n) DRY=1; shift ;;
		-h|--help) usage; exit 0 ;;
		-*) die "unknown option: $1" ;;
		*)  HOSTS="$HOSTS $1"; shift ;;
	esac
done

[ -n "$(echo "$HOSTS" | tr -d ' \n')" ] || die "provide at least one target host (-h for help)"
[ -r "$SRC_DIR/ts-update" ] || die "ts-update missing from directory $SRC_DIR"
[ "$WITH_BOOTHOOK" = 0 ] || [ -r "$SRC_DIR/ts-update-bootcheck.init" ] ||
	die "ts-update-bootcheck.init missing (or pass -B)"

run() {
	if [ "$DRY" = 1 ]; then
		echo "  + $*"
		return 0
	fi
	"$@"
}

fails=""
for h in $HOSTS; do
	[ -n "$h" ] || continue
	case "$h" in
		*@*) target="$h" ;;
		*)   target="$USER_DEFAULT@$h" ;;
	esac
	host="${h#*@}"

	echo "== $target"
	ok=1

	run scp -O "$SRC_DIR/ts-update" "$target:/usr/sbin/ts-update" || ok=0
	[ "$ok" = 1 ] && { run ssh "$target" 'chmod 755 /usr/sbin/ts-update' || ok=0; }

	# Device-specific config wins; without -e, device's existing
	# /etc/default/ts-update is not overwritten.
	conf=""
	if [ -r "$CONF_DIR/$host.env" ]; then
		conf="$CONF_DIR/$host.env"
	elif [ -n "$CONF_DEFAULT" ]; then
		conf="$CONF_DEFAULT"
	fi
	if [ "$ok" = 1 ] && [ -n "$conf" ]; then
		echo "   settings: $conf"
		run scp -O "$conf" "$target:/etc/default/ts-update" || ok=0
	fi

	if [ "$ok" = 1 ] && [ "$WITH_BOOTHOOK" = 1 ]; then
		run scp -O "$SRC_DIR/ts-update-bootcheck.init" \
			"$target:/etc/init.d/ts-update-bootcheck" || ok=0
		[ "$ok" = 1 ] && {
			run ssh "$target" \
				'chmod 755 /etc/init.d/ts-update-bootcheck && /etc/init.d/ts-update-bootcheck enable' || ok=0
		}
	fi

	[ "$ok" = 1 ] && { run ssh "$target" 'ts-update check' || ok=0; }

	if [ "$ok" != 1 ]; then
		echo "   FAILED: $target" >&2
		fails="$fails $target"
	fi
done

if [ -n "$fails" ]; then
	echo
	echo "failed:$fails" >&2
	exit 1
fi
echo
echo "done."
