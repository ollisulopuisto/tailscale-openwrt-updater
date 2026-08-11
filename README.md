# ts-update

Tailscalen puoliautomaattinen päivitys OpenWrt-reitittimellä ylävirran
staattisista binääreistä (pkgs.tailscale.com). Päivitys perutaan
automaattisesti, ellei sitä vahvisteta määräajassa — tarkoitettu
etäpäivitykseen, jossa epäonnistuminen katkaisisi ainoan yhteyden
laitteeseen.

## Miksi

OpenWrt:n apk-feed jää jälkeen ylävirrasta, ja Tailscalen oma
`tailscale update` sekä hallintakonsolin "Start update" eivät toimi
OpenWrt:llä lainkaan. Feedin paketti asentaa `/usr/sbin/tailscale`n
symlinkkinä `tailscaled`iin, koska OpenWrt kääntää CLI:n daemoniin mukaan
(`ts_include_cli`); ylävirran tarballissa ne ovat kaksi erillistä
binääriä, joten symlink on korvattava oikealla tiedostolla.

Init-skripti, UCI-konfiguraatio ja tila jäävät apk-paketille:
`/etc/init.d/tailscale`, `/etc/config/tailscale`, `/var/lib/tailscale`.
Vain binäärit `/usr/sbin`:ssä vaihdetaan.

## Asennus

### Suoraan GitHubista laitteella

Laitteella itsellään, ilman että työasemalta tarvitsee kopioida mitään.
`wget` (OpenWrt:llä uclient-fetch) ja `curl` käyvät kumpikin — skripti
tunnistaa itse, kumpi laitteelta löytyy:

    URL=https://raw.githubusercontent.com/ollisulopuisto/tailscale-openwrt-updater/main/netinstall.sh
    wget -O /tmp/netinstall.sh "$URL"     # tai: curl -fsSL -o /tmp/netinstall.sh "$URL"
    sh /tmp/netinstall.sh

Tai yhdellä rivillä, jos et halua lukea skriptiä ensin:

    wget -O- "$URL" | sh
    curl -fsSL "$URL" | sh

Putkiversiossa ei kannata käyttää `wget -q`:ta: jos lataus epäonnistuu,
`sh` saa tyhjän syötteen ja koko asennus menee läpi hiljaa mitään
tekemättä. Ilman `-q`:ta virhe näkyy. Skripti itse on kirjoitettu niin,
että kesken katkennut lataus ei aja puolikasta asennusta (runko on
`main()`-funktiossa, joka kutsutaan vasta viimeisellä rivillä), mutta
tyhjää latausta ei voi mitenkään havaita skriptin sisältä.

`netinstall.sh` hakee `ts-updaten`, boottitarkistuksen ja asetusmallin,
tarkistaa ettei lataus katkennut, asentaa ne ja ottaa boottitarkistuksen
käyttöön. Olemassa olevaa `/etc/default/ts-update`-tiedostoa ei
ylikirjoiteta, joten uudelleenasennus ei hukkaa laitekohtaisia asetuksia.
Jos päivitys odottaa vahvistusta, asennus keskeytyy — silloin kesken on
vahvistusikkuna, jota ei kannata sotkea.

Version voi kiinnittää ja tarkistussumman vaatia:

    sh /tmp/netinstall.sh --ref v1.0 --sha256 <summa>

Poisto (asetukset, tila ja varmuuskopiot jäävät):

    sh /tmp/netinstall.sh --uninstall

Jos HTTPS ei toimi, laitteesta puuttuu yleensä `ca-bundle` tai
`libustream-mbedtls` (`apk add ca-bundle`).

### Työasemalta ssh:n yli

Yksi laite:

    scp -O ts-update root@reititin:/usr/sbin/ts-update
    scp -O ts-update-bootcheck.init root@reititin:/etc/init.d/ts-update-bootcheck
    ssh root@reititin 'chmod 755 /usr/sbin/ts-update /etc/init.d/ts-update-bootcheck \
        && /etc/init.d/ts-update-bootcheck enable'

Monta laitetta:

    ./install.sh root@r1 root@r2
    ./install.sh -f hosts.txt

`install.sh` vie skriptin ja boottitarkistuksen init-skriptin, ja ajaa
lopuksi `ts-update check` jokaisella laitteella. Laitekohtaiset asetukset
luetaan hakemistosta `hosts.d/<host>.env` ja viedään nimellä
`/etc/default/ts-update`. Yhteinen oletusasetustiedosto niille laitteille,
joilla ei ole omaa, annetaan `-e`:llä — ilman sitä laitteen omaa
asetustiedostoa ei ylikirjoiteta:

    ./install.sh -e ts-update.default -f hosts.txt

