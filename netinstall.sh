#!/bin/sh
# netinstall.sh — asenna ts-update OpenWrt-laitteelle suoraan GitHubista.
#
# Ajetaan laitteella itsellään (vrt. install.sh, joka työntää tiedostot
# työasemalta ssh:n yli). Hakee ts-updaten, boottitarkistuksen ja
# asetusmallin, tarkistaa että ne ovat ehjiä, asentaa ja ottaa käyttöön.
#
# Suositeltu tapa — lataa, katso mitä ajat, aja sitten:
#   URL=https://raw.githubusercontent.com/ollisulopuisto/tailscale-openwrt-updater/main/netinstall.sh
#   wget -O /tmp/netinstall.sh "$URL"   # tai: curl -fsSL -o /tmp/netinstall.sh "$URL"
#   sh /tmp/netinstall.sh
#
# Yhdellä rivillä, jos luotat lähteeseen (kumpi tahansa käy):
#   wget -O- "$URL" | sh
#   curl -fsSL "$URL" | sh
#
# OpenWrt:n oma wget on uclient-fetch; sekin kelpaa. Skripti tunnistaa
# itse, kumpi laitteelta löytyy (wget, uclient-fetch tai curl).
#
# Valinnat:
#   -r, --ref REF        haara, tagi tai commit (oletus main)
#   -R, --repo OMISTAJA/REPO
#   -c, --sha256 SUMMA   vaadi tämä sha256 ts-updatelle
#   -p, --prefix DIR     asenna hakemiston DIR alle (testaus)
#   -w, --wget KOMENTO   latauskomento (wget, uclient-fetch, curl)
#   -B, --no-boot-hook   älä asenna boottitarkistusta
#   -f, --force          asenna vaikka päivitys odottaisi vahvistusta
#   -u, --uninstall      poista asennus (tila ja varmuuskopiot jäävät)
#   -n, --dry-run        näytä mitä tehtäisiin
#   -h, --help           tämä ohje
#
# Ympäristö: WGET=uclient-fetch valitsee latauskomennon.

set -u

