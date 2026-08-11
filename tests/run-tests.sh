#!/bin/sh
# run-tests.sh — ajaa TODO:n testimatriisin hiekkalaatikossa.
#
# Mitään oikeaa ei kosketa: ts-update ohjataan ympäristömuuttujilla
# (STATE_DIR, BACKUP_DIR, SBIN_DIR, INIT_SCRIPT, TMP_DIR, BASE_URL)
# tilapäiseen hakemistoon, ja tailscale, init-skripti ja wget ovat
# tynkiä. "Binäärit" ovat sh-skriptejä, jotka tulostavat versionsa.
#
#   ./tests/run-tests.sh          aja kaikki
#   ./tests/run-tests.sh 5 6      aja vain testit 5 ja 6
#
# Suite ajetaan kahdesti, jos python3 löytyy: kerran ilman jsonfilteriä
# (sed-varapolku) ja kerran jsonfilter-tyngän kanssa. TS_SH valitsee
# kuoren, jolla ts-update ajetaan (oletus sh).

# shellcheck disable=SC2317  # apurit ja testitapaukset kutsutaan epäsuorasti
set -u

SRC="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$SRC/ts-update"
WANT="$*"
# Kuori, jolla ts-update ajetaan. OpenWrt:llä se on busybox ash, joten
# CI ajaa suiten sekä dashilla että busyboxilla.
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

assert()      { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (odotettu '$3', saatiin '$2')"; fi; }
assert_file() { if [ -e "$2" ]; then ok "$1"; else bad "$1 (puuttuu: $2)"; fi; }
assert_nofile() { if [ ! -e "$2" ]; then ok "$1"; else bad "$1 (ei pitäisi olla: $2)"; fi; }

# --- hiekkalaatikko -----------------------------------------------------

# fake_binary <tiedosto> <versio> [BROKEN]
fake_binary() {
	cat > "$1" <<EOF
#!/bin/sh
# tynkä-tailscale $2 ${3:-}
V="$2"
STATE="$SB"
case "\$1 \${2:-}" in
	"version "*)
		echo "\$V"
		echo "  go version: tynkä"
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
		echo "tynkä status \$V"
		;;
	*) echo "tynkä: tuntematon komento: \$*" >&2; exit 1 ;;
esac
EOF
	chmod 755 "$1"
}

make_tarball() {  # make_tarball <versio> <arch> [BROKEN]
	_v="$1"; _a="$2"; _b="${3:-}"
	_d="$SB/build/tailscale_${_v}_${_a}"
	mkdir -p "$_d"
	fake_binary "$_d/tailscale" "$_v" "$_b"
	fake_binary "$_d/tailscaled" "$_v" "$_b"
	(cd "$SB/build" && tar czf "$SB/www/tailscale_${_v}_${_a}.tgz" "tailscale_${_v}_${_a}")
	sha256sum "$SB/www/tailscale_${_v}_${_a}.tgz" | awk '{print $1}' \
		> "$SB/www/tailscale_${_v}_${_a}.tgz.sha256"
}

write_json() {  # write_json <TarballsVersion> <arkkitehtuurit...>
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

setup() {  # setup [nykyinen versio]
	_cur="${1:-$OLD}"
	SB="$ROOT/case${CASE%% *}"
	rm -rf "$SB"
	mkdir -p "$SB/bin" "$SB/sbin" "$SB/state" "$SB/backup" "$SB/tmp" "$SB/www" "$SB/build"

	printf '{"AdvertiseRoutes":["192.168.1.0/24"],"WantRunning":true}\n' > "$SB/prefs.json"

	fake_binary "$SB/sbin/tailscale" "$_cur"
	fake_binary "$SB/sbin/tailscaled" "$_cur"
	touch "$SB/daemon.pid"

	# init-tynkä: käynnistyy vain jos tailscaled ei ole rikki
	cat > "$SB/bin/init-tailscale" <<EOF
#!/bin/sh
case "\$1" in
	stop)  rm -f "$SB/daemon.pid" ;;
	start) grep -q BROKEN "$SB/sbin/tailscaled" || touch "$SB/daemon.pid" ;;
