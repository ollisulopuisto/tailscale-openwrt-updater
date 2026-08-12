# ts-update — tilanne ja jäljellä oleva työ

## Mikä tämä on

`ts-update` päivittää Tailscalen OpenWrt-reitittimellä ylävirran staattisista
binääreistä (pkgs.tailscale.com) ja palauttaa edellisen version automaattisesti,
ellei käyttäjä vahvista päivitystä määräajassa. Tarkoitettu etäpäivitykseen,
jossa epäonnistuminen katkaisisi ainoan yhteyden laitteeseen.

Tausta ja käyttöohjeet: ks. [README.md](README.md).

## Nykytila

Versio 1.0.0. Ajossa kahdella reitittimellä:

- **aarch64**, OpenWrt 25.12.5 — tavallinen asennus, päivitykset vahtineen.
- **ramips/mt7621** (`mipsel_24kc` → `mipsle`), 16 MB flash — binäärit
  USB-levyllä ja `/usr/sbin`:issä symlinkit, koska ylävirran 70 MB ei mahdu
  flashiin. `SBIN_DIR`, `BACKUP_DIR` ja `TMP_DIR` osoitettu levylle,
  `STATE_DIR` jätetty flashiin.

Toiminnot: `check`, `run [--dry-run]`, `confirm`, `rollback`, `status`,
`boot-check`, sisäinen `_watchdog`. Varmuuskopio `$BACKUP_DIR/*.gz`,
odottava tila `$STATE_DIR`, vahti irrotettu istunnosta `setsid`illä ja
määräaika mitattuna monotonisesta `/proc/uptime`-laskurista.

Repossa myös `netinstall.sh` (asennus laitteella suoraan GitHubista),
`install.sh` (monen laitteen asennus työasemalta), `ts-update-bootcheck.init`,
`ts-update.default` ja `tests/run-tests.sh` (22 testitapausta
hiekkalaatikossa, ei vaadi oikeaa laitetta). CI ajaa shellcheckin ja
testimatriisin sekä dashilla että busybox ashilla.

## Tehdyt tehtävät

### 1. jsonfilter sed-jäsennyksen tilalle — tehty
`latest_version()`, `tarball_list()`, `backend_state()` ja `prefs_routes()`
käyttävät `jsonfilter`iä (`@.TarballsVersion`, `@.Tarballs[*]`,
`@.BackendState`, `@.AdvertiseRoutes[*]`). sed-varapolku on jäljellä, jos
`jsonfilter` puuttuu; testipeti ajaa molemmat polut.

### 2. Arkkitehtuurin validointi palvelimen listaa vasten — tehty
`tarball_available()` tarkistaa `Tarballs`-kartasta, että juuri tämä
versio/arkkitehtuuri on olemassa, ennen kuin mitään ladataan. Virheviesti
listaa saatavilla olevat arkkitehtuurit. `detect_arch()` on edelleen
ensimmäinen arvaus, mutta väärä arvaus huomataan nyt ennen latausta.

### 3. Lukitus — tehty
`flock -n` fd 9:llä `run`issa ja `rollback`issa; vahti odottaa lukkoa
enintään 120 s ja tekee rollbackin senkin jälkeen (yhteyden palautus voittaa).
Varapolkuna hakemistolukko, joka siivotaan jos lukinnut prosessi on kuollut.
Vahtiprosessille annetaan `9>&-`, ettei se peri lukkoa koko ikkunan ajaksi.

### 4. Levytilan tarkistus — tehty
`need_space()` ennen latausta (`/tmp`), varmuuskopiota (`/root`) ja
binäärien vaihtoa (`/usr/sbin`). Keskeytys tapahtuu ennen kuin mihinkään
on koskettu. Jos `df` ei kerro mitään järkevää, jatketaan varoituksella.

