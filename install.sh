#!/bin/sh
# install.sh — kopioi ts-update yhdelle tai useammalle OpenWrt-laitteelle.

set -u

usage() {
	cat <<'EOF'
install.sh — kopioi ts-update yhdelle tai useammalle OpenWrt-laitteelle.

  ./install.sh root@r1 root@r2
  ./install.sh -f hosts.txt

Valinnat:
  -f TIEDOSTO  lue hostit tiedostosta (yksi per rivi, # = kommentti)
  -u KÄYTTÄJÄ  oletuskäyttäjä hosteille joissa ei ole @-merkkiä (oletus root)
  -d HAKEMISTO laitekohtaiset asetustiedostot (oletus ./hosts.d). Jos
               HAKEMISTO/<host>.env on olemassa, se viedään laitteelle
               nimellä /etc/default/ts-update.
  -e TIEDOSTO  asetustiedosto niille laitteille, joilla ei ole omaa.
               Ilman tätä laitteen /etc/default/ts-update jätetään rauhaan.
  -B           älä asenna boottitarkistuksen init-skriptiä
  -n           näytä mitä tehtäisiin, älä tee mitään

OpenWrt:ssä ei ole sftp-serveriä, joten OpenSSH 9:n scp tarvitsee -O:n
(vanha scp-protokolla). Ilman sitä kopiointi epäonnistuu viestillä
"subsystem request failed".
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
		-f) [ $# -ge 2 ] || die "-f vaatii tiedoston"
		    [ -r "$2" ] || die "ei voi lukea: $2"
		    HOSTS="$HOSTS $(sed 's/#.*//' "$2")"
		    shift 2 ;;
		-u) [ $# -ge 2 ] || die "-u vaatii käyttäjän"
		    USER_DEFAULT="$2"; shift 2 ;;
		-d) [ $# -ge 2 ] || die "-d vaatii hakemiston"
		    CONF_DIR="$2"; shift 2 ;;
		-e) [ $# -ge 2 ] || die "-e vaatii tiedoston"
		    [ -r "$2" ] || die "ei voi lukea: $2"
		    CONF_DEFAULT="$2"; shift 2 ;;
		-B) WITH_BOOTHOOK=0; shift ;;
		-n) DRY=1; shift ;;
		-h|--help) usage; exit 0 ;;
		-*) die "tuntematon valitsin: $1" ;;
		*)  HOSTS="$HOSTS $1"; shift ;;
	esac
done

[ -n "$(echo "$HOSTS" | tr -d ' \n')" ] || die "anna vähintään yksi host (-h = ohje)"
[ -r "$SRC_DIR/ts-update" ] || die "ts-update puuttuu hakemistosta $SRC_DIR"
[ "$WITH_BOOTHOOK" = 0 ] || [ -r "$SRC_DIR/ts-update-bootcheck.init" ] ||
	die "ts-update-bootcheck.init puuttuu (tai käytä -B)"

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

	# Laitekohtainen asetustiedosto voittaa; ilman -e:tä laitteen omaa
	# /etc/default/ts-update ei ylikirjoiteta.
	conf=""
	if [ -r "$CONF_DIR/$host.env" ]; then
		conf="$CONF_DIR/$host.env"
	elif [ -n "$CONF_DEFAULT" ]; then
		conf="$CONF_DEFAULT"
	fi
	if [ "$ok" = 1 ] && [ -n "$conf" ]; then
		echo "   asetukset: $conf"
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
		echo "   EPÄONNISTUI: $target" >&2
		fails="$fails $target"
	fi
done

if [ -n "$fails" ]; then
	echo
	echo "epäonnistui:$fails" >&2
	exit 1
fi
echo
echo "valmis."