esac
exit 0
EOF
	chmod 755 "$SB/bin/init-tailscale"

	# wget-tynkä: tarjoilee $SB/www:sta, kaatuu jos $SB/netdown on olemassa.
	# Annetaan ts-updatelle WGET-muuttujana, koska busybox sh voi olla
	# käännetty standalone-tilaan, jolloin PATH-tynkä ei näkyisi.
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
		PATH="$SB/bin:$SB/sbin:/usr/bin:/bin" \
		HOME="$SB" \
		CONFIG_FILE=/dev/null \
		STATE_DIR="$SB/state" \
		BACKUP_DIR="$SB/backup" \
		SBIN_DIR="$SB/sbin" \
		INIT_SCRIPT="$SB/bin/init-tailscale" \
		LOCK_FILE="$SB/lock" \
		TMP_DIR="$SB/tmp" \
		BASE_URL="http://tynkä/stable" \
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

# --- testit -------------------------------------------------------------

case1() {
	CASE="1 jo uusin versio"; setup "$NEW"; say "$CASE"
	out="$(ts run 2>&1)"; rc=$?
	assert "poistuu koodilla 0" "$rc" 0
	case "$out" in *"Jo uusin"*) ok "kertoo olevansa ajan tasalla" ;;
		*) bad "väärä viesti: $out" ;; esac
	assert_nofile "ei varmuuskopiota" "$SB/backup/tailscaled.gz"
	assert_nofile "ei odottavaa päivitystä" "$SB/state/deadline"
}

case2() {
	CASE="2 verkko poikki kesken latauksen"; setup; say "$CASE"
	rm -f "$SB/www/tailscale_${NEW}_${ARCH}.tgz"
	out="$(ts run 2>&1)"; rc=$?
	assert "poistuu virheellä" "$rc" 1
	case "$out" in *"lataus epäonnistui"*) ok "kertoo latausvirheestä" ;;
		*) bad "väärä viesti: $out" ;; esac
	assert_nofile "ei varmuuskopiota" "$SB/backup/tailscaled.gz"
	assert "binääriä ei vaihdettu" "$(installed_version)" "$OLD"
	assert_file "daemon jätettiin rauhaan" "$SB/daemon.pid"
}

case3() {
	CASE="3 tarkistussumma ei täsmää"; setup; say "$CASE"
	echo "0000000000000000000000000000000000000000000000000000000000000000" \
		> "$SB/www/tailscale_${NEW}_${ARCH}.tgz.sha256"
	out="$(ts run 2>&1)"; rc=$?
	assert "poistuu virheellä" "$rc" 1
	case "$out" in *"tarkistussumma ei täsmää"*) ok "kertoo summavirheestä" ;;
		*) bad "väärä viesti: $out" ;; esac
	assert_nofile "lataus siivottiin" "$SB/tmp/tailscale_${NEW}_${ARCH}.tgz"
	assert "binääriä ei vaihdettu" "$(installed_version)" "$OLD"
}

case4() {
	CASE="4 uusi binääri ei nouse"; setup; say "$CASE"
	make_tarball "$NEW" "$ARCH" BROKEN
	out="$(ts run 2>&1)"; rc=$?
	assert "poistuu virheellä" "$rc" 1
	case "$out" in *"palautetaan"*) ok "tekee rollbackin odottamatta" ;;
		*) bad "väärä viesti: $out" ;; esac
	assert "vanha versio takaisin" "$(installed_version)" "$OLD"
	assert_file "daemon pystyssä" "$SB/daemon.pid"
	assert_nofile "ei jää odottamaan vahvistusta" "$SB/state/deadline"
}

case5() {
	CASE="5 vahvistus ajoissa"; setup; say "$CASE"
	TS_TIMEOUT=60 ts run >/dev/null 2>&1
	assert "uusi versio asennettu" "$(installed_version)" "$NEW"
	assert_file "vahti viritetty" "$SB/state/deadline"
	pid="$(cat "$SB/state/watchdog.pid")"
	ts confirm >/dev/null 2>&1
	sleep 8   # pidempi kuin vahdin pollausväli
	if kill -0 "$pid" 2>/dev/null; then bad "vahti jäi henkiin"; else ok "vahti kuoli"; fi
	assert_nofile "määräaika poistettu" "$SB/state/deadline"
	assert "uusi versio jäi voimaan" "$(installed_version)" "$NEW"
}

case6() {
	CASE="6 ei vahvistusta"; setup; say "$CASE"
	TS_TIMEOUT=5 ts run >/dev/null 2>&1
	assert "uusi versio asennettu" "$(installed_version)" "$NEW"
	i=0
	while [ "$i" -lt 30 ] && [ -f "$SB/state/deadline" ]; do sleep 1; i=$((i + 1)); done
	sleep 2
	assert "rollback määräajan jälkeen" "$(installed_version)" "$OLD"
	assert_file "daemon pystyssä rollbackin jälkeen" "$SB/daemon.pid"
	assert_nofile "tila siivottu" "$SB/state/deadline"
}