### 5. Vahti selviää uudelleenkäynnistyksestä — tehty
Odottava tila on `/root/ts-update/`ssa, ei `/tmp`:ssä. `boot-check` +
`/etc/init.d/ts-update-bootcheck` tarkistaa boottauksessa: jos daemon ei
nouse tai määräaika ehti umpeutua → rollback, muuten vahti viritetään
uudelleen jäljellä olevaksi ajaksi. Määräaika on absoluuttinen aikaleima ja
rajataan boottauksessa enintään `TIMEOUT`:iin ntp-hyppyjen varalta.

### 6. Versiovertailu — tehty
`normalize_version()` pudottaa `v`-etuliitteen, `-1`-tyyliset lisäosat ja
`(OpenWrt)`-loppuosan; `version_newer()` vertaa numeerisesti. Feed-versio
`1.98.3-1 (OpenWrt)` ei enää näytä eri versiolta kuin ylävirran `1.98.3`.

### 7. Kuivaharjoitus — tehty
`ts-update run --dry-run` lataa, tarkistaa summan ja ajaa uuden binäärin
kerran, mutta ei pysäytä palvelua eikä vaihda mitään.

### 8. Terveystarkistuksen kattavuus — tehty
`BackendState: Running`, verkkoliitännän (`IFACE`, oletus `tailscale0`)
olemassaolo, mainostettujen reittien säilyminen (`tailscale debug prefs`,
verrataan päivitystä edeltävään tilaan) ja valinnainen `tailscale ping PEER`.
Vertailukohta otetaan talteen ennen päivitystä, joten tarkistus ei vaadi
laitekohtaista konfigurointia. Epäonnistumisen syy kirjataan lokiin.

### 9. Monen laitteen asennus — tehty
`install.sh` ottaa hostit argumentteina tai `-f`-tiedostosta, käyttää
`scp -O`:ta (OpenWrt:ssä ei ole sftp-serveriä), asentaa myös
boottitarkistuksen ja vie laitekohtaisen `/etc/default/ts-update`-tiedoston
hakemistosta `hosts.d/<host>.env`. Yhteinen oletus annetaan `-e`:llä;
ilman sitä laitteen omia asetuksia ei ylikirjoiteta. `-n` näyttää mitä
tehtäisiin.

### 10. Tarkistukset ja dokumentaatio — tehty
`shellcheck -s sh` menee puhtaana läpi kaikista skripteistä. README kertoo
asennuksen, käytön ja erikseen sen, mitä skripti EI suojaa.

## Jäljellä

- **Muut arkkitehtuurit testaamatta oikealla laudalla**: `mips`,
  `mips64`, `mips64le`, `arm`, `amd64`, `386`, `riscv64`.
  `detect_arch()`in osuma näkyy heti `ts-update check`istä, ja väärä
  arvaus torjutaan ennen latausta.
  - `arm64`: ajossa, päivitykset vahtineen.
  - `mipsle`: todettu ramips/mt7621:llä (`DISTRIB_ARCH=mipsel_24kc`).
    Ylävirran binääri nousee pystyyn ja liittyy tailnetiin, mutta
    laitteen 16 MB:n flashiin se ei mahdu — binäärit ajetaan USB:ltä
    symlinkkien takaa, jolloin ts-update toimii `SBIN_DIR`in kautta.
    Itse ts-updaten päivityskierrosta ei ole vielä ajettu siellä läpi.
- **Boottitarkistus testattu vain hiekkalaatikossa** (testit 11 ja 12).
  Oikea uudelleenkäynnistys kesken vahvistusikkunan on vielä ajamatta.
- **apk-paketin päivitys** palauttaa feedin binäärit `/usr/sbin`:iin.
  Nyt siitä vain varoitetaan READMEssä; automaattista havaitsemista
  (esim. `check` huomaisi symlinkin palanneen) ei ole.
- **Lokin kierrätys** on karkea (leikkaus 500 riviin, kun tiedosto ylittää
  256 kt). Riittänee, mutta ei ole testattu pitkällä ajolla.

## Testimatriisi

Ajetaan `./tests/run-tests.sh` (hiekkalaatikko, ei vaadi laitetta);
tapauskohtainen erittely on READMEssä.