# Koko runko on main()-funktiossa ja se kutsutaan vasta viimeisellä
# rivillä. Kun skripti ajetaan putkesta (wget ... | sh), sh lukee ja
# suorittaa sitä palanen kerrallaan — kesken katkennut lataus ajaisi
# puolikkaan skriptin. Näin puolikas ei tee mitään: main on joko
# kokonaan luettu tai sitä ei kutsuta lainkaan.
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
	netinstall.sh — asenna ts-update OpenWrt-laitteelle suoraan GitHubista.

	Ajetaan laitteella itsellään (vrt. install.sh, joka työntää tiedostot
	työasemalta ssh:n yli).

	  URL=https://raw.githubusercontent.com/ollisulopuisto/tailscale-openwrt-updater/main/netinstall.sh
	  wget -O /tmp/netinstall.sh "$URL"    # tai: curl -fsSL -o /tmp/netinstall.sh "$URL"
	  sh /tmp/netinstall.sh

	Yhdellä rivillä, jos luotat lähteeseen:  wget -O- "$URL" | sh
	                                         curl -fsSL "$URL" | sh

	Valinnat:
	  -r, --ref REF        haara, tagi tai commit (oletus main)
	  -R, --repo OMISTAJA/REPO
	  -c, --sha256 SUMMA   vaadi tämä sha256 ts-updatelle
	  -p, --prefix DIR     asenna hakemiston DIR alle (testaus)
	  -w, --wget KOMENTO   latauskomento (wget, uclient-fetch, curl)
	  -B, --no-boot-hook   älä asenna boottitarkistusta
	  -f, --force          asenna vaikka päivitys odottaisi vahvistusta
	  -u, --uninstall      poista asennus (tila ja varmuuskopiot jäävät)
	  -n, --dry-run        näytä mitä tehtäisiin
	  -h, --help           tämä ohje
	EOF
	}

	while [ $# -gt 0 ]; do
		case "$1" in
			-r|--ref)      [ $# -ge 2 ] || die "$1 vaatii arvon"; REF="$2"; shift 2 ;;
			-R|--repo)     [ $# -ge 2 ] || die "$1 vaatii arvon"; REPO="$2"; shift 2 ;;
			-c|--sha256)   [ $# -ge 2 ] || die "$1 vaatii arvon"; WANT_SHA="$2"; shift 2 ;;
			-p|--prefix)   [ $# -ge 2 ] || die "$1 vaatii arvon"; PREFIX="$2"; shift 2 ;;
			-w|--wget)     [ $# -ge 2 ] || die "$1 vaatii arvon"; WGET="$2"; shift 2 ;;
			-B|--no-boot-hook) WITH_BOOTHOOK=0; shift ;;
			-f|--force)    FORCE=1; shift ;;
			-u|--uninstall) UNINSTALL=1; shift ;;
			-n|--dry-run)  DRY=1; shift ;;
			-h|--help)     usage; exit 0 ;;
			*)             die "tuntematon valitsin: $1 (-h = ohje)" ;;
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

	# --- poisto -------------------------------------------------------------

	if [ "$UNINSTALL" = 1 ]; then
		if [ -x "$PREFIX$INITD/ts-update-bootcheck" ] && [ -z "$PREFIX" ]; then
			run "$INITD/ts-update-bootcheck" disable 2>/dev/null || true
		fi
		run rm -f "$PREFIX$INITD/ts-update-bootcheck" "$PREFIX$SBIN/ts-update"
		say "ts-update poistettu."
		say "Jätettiin ennalleen: $PREFIX$DEFAULTS/ts-update, $PREFIX$STATE_DIR, $PREFIX/root/ts-backup"
		exit 0
	fi

	# --- latauskomento ------------------------------------------------------

	if [ -z "$WGET" ]; then
		for _c in wget uclient-fetch curl; do
			if command -v "$_c" >/dev/null 2>&1; then WGET="$_c"; break; fi
		done
	fi
	[ -n "$WGET" ] || die "ei löytynyt wgetiä, uclient-fetchiä eikä curlia"

	# curl tarvitsee eri valitsimet kuin wget/uclient-fetch
	fetch() {  # fetch <url> <kohde>
		case "$WGET" in
			*curl)  "$WGET" -fsSL -o "$2" "$1" ;;
			*)      "$WGET" -q -O "$2" "$1" ;;
		esac
	}

	# --- odottava päivitys --------------------------------------------------

	# Uuden skriptin asentaminen kesken vahvistusikkunan sotkisi käynnissä
	# olevan vahdin, joten se estetään ilman --forcea.
	if [ -r "$PREFIX$DEFAULTS/ts-update" ]; then
		# shellcheck disable=SC1090  # laitteen oma asetustiedosto
		STATE_DIR="$(. "$PREFIX$DEFAULTS/ts-update" 2>/dev/null; echo "${STATE_DIR:-/root/ts-update}")"
	fi
	if [ "$FORCE" = 0 ] && { [ -f "$PREFIX$STATE_DIR/deadline" ] || [ -f "$PREFIX$STATE_DIR/pending" ]; }; then
		echo "netinstall: päivitys odottaa yhä vahvistusta." >&2
		echo "  Aja ensin: ts-update confirm  (tai ts-update rollback)" >&2
		echo "  Ohita tämä tarvittaessa: --force" >&2
		exit 1
	fi

	# --- lataus -------------------------------------------------------------

	TMP="${TMPDIR:-/tmp}/ts-update-netinstall.$$"
	cleanup() { rm -rf "$TMP"; }
	trap cleanup EXIT
	trap 'cleanup; exit 130' INT
	trap 'cleanup; exit 143' TERM
	mkdir -p "$TMP" || die "väliaikaishakemistoa ei voi luoda"

	say "lähde: $BASE_URL"

	get() {  # get <tiedosto>
		if ! fetch "$BASE_URL/$1" "$TMP/$1"; then
			echo "netinstall: lataus epäonnistui: $BASE_URL/$1" >&2
			echo "  Jos HTTPS ei toimi, laitteesta puuttuu todennäköisesti" >&2
			echo "  ca-bundle tai libustream-mbedtls (apk add ca-bundle)." >&2
			exit 1
		fi
		[ -s "$TMP/$1" ] || die "tyhjä tiedosto: $1"
	}

	get ts-update
	get ts-update.default
	[ "$WITH_BOOTHOOK" = 1 ] && get ts-update-bootcheck.init

	# Katkennut lataus huomataan ennen kuin mitään on asennettu: skriptien
	# viimeinen rivi on loppumerkki, ja ts-updaten pitää myös jäsentyä.
	# Pelkkä sh -n ei riitä — tiedoston alkuosa on kommenttia, joka menee
	# syntaksitarkistuksesta läpi sellaisenaan.
	complete_file() {  # complete_file <tiedosto>
		tail -n 5 "$1" | grep -q '^# ts-update-eof$'
	}

	complete_file "$TMP/ts-update" || die "ladattu ts-update on katkennut"
	sh -n "$TMP/ts-update" || die "ladattu ts-update ei ole ehjä"
	if [ "$WITH_BOOTHOOK" = 1 ]; then
		complete_file "$TMP/ts-update-bootcheck.init" \
			|| die "ladattu ts-update-bootcheck.init on katkennut"
	fi

	SUM=""
	if command -v sha256sum >/dev/null 2>&1; then
		SUM="$(sha256sum "$TMP/ts-update" | awk '{print $1}')"
	fi
	if [ -n "$WANT_SHA" ]; then
		[ -n "$SUM" ] || die "sha256sum puuttuu, tarkistussummaa ei voi varmistaa"
		[ "$SUM" = "$WANT_SHA" ] || die "tarkistussumma ei täsmää: $SUM"
		say "tarkistussumma ok"
	fi

	# --- asennus ------------------------------------------------------------

	run mkdir -p "$PREFIX$SBIN" "$PREFIX$DEFAULTS" || die "hakemistoja ei voi luoda"
	run cp "$TMP/ts-update" "$PREFIX$SBIN/ts-update.new" || die "kopiointi epäonnistui"
	run chmod 755 "$PREFIX$SBIN/ts-update.new"
	run mv "$PREFIX$SBIN/ts-update.new" "$PREFIX$SBIN/ts-update" || die "asennus epäonnistui"
	say "asennettu: $PREFIX$SBIN/ts-update"
	[ -n "$SUM" ] && say "sha256:    $SUM"

	# Asetustiedostoa ei ylikirjoiteta: laitekohtaiset PEER/TIMEOUT-arvot
	# säilyvät päivityksen yli.
	if [ -e "$PREFIX$DEFAULTS/ts-update" ]; then
		say "asetukset:  $PREFIX$DEFAULTS/ts-update (säilytettiin ennallaan)"
	else
		run cp "$TMP/ts-update.default" "$PREFIX$DEFAULTS/ts-update"
		say "asetukset:  $PREFIX$DEFAULTS/ts-update (uusi, malliarvot)"
	fi

	if [ "$WITH_BOOTHOOK" = 1 ]; then
		run mkdir -p "$PREFIX$INITD"
		run cp "$TMP/ts-update-bootcheck.init" "$PREFIX$INITD/ts-update-bootcheck"
		run chmod 755 "$PREFIX$INITD/ts-update-bootcheck"
		if [ -z "$PREFIX" ] && [ "$DRY" = 0 ]; then
			if "$INITD/ts-update-bootcheck" enable 2>/dev/null; then
				say "boottitarkistus: käytössä"
			else
				say "boottitarkistus: asennettu, mutta enable epäonnistui —"
				say "  ota käyttöön käsin: $INITD/ts-update-bootcheck enable"
			fi
		else
			say "boottitarkistus: $PREFIX$INITD/ts-update-bootcheck"
		fi
	fi

	if [ -z "$PREFIX" ] && [ "$DRY" = 0 ]; then
		say ""
		"$SBIN/ts-update" check || true
		say ""
		say "Päivitys: ts-update run   (ja sen jälkeen ts-update confirm)"
	fi

}

main "$@"
