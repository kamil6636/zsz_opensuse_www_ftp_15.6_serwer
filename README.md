# openSUSE: serwer WWW + FTP + router (NAT, DHCP, DNS) i klient

Jeden skrypt (`setup-www-ftp.sh`), który konfiguruje dwie maszyny z openSUSE Leap 15.6:

- **serwer**: router z NAT-em (daje klientowi internet), DHCP i DNS (dnsmasq), WWW (Apache), FTP (vsftpd), firewall (firewalld), SSH,
- **klient**: sieć przez serwer, narzędzia (curl, wget, lftp) i testy połączenia.

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

## Instalacja klienta

Serwer musi być włączony. W razie potrzeby klient pobiera skrypt przez serwer:

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

Klient pyta o interfejs, adres serwera, nazwy i o to, czy pobrać IP przez DHCP (domyślnie tak, adres z puli `192.168.50.100–200`). Przed pierwszym uruchomieniem klient nie ma adresu: jeśli nie dostał go z DHCP, ustaw tymczasowo `ip addr add 192.168.50.20/24 dev eth0`.

## Opcje skryptu

| Opcja | Znaczenie |
|---|---|
| `-y` | bez pytań, wartości domyślne |
| `--skip-net` | nie zmienia adresów IP interfejsów |
| `--root-pass=HASLO` | ustawia inne hasło roota niż domyślne |
| `--no-root-pass` | nie zmienia hasła roota |

Domyślne hasło roota jest zmienną `ROOT_PASS` na początku skryptu. Zmień je przed użyciem poza maszynami testowymi.

Skrypt można uruchamiać wielokrotnie.

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

## Rozwiązywanie problemów

| Objaw | Co zrobić |
|---|---|
| Klient nie dostaje adresu | Sprawdź, czy nazwa sieci wewnętrznej w VirtualBoxie jest taka sama na obu maszynach; na serwerze `systemctl status dnsmasq` |
| Klient nie ma internetu | Na serwerze: `sysctl net.ipv4.ip_forward` (ma być 1) i `firewall-cmd --get-active-zones` (WAN w `external`, LAN w `internal`) |
| `Could not resolve host` | Brak DNS lub internetu na maszynie; sprawdź `ping 8.8.8.8` |
| `PackageKit is blocking zypper` | Skrypt sam to obchodzi; ręcznie: `systemctl mask --now packagekit` |
| `Connection refused` przy SSH | `systemctl enable --now sshd` i sprawdź przekierowanie portu |
| `no provider of git found` | Git nie jest potrzebny, użyj `curl` z archiwum, jak wyżej |

## Uwagi bezpieczeństwa

- FTP przesyła hasła niezaszyfrowane. Do nauki w sieci lokalnej wystarczy, w sieci publicznej użyj SFTP.
- Skrypt ustawia znane hasło roota. To rozwiązanie wyłącznie do maszyn testowych.
- WWW i FTP są dostępne od strony LAN. Od strony WAN skrypt otwiera tylko SSH i (opcjonalnie) HTTP.