`-n` näyttää mitä tehtäisiin ajamatta mitään, `-B` jättää
boottitarkistuksen asentamatta.

`scp -O` (vanha scp-protokolla) on pakollinen OpenSSH 9:llä: OpenWrt:ssä
ei ole sftp-serveriä.

## Käyttö

    ts-update check             nykyinen ja uusin versio, paketin saatavuus
    ts-update run               päivitä, terveystarkistus, viritä vahti
    ts-update run --dry-run     lataa ja tarkista, älä vaihda mitään
    ts-update confirm           vahvista päivitys (peruu rollbackin)
    ts-update rollback          palauta edellinen versio heti
    ts-update status            tila ja jäljellä oleva vahvistusaika
    ts-update boot-check        boottauksen jälkeen (init-skripti ajaa tämän)

Tavallinen kierto etäyhteydellä:

    ssh root@reititin ts-update run
    # testaa yhteys ULKOPUOLELTA, toiselta tailnet-laitteelta
    ssh root@reititin ts-update confirm

Jos vahvistus jää tekemättä, vahti palauttaa edellisen version
`TIMEOUT`-sekunnin kuluttua ja yhteys palaa itsestään.

## Asetukset

Ympäristömuuttujina tai tiedostossa `/etc/default/ts-update`
(ympäristö voittaa tiedoston). Malli: `ts-update.default`.

| Muuttuja | Oletus | Merkitys |
|---|---|---|
| `ARCH` | automaattinen | binääriarkkitehtuuri (`arm64`, `mipsle`, …) |
| `TIMEOUT` | 300 | vahvistusaika sekunteina |
| `PEER` | – | tailnet-osoite, johon pingataan terveystestissä |
| `IFACE` | `tailscale0` | verkkoliitäntä, jonka olemassaolo tarkistetaan |
| `CHECK_ROUTES` | 1 | varmista mainostettujen reittien säilyminen |
| `HEALTH_WAIT` | 90 | sekunteja daemonin nousemisen odotusta |
| `WGET` | `wget` | latauskomento (odottaa `-q`/`-T`/`-O`-valitsimia) |

Polut `STATE_DIR`, `BACKUP_DIR`, `SBIN_DIR`, `INIT_SCRIPT`, `TMP_DIR`,
`LOCK_FILE` ja `BASE_URL` voi myös ohittaa; testipeti käyttää tätä.

## Miten turva toimii

1. **Arkkitehtuuri tarkistetaan palvelimen listaa vasten** ennen latausta:
   `?mode=json`in `Tarballs`-kartasta katsotaan, että juuri tämä
   versio/arkkitehtuuri on olemassa. Väärä arvaus huomataan ennen kuin
   mitään on ladattu.
2. **Levytila tarkistetaan** ennen latausta, varmuuskopiota ja binäärien
   vaihtoa, jottei `/overlay` täyty kesken toimenpiteen.
3. **Tarkistussumma** haetaan ja varmistetaan (`sha256sum -c`).
4. **Uusi binääri ajetaan kerran** (`tailscale version`) vielä ennen kuin
   palvelua pysäytetään: väärä arkkitehtuuri ei silloin katkaise yhteyttä.
5. **Varmuuskopio** vanhoista binääreistä `/root/ts-backup/*.gz`.
6. **Terveystarkistus**: `BackendState: Running`, verkkoliitäntä pystyssä,
   mainostetut reitit samat kuin ennen päivitystä, ja valinnainen
   `tailscale ping PEER`. Epäonnistuminen palauttaa vanhan version heti.
7. **Vahti** (`setsid`illä irrotettu taustaprosessi) palauttaa vanhan
   version, ellei `confirm` tule määräajassa.
8. **Boottitarkistus**: odottava päivitys tallennetaan `/root`iin, ja
   `/etc/init.d/ts-update-bootcheck` jatkaa vahtia jäljellä olevalla
   ajalla tai tekee rollbackin, jos daemon ei noussut tai määräaika ehti
   umpeutua. Ilman tätä kesken vahvistusikkunan tehty uudelleenkäynnistys
   jättäisi vahvistamattoman version pysyvästi voimaan.
9. **Lukitus** (`flock`, varapolkuna hakemistolukko) estää kaksi
   päällekkäistä ajoa.

JSON luetaan `jsonfilter`illä (libubox, OpenWrt:ssä vakiona). Jos sitä ei
ole, käytetään sed-varapolkua.

## Mitä tämä EI suojaa

- **Reitittimen kaatuminen tai jumittuminen.** Vahti elää samassa
  laitteessa; jos koko laite kaatuu, mikään ei tee rollbackia ennen
  boottausta — ja jos laite ei boottaa, ei senkään jälkeen.