case7() {
	CASE="7 kuivaharjoitus"; setup; say "$CASE"
	out="$(ts run --dry-run 2>&1)"; rc=$?
	assert "poistuu koodilla 0" "$rc" 0
	case "$out" in *"Kuivaharjoitus valmis"*) ok "kertoo tuloksen" ;;
		*) bad "väärä viesti: $out" ;; esac
	assert "binääriä ei vaihdettu" "$(installed_version)" "$OLD"
	assert_file "daemonia ei pysäytetty" "$SB/daemon.pid"
	assert_nofile "ei varmuuskopiota" "$SB/backup/tailscaled.gz"
	assert_nofile "ei odottavaa päivitystä" "$SB/state/deadline"
	assert_nofile "väliaikaistiedostot siivottu" "$SB/tmp/tailscale_${NEW}_${ARCH}.tgz"
}

case8() {
	CASE="8 arkkitehtuuria ei ole palvelimella"; setup; say "$CASE"
	write_json "$NEW" amd64 mipsle
	out="$(ts run 2>&1)"; rc=$?
	assert "poistuu virheellä" "$rc" 1
	case "$out" in *"ei ole pakettia"*) ok "kertoo puuttuvasta paketista" ;;
		*) bad "väärä viesti: $out" ;; esac
	case "$out" in *"amd64"*) ok "listaa saatavilla olevat" ;;
		*) bad "ei listaa vaihtoehtoja: $out" ;; esac
	assert_nofile "mitään ei ladattu" "$SB/tmp/tailscale_${NEW}_${ARCH}.tgz"
	assert "binääriä ei vaihdettu" "$(installed_version)" "$OLD"
}

case9() {
	CASE="9 lukitus"; say "$CASE"
	if ! command -v flock >/dev/null 2>&1; then
		say "  ohitettu (flock puuttuu tästä koneesta)"
		return 0
	fi
	setup
	# pidetään lukkoa toisesta prosessista
	sh -c "exec 9>\"$SB/lock\"; flock 9; sleep 6" &
	holder=$!
	sleep 1
	out="$(ts run 2>&1)"; rc=$?
	assert "toinen ajo torjutaan" "$rc" 1
	case "$out" in *"Toinen ts-update-ajo"*) ok "kertoo syyn" ;;
		*) bad "väärä viesti: $out" ;; esac
	assert "binääriä ei vaihdettu" "$(installed_version)" "$OLD"
	kill "$holder" 2>/dev/null
	wait "$holder" 2>/dev/null
}

case10() {
	CASE="10 feed-versio ei näytä uudemmalta"; setup "1.98.3-1 (OpenWrt)"; say "$CASE"
	write_json 1.98.3 "$ARCH"
	out="$(ts run 2>&1)"; rc=$?
	assert "poistuu koodilla 0" "$rc" 0
	case "$out" in *"Jo uusin"*) ok "normalisoi versiovertailun" ;;
		*) bad "väärä viesti: $out" ;; esac
	assert_nofile "ei odottavaa päivitystä" "$SB/state/deadline"
}

case11() {
	CASE="11 boottaus vahvistusikkunassa, daemon kunnossa"; setup; say "$CASE"
	TS_TIMEOUT=120 ts run >/dev/null 2>&1
	# simuloi boottia: vahti tapetaan, tila jää levylle
	kill "$(cat "$SB/state/watchdog.pid")" 2>/dev/null
	sleep 1
	assert_file "määräaika säilyi levyllä" "$SB/state/deadline"
	# määräaika hyvin lähelle nykyhetkeä, jotta rollback ehtii testin aikana
	echo "$(( $(date +%s) + 5 ))" > "$SB/state/deadline"
	TS_TIMEOUT=120 ts boot-check >/dev/null 2>&1
	assert_file "vahti viritetty uudelleen" "$SB/state/watchdog.pid"
	i=0
	while [ "$i" -lt 30 ] && [ -f "$SB/state/deadline" ]; do sleep 1; i=$((i + 1)); done
	sleep 2
	assert "rollback tapahtui boottauksen jälkeenkin" "$(installed_version)" "$OLD"
}

