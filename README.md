# openSUSE: serwer WWW + FTP + router (NAT, DHCP, DNS) i klient

Jeden skrypt (`setup-www-ftp.sh`), który konfiguruje dwie maszyny z openSUSE Leap 15.6:

- **serwer**: router z NAT-em (daje klientowi internet), DHCP i DNS (dnsmasq), WWW (Apache), FTP (vsftpd), firewall (firewalld), SSH,
- **klient**: sieć przez serwer, narzędzia (curl, wget, lftp) i testy połączenia.

Skrypt **sam naprawia typowe problemy z internetem** (wyłączona karta, brak adresu z DHCP, brak trasy domyślnej, brak DNS). Jeśli to nie wystarczy, jest [poradnik ręcznej naprawy](#poradnik-internet).

```
INTERNET ── [WAN: eth1] SERWER [LAN: eth0] ── KLIENT
```

## Wymagania

- openSUSE Leap 15.6 na obu maszynach, uruchamianie jako **root** (`su -`).
- Serwer ma **dwie karty sieciowe**: jedną z internetem (WAN), drugą do klienta (LAN).
- Klient ma jedną kartę podłączoną do tej samej sieci co LAN serwera.

### Ustawienia w VirtualBoxie (maszyny wyłączone)

| Maszyna | Adapter 1 | Adapter 2 |
|---|---|---|
| Serwer | NAT (WAN, internet) | Sieć wewnętrzna, nazwa np. `lan` (LAN) |
| Klient | Sieć wewnętrzna, **ta sama nazwa** `lan` | wyłączony |

Przy każdym adapterze w *Zaawansowane* zaznacz **Kabel podłączony**.

Opcjonalnie, żeby łączyć się z hosta przez SSH i przeglądarkę: *Serwer → Sieć → Adapter 1 → Zaawansowane → Przekierowanie portów*:

| Nazwa | Protokół | Adres hosta | Port hosta | Port gościa |
|---|---|---|---|---|
| ssh | TCP | 127.0.0.1 | 2222 | 22 |
| www | TCP | 127.0.0.1 | 8080 | 80 |

## Instalacja serwera

Najpierw serwer, bo klient dostaje internet właśnie przez niego. Zaloguj się jako root i wpisz:

```bash
curl -L -o repo.tar.gz https://github.com/kamil6636/zsz_opensuse_www_ftp_15.6_serwer/archive/refs/heads/main.tar.gz
tar -xzf repo.tar.gz
cd zsz_opensuse_www_ftp_15.6_serwer-main
bash setup-www-ftp.sh server
```

Skrypt zapyta o:

1. interfejs WAN (domyślnie ten z trasą domyślną, np. `eth1`),
2. interfejs LAN (np. `eth0`),
3. adres IP serwera w LAN (domyślnie `192.168.50.1/24`),
4. nazwę hosta (domyślnie `serwer`),
5. czy otworzyć WWW także od strony WAN,
6. hasło dla użytkownika FTP `ftpuser`.

Na wszystkie pytania poza hasłem FTP wystarczy **Enter** (przyjmuje wartość domyślną).

Bez pytań (hasło FTP zostanie wygenerowane i wypisane na końcu):

```bash
bash setup-www-ftp.sh server -y
```

Na końcu skrypt pokazuje sekcję **Testy**. Wszystkie pozycje powinny mieć status OK / `active`.

> Jeśli serwer nie ma internetu, `curl` z GitHuba się nie uda. Przenieś wtedy skrypt z hosta: `scp -P 2222 setup-www-ftp.sh root@127.0.0.1:~` (wymaga reguły przekierowania portu SSH) i uruchom `bash setup-www-ftp.sh server`. Skrypt sam spróbuje uzyskać internet przed instalacją pakietów.

## Instalacja klienta

Serwer musi być włączony. Klient pobiera skrypt przez serwer:

```bash
curl -O http://192.168.50.1/setup-www-ftp.sh
bash setup-www-ftp.sh client
```

Albo z GitHuba (jeśli klient ma już internet):

```bash
curl -L -o repo.tar.gz https://github.com/kamil6636/zsz_opensuse_www_ftp_15.6_serwer/archive/refs/heads/main.tar.gz
tar -xzf repo.tar.gz
cd zsz_opensuse_www_ftp_15.6_serwer-main
bash setup-www-ftp.sh client
```

Klient pyta o interfejs, adres serwera, nazwy i o to, czy pobrać IP przez DHCP (domyślnie tak, adres z puli `192.168.50.100–200`). Jeśli klient nie ma jeszcze adresu, żeby pobrać skrypt, ustaw go tymczasowo: `ip addr add 192.168.50.20/24 dev eth0`.

## Opcje skryptu

| Opcja | Znaczenie |
|---|---|
| `-y` | bez pytań, wartości domyślne |
| `--skip-net` | nie zmienia adresów IP interfejsów |
| `--root-pass=HASLO` | ustawia inne hasło roota niż domyślne |
| `--no-root-pass` | nie zmienia hasła roota |

Domyślne hasło roota jest zmienną `ROOT_PASS` na początku skryptu. Zmień je przed użyciem poza maszynami testowymi.

Skrypt można uruchamiać wielokrotnie.

## Co skrypt naprawia sam

| Problem | Co robi skrypt |
|---|---|
| Karta sieciowa wyłączona | włącza ją (`ip link set ... up`) i ostrzega, jeśli brakuje połączenia (kabel w VirtualBoxie) |
| Brak adresu IPv4 | uruchamia DHCP (NetworkManager lub wicked) |
| Brak trasy domyślnej | dodaje bramę (w sieci NAT VirtualBoxa to adres kończący się na `.2`; na kliencie adres serwera) |
| Brak DNS | ustawia 8.8.8.8 i 1.1.1.1 |
| Serwer: nie wiadomo, która karta to WAN | próbuje po kolei na każdej fizycznej karcie |
| DHCP nie działa nigdzie | ostatecznie ustawia domyślne adresy NAT VirtualBoxa (10.0.2.15, brama 10.0.2.2, DNS 10.0.2.3) |
| PackageKit blokuje `zypper` | wyłącza go na czas instalacji |
| Brak repozytoriów online | dodaje repozytoria Leap |
| Karty w złych strefach firewalla | przypisuje WAN do `external`, LAN do `internal` |

Skrypt nie naprawi tego, co jest poza systemem: źle ustawionego adaptera w VirtualBoxie (tryb inny niż NAT, odznaczony „Kabel podłączony”) albo braku internetu na komputerze-hoście. Wtedy wypisze wskazówkę, a poniższy poradnik pokaże, co sprawdzić.

## Sprawdzenie, że wszystko działa

Na kliencie:

```bash
ping -c2 192.168.50.1      # serwer
ping -c2 8.8.8.8           # internet przez serwer
ping -c2 github.com        # DNS
curl http://serwer         # strona WWW
lftp -u ftpuser serwer     # FTP
```

Z hosta (przy regule przekierowania portów): `http://127.0.0.1:8080` oraz `ssh -p 2222 root@127.0.0.1`.

Własną stronę wgrasz przez FTP do `/srv/www/htdocs/` (plik `index.html` zastąpi stronę testową):

```bash
curl -T index.html ftp://ftpuser@serwer/
```

<a id="poradnik-internet"></a>
## Poradnik: internet

Poradnik zakłada czysty system openSUSE Leap 15.6 w VirtualBoxie, gdzie adapter 1 to NAT. W takiej sieci maszyna dostaje zwykle adres `10.0.2.15`, bramę `10.0.2.2` i DNS `10.0.2.3`. Jeśli używasz „Sieci NAT” w VirtualBoxie, adresy mogą być inne (np. `10.0.3.15`, brama `10.0.3.2`). Zasada jest ta sama: brama to adres kończący się na `.2`. Komendy wpisuj jako root. Nazwy kart (`eth0`, `eth1`) sprawdzisz przez `ip -br a`.

### Krok 1: diagnoza

```bash
ip -br a            # czy karta ma adres IPv4?
ip route            # czy jest linia "default via ..."?
ping -c2 8.8.8.8    # czy jest internet po samym IP?
ping -c2 github.com # czy działa DNS?
```

| Wynik | Przyczyna | Idź do kroku |
|---|---|---|
| karta bez adresu IPv4 (tylko `fe80::...`) | brak DHCP | 3 |
| adres jest, brak linii `default` | brak bramy | 4 |
| `ping 8.8.8.8` działa, `github.com` nie | brak DNS | 5 |
| adres i brama są, a `ping 8.8.8.8` nie działa | problem w VirtualBoxie lub na hoście | 2 |

### Krok 2: ustawienia VirtualBoxa i hosta

Przy wyłączonej maszynie: *Ustawienia → Sieć → Adapter 1*:

- **Włącz kartę sieciową**,
- **Podłączona do: NAT**,
- w *Zaawansowane* zaznacz **Kabel podłączony**.

Sprawdź też, czy sam komputer-host ma internet. Bez niego NAT w maszynie też nie zadziała.

### Krok 3: uzyskanie adresu (DHCP)

Włącz kartę i poproś o adres. Użyj jednego z wariantów, zależnie od tego, co jest w systemie (`systemctl is-active NetworkManager wicked` pokaże, który działa).

NetworkManager (system z środowiskiem graficznym):

```bash
ip link set eth0 up
nmcli device connect eth0
# jeśli brak połączenia dla karty, utwórz je:
nmcli con add type ethernet ifname eth0 con-name net-eth0 ipv4.method auto
nmcli con up net-eth0
```

wicked (typowa instalacja serwerowa):

```bash
ip link set eth0 up
printf "BOOTPROTO='dhcp'\nSTARTMODE='auto'\n" > /etc/sysconfig/network/ifcfg-eth0
wicked ifreload eth0
```

Sprawdź `ip -br a`. Karta powinna mieć adres, np. `10.0.2.15/24`.

**Jeśli DHCP nie działa**, ustaw adresy ręcznie (dla domyślnej sieci NAT VirtualBoxa):

```bash
ip link set eth0 up
ip addr add 10.0.2.15/24 dev eth0
ip route add default via 10.0.2.2
echo "nameserver 10.0.2.3" > /etc/resolv.conf
```

Te ustawienia znikną po restarcie. Trwałe ustawienie zrobisz przez YaST (*System → Network Settings → Edit → Dynamic Address (DHCP)*) albo komendami `nmcli`/`wicked` powyżej.

### Krok 4: brama (trasa domyślna)

```bash
ip route add default via 10.0.2.2 dev eth0
ip route
```

Jeśli komenda zwróci `Nexthop has invalid gateway`, karta nie ma adresu w tej podsieci. Wróć do kroku 3. Jeśli zwróci `File exists`, trasa już jest.

### Krok 5: DNS

Doraźnie:

```bash
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
```

Na stałe (openSUSE zarządza DNS przez `netconfig`): w pliku `/etc/sysconfig/network/config` ustaw

```
NETCONFIG_DNS_STATIC_SERVERS="8.8.8.8 1.1.1.1"
```

i zastosuj: `netconfig update -f`.

### Krok 6: test

```bash
ping -c2 8.8.8.8
ping -c2 github.com
```

Jeśli oba odpowiadają, uruchom skrypt ponownie.

### Klient bez internetu

Klient dostaje internet tylko przez serwer. Najpierw upewnij się, że działa serwer:

1. Na **serwerze**: `ping -c2 8.8.8.8` musi działać (jeśli nie, napraw serwer według kroków 1 do 6).
2. Na serwerze: `sysctl net.ipv4.ip_forward` ma pokazać `1`.
3. Na serwerze: `firewall-cmd --get-active-zones` ma pokazać WAN w `external` i LAN w `internal`.
4. Na serwerze: `systemctl is-active dnsmasq firewalld` ma pokazać `active`.
5. W VirtualBoxie klient i adapter 2 serwera mają **tę samą nazwę sieci wewnętrznej**.
6. Na **kliencie**: `ip route` ma pokazać `default via 192.168.50.1`, a w razie braku wpisz `ip route add default via 192.168.50.1`.

Najprościej uruchomić skrypt serwera jeszcze raz (`bash setup-www-ftp.sh server`), bo naprawia punkty 2 do 4 sam.

## Rozwiązywanie innych problemów

| Objaw | Co zrobić |
|---|---|
| Klient nie dostaje adresu | Sprawdź nazwę sieci wewnętrznej w VirtualBoxie; na serwerze `systemctl status dnsmasq` |
| `PackageKit is blocking zypper` | Skrypt sam to obchodzi; ręcznie: `systemctl mask --now packagekit` |
| `Connection refused` przy SSH | `systemctl enable --now sshd` i sprawdź przekierowanie portu |
| `no provider of git found` | Git nie jest potrzebny, użyj `curl` z archiwum, jak wyżej |
| `Permission denied` przy `sudo` | Na openSUSE `sudo` pyta o hasło roota; wejdź na roota przez `su -` |

## Uwagi bezpieczeństwa

- FTP przesyła hasła niezaszyfrowane. Do nauki w sieci lokalnej wystarczy, w sieci publicznej użyj SFTP.
- Skrypt ustawia znane hasło roota. To rozwiązanie wyłącznie do maszyn testowych.
- WWW i FTP są dostępne od strony LAN. Od strony WAN skrypt otwiera tylko SSH i (opcjonalnie) HTTP.