- **LAN-yhteyden tai virran menetys.** Boottitarkistus auttaa vain, jos
  laite nousee ylös.
- **apk-paketin päivitys.** `apk upgrade` asentaa feedin binäärit takaisin
  `/usr/sbin`:iin (ja `tailscale`n taas symlinkkinä). Aja `ts-update run`
  uudelleen paketin päivityksen jälkeen.
- **Tailscalen konfiguraatiovirheet.** Terveystarkistus katsoo daemonin
  tilaa, liitäntää ja mainostettuja reittejä — ei sitä, toimiiko ACL,
  DNS tai exit node -reititys oikein. Testaa yhteys aina ulkopuolelta
  ennen `confirm`ia.
- **Ylävirran rikkinäinen julkaisu**, joka nousee pystyyn ja läpäisee
  terveystarkistuksen mutta rikkoo jotain muuta. Siihen auttaa vain
  vahvistusikkunan aikana tehty oma testaus.
- **Kellon hyppy.** Määräaika on absoluuttinen aikaleima; boottitarkistus
  rajaa jäljellä olevan ajan enintään `TIMEOUT`:iin, mutta rajua
  taaksepäin hyppäävää kelloa se ei korjaa.

## Kehitys

    shellcheck -s sh ts-update install.sh netinstall.sh ts-update-bootcheck.init tests/run-tests.sh
    ./tests/run-tests.sh

GitHub Actions (`.github/workflows/ci.yml`) ajaa jokaisesta pushista ja
pull requestista `shellcheck -s sh`in, `dash -n`-syntaksitarkistuksen ja
testimatriisin kahdella kuorella: `dash` (tiukka POSIX) ja busybox ash
(sama kuin OpenWrt:llä). Kuoren voi valita paikallisestikin:
`TS_SH=dash ./tests/run-tests.sh`.

Testipeti ajaa koko koneiston hiekkalaatikossa: `tailscale`, init-skripti
ja `wget` ovat tynkiä, "binäärit" ovat sh-skriptejä ja polut osoittavat
väliaikaishakemistoon. Oikeaa laitetta ei tarvita eikä kosketa. Suite
ajetaan kahdesti, jos `python3` löytyy: kerran sed-varapolulla ja kerran
`jsonfilter`-tyngän kanssa. Yksittäiset tapaukset numerolla:
`./tests/run-tests.sh 5 6`.

### Testimatriisi

| Tapaus | Odotus | Testi |
|---|---|---|
| Jo uusin versio | `run` poistuu koodilla 0, ei kosketa mihinkään | 1 |
| Verkko poikki kesken latauksen | ei varmuuskopiota, ei binäärinvaihtoa | 2 |
| Tarkistussumma ei täsmää | lataus poistetaan, poistuu virheellä | 3 |
| Uusi binääri ei nouse | automaattinen rollback ilman odotusta | 4 |
| Vahvistus ajoissa | vahti kuolee, uusi versio jää | 5 |
| Ei vahvistusta | rollback määräajan päätyttyä | 6 |
| Kuivaharjoitus | lataus ja summa ok, mitään ei vaihdeta | 7 |
| Arkkitehtuuria ei ole palvelimella | virhe ennen latausta | 8 |
| Kaksi rinnakkaista ajoa | jälkimmäinen torjutaan | 9 |
| Feed-versio `1.98.3-1` vs. `1.98.3` | ei näytä uudemmalta | 10 |
| Boottaus vahvistusikkunassa, daemon kunnossa | vahti jatkaa, rollback määräajassa | 11 |
| Boottaus vahvistusikkunassa, daemon rikki | rollback heti | 12 |
| Mainostetut reitit katoavat | terveystarkistus kaatuu, rollback | 13 |
| `check` ja `status` | näyttävät version, paketin ja vahvistustilan | 14 |
| Boottaus binäärinvaihdon ja vahdin virityksen välissä | rollback, ei jää voimaan | 15 |
| Vahvistus samaan aikaan kun vahti palauttaa | `confirm` kertoo todellisen tilan | 16 |
| Vanhentunut `watchdog.pid` boottauksen jälkeen | ei tapa vierasta prosessia | 17 |
| `netinstall.sh` GitHubista | asentaa, ei ylikirjoita asetuksia, torjuu katkenneen latauksen | 18 |

Testaamatta oikealla laitteella: `mipsle`, `mips`, `mips64`, `arm`,
`amd64`, `386`, `riscv64`. Ajossa: aarch64 / OpenWrt 25.12.5.
`ts-update check` kertoo heti, osuiko arkkitehtuurin tunnistus oikeaan.