case12() {
	CASE="12 boottaus vahvistusikkunassa, daemon rikki"; setup; say "$CASE"
	TS_TIMEOUT=120 ts run >/dev/null 2>&1
	kill "$(cat "$SB/state/watchdog.pid")" 2>/dev/null
	sleep 1
	rm -f "$SB/daemon.pid"          # daemon ei noussut boottauksessa
	sed -i 's/^# tynkä-tailscale.*/# tynkä-tailscale BROKEN/' "$SB/sbin/tailscaled"
	out="$(TS_TIMEOUT=120 ts boot-check 2>&1)"
	case "$out" in *"palautetaan"*) ok "boot-check tekee rollbackin" ;;
		*) bad "väärä viesti: $out" ;; esac
	assert "vanha versio takaisin" "$(installed_version)" "$OLD"
	assert_nofile "tila siivottu" "$SB/state/deadline"
}

case13() {
	CASE="13 mainostetut reitit katoavat"; setup; say "$CASE"
	# uusi versio "unohtaa" reitit: prefs tyhjennetään kun uusi daemon nousee
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
	assert "poistuu virheellä" "$rc" 1
	case "$out" in *"mainostetut reitit"*) ok "huomaa kadonneet reitit" ;;
		*) bad "väärä viesti: $out" ;; esac
	assert "vanha versio takaisin" "$(installed_version)" "$OLD"
}

case14() {
	CASE="14 status ja check"; setup; say "$CASE"
	out="$(ts check 2>&1)"
	case "$out" in *"$NEW"*) ok "check näyttää uusimman" ;;
		*) bad "check ei näytä uusinta: $out" ;; esac
	case "$out" in *"tailscale_${NEW}_${ARCH}.tgz"*) ok "check vahvistaa paketin olemassaolon" ;;
		*) bad "check ei tarkista pakettia: $out" ;; esac
	out="$(ts status 2>&1)"
	case "$out" in *"ei odottavaa päivitystä"*) ok "status: ei odottavaa" ;;
		*) bad "status väärin: $out" ;; esac
	TS_TIMEOUT=60 ts run >/dev/null 2>&1
	out="$(ts status 2>&1)"
	case "$out" in *"ODOTTAA VAHVISTUSTA"*) ok "status: odottaa vahvistusta" ;;
		*) bad "status väärin: $out" ;; esac
	case "$out" in *"vahti:         käynnissä"*) ok "status: vahti käynnissä" ;;
		*) bad "status ei näe vahtia: $out" ;; esac
	ts confirm >/dev/null 2>&1
}

case15() {
	CASE="15 boottaus binäärinvaihdon ja vahdin virityksen välissä"; setup; say "$CASE"
	TS_TIMEOUT=120 ts run >/dev/null 2>&1
	# simuloi: vahti ja määräaika eivät ehtineet levylle, vain pending
	kill "$(cat "$SB/state/watchdog.pid")" 2>/dev/null
	rm -f "$SB/state/deadline" "$SB/state/watchdog.pid"
	sleep 1
	assert_file "odottava päivitys tiedossa" "$SB/state/pending"
	out="$(ts status 2>&1)"
	case "$out" in *"jäi ilman vahtia"*) ok "status kertoo keskeneräisyydestä" ;;
		*) bad "status ei huomaa: $out" ;; esac
	out="$(TS_TIMEOUT=120 ts boot-check 2>&1)"
	case "$out" in *"keskeytyi ennen vahdin viritystä"*) ok "boot-check tunnistaa tilanteen" ;;
		*) bad "väärä viesti: $out" ;; esac
	assert "vanha versio takaisin" "$(installed_version)" "$OLD"
	assert_nofile "tila siivottu" "$SB/state/pending"
}

case16() {
	CASE="16 vahvistus samaan aikaan kun vahti palauttaa"; setup; say "$CASE"
	TS_TIMEOUT=5 ts run >/dev/null 2>&1
	assert "uusi versio asennettu" "$(installed_version)" "$NEW"
	# odota kunnes vahti on tehnyt rollbackin, vahvista vasta sitten
	i=0
	while [ "$i" -lt 30 ] && [ -f "$SB/state/deadline" ]; do sleep 1; i=$((i + 1)); done
	sleep 3
	out="$(ts confirm 2>&1)"; rc=$?
	assert "confirm ei valehtele onnistumisesta" "$rc" 0
	case "$out" in *"Mitään ei odota vahvistusta"*|*"rollback ehti tapahtua"*)
			ok "confirm kertoo todellisen tilan" ;;
		*) bad "väärä viesti: $out" ;; esac
	assert "vanha versio voimassa" "$(installed_version)" "$OLD"
}

case17() {
	CASE="17 vanhentunut watchdog.pid ei johda vieraan prosessin tappoon"; setup; say "$CASE"
	TS_TIMEOUT=120 ts run >/dev/null 2>&1
	kill "$(cat "$SB/state/watchdog.pid")" 2>/dev/null
	sleep 1
	# boottauksen jälkeen PID viittaa johonkin aivan muuhun prosessiin
	sleep 300 &
	victim=$!
	echo "$victim" > "$SB/state/watchdog.pid"
	out="$(ts status 2>&1)"
	case "$out" in *"vahti:         EI KÄYNNISSÄ"*) ok "status ei usko vierasta PID:iä vahdiksi" ;;
		*) bad "status luuli vahtia eläväksi: $out" ;; esac
	ts confirm >/dev/null 2>&1
	sleep 1
	if kill -0 "$victim" 2>/dev/null; then ok "vieras prosessi jäi henkiin"; else bad "disarm tappoi väärän prosessin"; fi
	kill "$victim" 2>/dev/null
	wait "$victim" 2>/dev/null
}

# netinstall.sh ajetaan tyngällä latauskomennolla ja hiekkalaatikkoon
# --prefixillä: mitään ei haeta verkosta eikä asenneta oikeaan juureen.
netinstall() {
	env -i \
		PATH="$SB/bin:/usr/bin:/bin" \
		HOME="$SB" \
		BASE_URL="http://tynkä/repo" \
		sh "$SRC/netinstall.sh" --prefix "$SB/fakeroot" -w "$SB/bin/wget" "$@"
}

case18() {
	CASE="18 netinstall GitHubista"; setup; say "$CASE"
	cp "$SRC/ts-update" "$SRC/ts-update.default" "$SRC/ts-update-bootcheck.init" "$SB/www/"

	out="$(netinstall 2>&1)"; rc=$?
	assert "asennus onnistuu" "$rc" 0
	assert_file "ts-update paikallaan" "$SB/fakeroot/usr/sbin/ts-update"
	if [ -x "$SB/fakeroot/usr/sbin/ts-update" ]; then ok "ts-update on ajettava"; else bad "ei ajo-oikeutta"; fi
	assert_file "boottitarkistus paikallaan" "$SB/fakeroot/etc/init.d/ts-update-bootcheck"
	assert_file "asetustiedosto luotiin" "$SB/fakeroot/etc/default/ts-update"
	case "$out" in *sha256*) ok "kertoo tarkistussumman" ;; *) bad "ei summaa: $out" ;; esac

	# laitekohtaiset asetukset eivät saa hävitä uudelleenasennuksessa
	echo "PEER=100.64.0.1" >> "$SB/fakeroot/etc/default/ts-update"
	netinstall >/dev/null 2>&1
	if grep -q '^PEER=100.64.0.1' "$SB/fakeroot/etc/default/ts-update"; then
		ok "asetuksia ei ylikirjoiteta"
	else
		bad "asetustiedosto ylikirjoitettiin"
	fi

	# oikea tarkistussumma kelpaa, väärä ei
	sum="$(sha256sum "$SRC/ts-update" | awk '{print $1}')"
	netinstall -c "$sum" >/dev/null 2>&1
	assert "oikea tarkistussumma kelpaa" "$?" 0
	out="$(netinstall -c 0000000000000000000000000000000000000000000000000000000000000000 2>&1)"; rc=$?
	assert "väärä tarkistussumma torjutaan" "$rc" 1
	case "$out" in *"ei täsmää"*) ok "kertoo summavirheestä" ;; *) bad "väärä viesti: $out" ;; esac

	# odottava päivitys estää asennuksen ilman --forcea
	mkdir -p "$SB/fakeroot/root/ts-update"
	echo "1.98.3 -> 1.100.0" > "$SB/fakeroot/root/ts-update/pending"
	out="$(netinstall 2>&1)"; rc=$?
	assert "odottava päivitys estää asennuksen" "$rc" 1
	case "$out" in *"odottaa yhä vahvistusta"*) ok "kertoo syyn" ;; *) bad "väärä viesti: $out" ;; esac
	netinstall --force >/dev/null 2>&1
	assert "--force ohittaa eston" "$?" 0
	rm -f "$SB/fakeroot/root/ts-update/pending"

	# katkennut lataus ei saa päätyä asennukseen
	cp "$SB/fakeroot/usr/sbin/ts-update" "$SB/ts-update.ehja"
	head -c 400 "$SRC/ts-update" > "$SB/www/ts-update"
	out="$(netinstall 2>&1)"; rc=$?
	assert "kommenttiotsakkeeseen katkennut lataus torjutaan" "$rc" 1
	case "$out" in *katkennut*) ok "kertoo syyn" ;; *) bad "väärä viesti: $out" ;; esac
	head -c 9000 "$SRC/ts-update" > "$SB/www/ts-update"
	out="$(netinstall 2>&1)"; rc=$?
	assert "keskeltä katkennut lataus torjutaan" "$rc" 1
	if cmp -s "$SB/ts-update.ehja" "$SB/fakeroot/usr/sbin/ts-update"; then
		ok "vanha versio jäi koskematta"
	else
		bad "rikkinäinen versio asennettiin"
	fi

	# poisto jättää asetukset ja tilan rauhaan
	netinstall --uninstall >/dev/null 2>&1
	assert_nofile "ts-update poistettu" "$SB/fakeroot/usr/sbin/ts-update"
	assert_nofile "boottitarkistus poistettu" "$SB/fakeroot/etc/init.d/ts-update-bootcheck"
	assert_file "asetukset jäivät" "$SB/fakeroot/etc/default/ts-update"
}

case19() {
	CASE="19 feedin symlink-asettelu"; setup; say "$CASE"
	# feedin paketti asentaa tailscalen symlinkkinä tailscalediin
	rm -f "$SB/sbin/tailscale"
	ln -s tailscaled "$SB/sbin/tailscale"

	TS_TIMEOUT=120 ts run >/dev/null 2>&1
	assert "uusi versio asennettu" "$(installed_version)" "$NEW"
	assert_file "symlinkki tallennettiin linkkinä" "$SB/backup/tailscale.link"
	assert_nofile "samaa binääriä ei pakattu kahdesti" "$SB/backup/tailscale.gz"
	assert "linkin kohde talteen" "$(cat "$SB/backup/tailscale.link")" "tailscaled"
	if [ -L "$SB/sbin/tailscale" ]; then
		bad "päivityksen jälkeen pitäisi olla oikea binääri"
	else
		ok "päivitys korvasi symlinkin binäärillä"
	fi

	ts rollback >/dev/null 2>&1
	if [ -L "$SB/sbin/tailscale" ]; then
		ok "rollback palautti symlinkin"
	else
		bad "rollback jätti oikean tiedoston symlinkin tilalle"
	fi
	assert "linkki osoittaa oikeaan" "$(readlink "$SB/sbin/tailscale")" "tailscaled"
	assert "vanha versio takaisin" "$(installed_version)" "$OLD"
}

case20() {
	CASE="20 asennuskohteessa ei ole tilaa"; setup; say "$CASE"
	# df-tynkä: asennuskohde näyttää täydeltä, muut polut oikealta df:ltä
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
		say "  ohitettu (kuori ajaa oman df-appletinsa PATHin ohi)"
		return 0
	fi

	out="$(ts run 2>&1)"; rc=$?
	assert "poistuu virheellä" "$rc" 1
	case "$out" in *"ei ole tilaa uusille binääreille"*) ok "kertoo syyn" ;;
		*) bad "väärä viesti: $out" ;; esac
	assert_nofile "mitään ei ladattu" "$SB/tmp/tailscale_${NEW}_${ARCH}.tgz"
	assert_nofile "ei varmuuskopiota" "$SB/backup/tailscaled.gz"
	assert "binääriä ei vaihdettu" "$(installed_version)" "$OLD"
	assert_file "daemon jätettiin rauhaan" "$SB/daemon.pid"
}

run_suite() {
	for n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
		want "$n" || continue
		"case$n"
	done
}

for _need in sha256sum tar gzip awk sed; do
	command -v "$_need" >/dev/null 2>&1 || { say "puuttuu: $_need"; exit 1; }
done

mkdir -p "$ROOT"

say "== suite: sed-varapolku (ei jsonfilteriä)"
USE_JSONFILTER=0
run_suite

if command -v python3 >/dev/null 2>&1; then
	say ""
	say "== suite: jsonfilter-tynkä"
	USE_JSONFILTER=1
	run_suite
else
	say ""
	say "(python3 puuttuu — jsonfilter-polkua ei testattu)"
fi

say ""
say "läpi: $PASS, virheitä: $FAIL"
if [ "$FAIL" -gt 0 ]; then
	printf '%s\n' "$FAILED"
	exit 1
fi
exit 0
