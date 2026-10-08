# openSUSE: serwer WWW + FTP + router (NAT, DHCP, DNS) i klient

Jeden skrypt (`setup-www-ftp.sh`), który konfiguruje dwie maszyny z openSUSE Leap 15.6:

- **serwer**: router z NAT-em (daje klientowi internet), DHCP i DNS (dnsmasq), WWW (Apache), FTP (vsftpd), firewall (firewalld), SSH,
- **klient**: sieć przez serwer, narzędzia (curl, wget, lftp) i testy połączenia.

Skrypt **sam naprawia typowe problemy z internetem** (wyłączona karta, brak adresu z DHCP, brak trasy domyślnej, brak DNS). Projekt jest przeznaczony do lokalnego serwera na potrzeby zadania, dlatego nie ma w nim zabezpieczeń ponad podstawowe.

```
INTERNET ── [WAN: karta z NAT-em] SERWER [LAN: sieć wewnętrzna] ── KLIENT
                10.0.2.15                     192.168.50.1          192.168.50.100-200
```

## Spis treści

1. [Wymagania](#wymagania)
2. [Instalacja serwera krok po kroku](#instalacja-serwera)
3. [Instalacja klienta](#instalacja-klienta)
4. [SSH: poradnik](#ssh)
5. [Opcje skryptu](#opcje-skryptu)
6. [Co skrypt naprawia sam](#co-skrypt-naprawia-sam)
7. [Sprawdzenie, że wszystko działa](#sprawdzenie)
8. [Poradnik: internet](#poradnik-internet)
9. [Dodatek: ręczna konfiguracja serwera bez skryptu](#dodatek-reczna-konfiguracja)
10. [Rozwiązywanie innych problemów](#problemy)

---

## Wymagania

- **VirtualBox** na komputerze-hoście (Windows, Linux lub macOS) z działającym internetem.
- Obraz **openSUSE Leap 15.6** (ISO). Skrypt był pisany i testowany pod tę wersję. Uwaga: Leap 15.6 przestał być wspierany 30.04.2026 (nie dostaje już poprawek), ale instalacja pakietów z repozytoriów nadal działa, a ostrzeżenia o wygasłych metadanych repozytoriów można zignorować. Nowszy Leap 16.0 ma inny instalator i inne domyślne ustawienia, więc skrypt nie był na nim sprawdzany.
- Uruchamianie skryptu jako **root**.
- Serwer ma **dwie karty sieciowe**: jedną z internetem (WAN), drugą do klienta (LAN). Klient ma jedną kartę w tej samej sieci co LAN serwera.

<a id="instalacja-serwera"></a>
## Instalacja serwera krok po kroku

### Etap 1: utworzenie maszyny wirtualnej serwera

1. Uruchom VirtualBox i kliknij **Nowa** (New).
2. Wpisz:
   - **Nazwa:** `serwer`,
   - **Obraz ISO:** wskaż pobrany plik openSUSE Leap 15.6,
   - **Typ:** Linux, **Wersja:** openSUSE (64-bit),
   - zaznacz **Skip Unattended Installation** (pomiń instalację nienadzorowaną), jeśli jest taka opcja.
3. **Sprzęt:** pamięć **2048 MB**, procesory **2**.
4. **Dysk wirtualny:** utwórz nowy, **20 GB**, typ VDI, dynamicznie przydzielany.
5. Zakończ kreator, ale **jeszcze nie uruchamiaj** maszyny.

### Etap 2: karty sieciowe serwera (maszyna wyłączona)

Wejdź w *Ustawienia → Sieć*:

| Zakładka | Ustawienia |
|---|---|
| **Adapter 1** | zaznacz *Włącz kartę sieciową*, **Podłączona do: NAT**, w *Zaawansowane* zaznacz *Kabel podłączony* |
| **Adapter 2** | zaznacz *Włącz kartę sieciową*, **Podłączona do: Sieć wewnętrzna**, **nazwa: `lan`**, *Kabel podłączony* zaznaczony |

Nazwa sieci wewnętrznej (`lan`) musi być **identyczna** na serwerze i na kliencie (bez literówek).

Od razu możesz dodać przekierowanie portów, żeby łączyć się z hosta (*Adapter 1 → Zaawansowane → Przekierowanie portów → ikonka +*):

| Nazwa | Protokół | Adres hosta | Port hosta | Adres gościa | Port gościa |
|---|---|---|---|---|---|
| ssh | TCP | 127.0.0.1 | 2222 | (puste) | 22 |
| www | TCP | 127.0.0.1 | 8080 | (puste) | 80 |

### Etap 3: instalacja systemu openSUSE Leap 15.6

Uruchom maszynę (przycisk **Uruchom**). Nazwy opcji w instalatorze mogą się nieco różnić od podanych.

1. W menu startowym wybierz **Installation** (nie *Upgrade*).
2. **Language / Keyboard:** wybierz język i **układ klawiatury** (np. Polish). Zaakceptuj licencję i kliknij **Next**.
3. **Online Repositories:** jeśli instalator o to pyta, wybierz **Yes** (maszyna ma internet przez NAT) i zostaw domyślną listę repozytoriów.
4. **System Role:** wybierz **Server** (bez środowiska graficznego, lżejszy). Jeśli wolisz mieć okna i schowek współdzielony, wybierz rolę z pulpitem, np. Xfce lub GNOME.
5. **Suggested Partitioning:** zostaw propozycję instalatora (cały dysk wirtualny) i kliknij **Next**.
6. **Clock and Time Zone:** region **Europe**, strefa **Poland**.
7. **Local User:** wpisz imię i nazwę użytkownika (np. `zsz`) i hasło. Zaznacz **Use this password for system administrator**, żeby root miał to samo hasło. Skrypt i tak ustawi hasło roota na domyślne. Nie zaznaczaj *Automatic Login*.
8. **Installation Settings (podsumowanie):** sprawdź sekcję *Security*. Ma być:
   - SSH service **enabled**,
   - SSH port **open**.

   Jeśli jest inaczej, kliknij odpowiedni link (*enable*, *open*). Firewall zostaw włączony, skrypt skonfiguruje go sam.
9. Kliknij **Install** i potwierdź. Instalacja trwa zwykle 5 do 15 minut.
10. Po instalacji maszyna się zrestartuje. Jeśli ponownie pojawi się menu instalatora, wyłącz maszynę, w *Ustawienia → Pamięć* odłącz plik ISO i uruchom ponownie.

### Etap 4: pierwsze uruchomienie i sprawdzenie sieci

1. Zaloguj się: login `root` i hasło ustawione w instalatorze.
2. Sprawdź karty:

   ```bash
   ip -br a
   ```

   Powinny być dwie karty (np. `eth0`, `eth1`, albo `enp0s3`, `enp0s8`). Ta z adresem `10.0.x.15` to **WAN** (NAT). Ta bez adresu IPv4 to **LAN**. Zapamiętaj ich nazwy.
3. Sprawdź internet:

   ```bash
   ping -c2 8.8.8.8
   ping -c2 github.com
   ```

   Jeśli to nie działa, nie szkodzi, skrypt spróbuje to naprawić sam. W razie kłopotów zajrzyj do [poradnika internetu](#poradnik-internet).

### Etap 5: pobranie skryptu

Jako root wpisz:

```bash
curl -L -o repo.tar.gz https://github.com/kamil6636/zsz_opensuse_www_ftp_15.6_serwer/archive/refs/heads/main.tar.gz
tar -xzf repo.tar.gz
cd zsz_opensuse_www_ftp_15.6_serwer-main
ls
```

W katalogu ma być `setup-www-ftp.sh`. Opcja `-L` jest potrzebna, bo GitHub przekierowuje pobieranie. Git nie jest wymagany.

Jeśli serwer nie ma internetu, skopiuj skrypt z hosta (wymaga reguły przekierowania portu SSH z etapu 2 i [włączonego SSH](#ssh)):

```bash
scp -P 2222 setup-www-ftp.sh root@127.0.0.1:~
```

### Etap 6: uruchomienie skryptu

```bash
bash setup-www-ftp.sh server
```

Skrypt zadaje pytania. Wartość w nawiasach kwadratowych `[...]` to domyślna odpowiedź, którą zatwierdza **Enter**:

| Pytanie | Co oznacza | Odpowiedź |
|---|---|---|
| Interfejs WAN | karta z internetem (NAT) | Enter, jeśli podpowiedź to karta z adresem `10.0.x.15` |
| Interfejs LAN | karta do klienta (sieć wewnętrzna) | Enter, jeśli to ta druga karta |
| Adres IP serwera w LAN | adres serwera w sieci klienta | Enter (`192.168.50.1`) |
| Nazwa hosta serwera | nazwa maszyny | Enter (`serwer`) |
| Otworzyć WWW od strony WAN | pozwala wejść na stronę z hosta przez przekierowanie portu | Enter (`t`) |
| Zastosować? | ostatnie potwierdzenie z podsumowaniem | `t` albo Enter |
| Hasło dla ftpuser | hasło użytkownika FTP | wpisz własne i powtórz |

Jeśli któraś podpowiedź wygląda źle (np. WAN ma zły interfejs), wpisz właściwą nazwę karty (np. `eth1`) zamiast Enter. **Nie wpisuj adresu IP tam, gdzie pytanie dotyczy nazwy karty.**

Bez pytań (hasło FTP zostanie wygenerowane i wypisane na końcu):

```bash
bash setup-www-ftp.sh server -y
```

Co skrypt robi po kolei (widać to po liniach `==>`):

1. Ustawia hasło roota i nazwę hosta.
2. Konfiguruje kartę LAN (stały adres `192.168.50.1/24`).
3. Sprawdza internet na WAN i w razie potrzeby go naprawia.
4. Instaluje pakiety: Apache, vsftpd, firewalld, dnsmasq, curl, openssh (kilka minut).
5. Włącza SSH i routing IPv4.
6. Tworzy stronę WWW i kopię skryptu w `/srv/www/htdocs/` (z niej klient pobierze skrypt).
7. Konfiguruje FTP (użytkownik `ftpuser`, katalog `/srv/www/htdocs`).
8. Konfiguruje DHCP i DNS dla klientów (dnsmasq, pula `192.168.50.100-200`).
9. Konfiguruje firewall i NAT (WAN w strefie `external`, LAN w `internal`).
10. Uruchamia usługi i wypisuje **Testy**.

### Etap 7: sprawdzenie wyniku

Na końcu skrypt wypisuje sekcję **Testy**. Poprawny wynik wygląda mniej więcej tak:

```
==> Testy
  firewalld  active
  apache2    active
  vsftpd     active
  dnsmasq    active
  sshd       active
  WWW lokalnie: OK
  Routing:      OK
  Internet:     OK
  Strefy firewalla:
    external
      interfaces: eth1
    internal
      interfaces: eth0
```

Dodatkowo sprawdź ręcznie:

```bash
curl http://localhost                 # strona "Serwer WWW na openSUSE działa!"
/usr/sbin/sysctl net.ipv4.ip_forward  # ma być 1
firewall-cmd --get-active-zones       # WAN w external, LAN w internal
ip -br a                              # LAN = 192.168.50.1/24
```

Jeśli któraś pozycja pokazuje BŁĄD, BRAK albo `inactive`, uruchom skrypt jeszcze raz (można go powtarzać bez szkody). Jeśli nie pomaga, zobacz [poradnik internetu](#poradnik-internet) i [rozwiązywanie problemów](#problemy).

Na końcu serwer jest gotowy. Następny krok to [klient](#instalacja-klienta).

<a id="instalacja-klienta"></a>
## Instalacja klienta

Serwer musi być włączony.

1. Utwórz maszynę `klient` w VirtualBoxie tak samo jak serwer (Etap 1), ale z **jednym** adapterem: **Adapter 1 → Sieć wewnętrzna → nazwa `lan`** (taka sama jak na serwerze). Zainstaluj openSUSE (Etap 3, rola dowolna, np. z pulpitem).
2. Po zalogowaniu jako root (`su -`) klient powinien dostać adres z DHCP serwera (`ip -br a`). Jeśli nie ma adresu, ustaw go tymczasowo: `ip addr add 192.168.50.20/24 dev eth0` (nazwę karty weź z `ip -br a`).
3. Pobierz skrypt z serwera i uruchom go:

   ```bash
   curl -O http://192.168.50.1/setup-www-ftp.sh
   bash setup-www-ftp.sh client
   ```

   Jeśli klient ma już internet, może też pobrać skrypt z GitHuba, jak w etapie 5.
4. Odpowiedzi: Enter na interfejs, adres serwera (`192.168.50.1`), nazwę serwera (`serwer`) i nazwę klienta (`klient`). Na pytanie o DHCP zostaw `t` (adres z puli `192.168.50.100-200`) albo wpisz `n` i podaj stały adres (np. `192.168.50.20/24`). Na końcu `t`.

Skrypt klienta ustawia sieć, naprawia internet, dopisuje serwer do `/etc/hosts`, instaluje narzędzia i wypisuje testy.

<a id="ssh"></a>
## SSH: poradnik

SSH pozwala wpisywać polecenia z komputera-hosta (wklejanie, kopiowanie) i przesyłać pliki. Ponieważ serwer jest lokalny i służy do zadania, poniższa konfiguracja jest celowo prosta: logowanie roota hasłem.

Skrypt serwera instaluje i włącza `sshd` sam. Jeśli SSH nie działa, zrób to ręcznie.

### 1. Instalacja i uruchomienie (na serwerze, jako root)

```bash
zypper install openssh
systemctl enable --now sshd
systemctl status sshd --no-pager
ss -tlnp | grep :22
```

Ostatnia komenda ma pokazać, że `sshd` nasłuchuje na porcie 22.

### 2. Zezwolenie na logowanie roota hasłem

Domyślnie SSH może blokować logowanie roota hasłem. Wstaw dwie linie na **początek** pliku konfiguracyjnego (sshd bierze pierwszą napotkaną wartość, więc to działa niezależnie od reszty pliku):

```bash
[ -f /etc/ssh/sshd_config ] || cp /usr/etc/ssh/sshd_config /etc/ssh/sshd_config
sed -i '1i PermitRootLogin yes\nPasswordAuthentication yes' /etc/ssh/sshd_config
sshd -t && systemctl restart sshd
```

`sshd -t` sprawdza poprawność konfiguracji. Brak wypisanego błędu oznacza, że wszystko jest w porządku.

### 3. Otwarcie portu w firewallu

Skrypt robi to sam. Ręcznie:

```bash
firewall-cmd --permanent --zone=external --add-service=ssh
firewall-cmd --permanent --zone=internal --add-service=ssh
firewall-cmd --reload
```

Jeśli firewalld jeszcze nie jest skonfigurowany (przed uruchomieniem skryptu), użyj `firewall-cmd --permanent --add-service=ssh && firewall-cmd --reload`.

### 4. Przekierowanie portu w VirtualBoxie (połączenie z hosta)

Karta NAT nie jest widoczna z hosta, więc potrzebna jest reguła przekierowania portu.

**W oknie VirtualBoxa:** *Ustawienia serwera → Sieć → Adapter 1 → Zaawansowane → Przekierowanie portów → +*:

| Nazwa | Protokół | Adres hosta | Port hosta | Adres gościa | Port gościa |
|---|---|---|---|---|---|
| ssh | TCP | 127.0.0.1 | 2222 | (puste) | 22 |

**Albo z linii poleceń hosta** (nazwa maszyny jak w VirtualBoxie, tu `serwer`):

```bash
# maszyna wyłączona
VBoxManage modifyvm "serwer" --natpf1 "ssh,tcp,127.0.0.1,2222,,22"
# maszyna włączona
VBoxManage controlvm "serwer" natpf1 "ssh,tcp,127.0.0.1,2222,,22"
```

W Windowsie `VBoxManage.exe` leży w `C:\Program Files\Oracle\VirtualBox\`.

### 5. Połączenie z hosta

W terminalu hosta (Terminal, PowerShell lub cmd, wszystkie mają polecenie `ssh`):

```bash
ssh -p 2222 root@127.0.0.1
```

Przy pierwszym połączeniu wpisz `yes` (akceptacja odcisku klucza), potem hasło roota. Zamiast terminala możesz użyć PuTTY: host `127.0.0.1`, port `2222`, typ SSH.

Przesyłanie plików:

```bash
scp -P 2222 setup-www-ftp.sh root@127.0.0.1:~       # z hosta na serwer
scp -P 2222 root@127.0.0.1:~/plik.txt .              # z serwera na hosta
```

Uwaga: `scp` używa **dużego** `-P` dla portu, a `ssh` małego `-p`.

### 6. Połączenie z klienta na serwer (sieć wewnętrzna)

Na kliencie (ma narzędzia SSH po uruchomieniu skryptu klienta):

```bash
ssh root@192.168.50.1
# albo po nazwie
ssh root@serwer
```

### 7. Połączenie z hosta na klienta (przez serwer)

Klient ma tylko sieć wewnętrzną, więc host nie widzi go bezpośrednio. Użyj serwera jako przystanku (`-J`):

```bash
ssh -J root@127.0.0.1:2222 root@192.168.50.20
```

(zamiast `192.168.50.20` wpisz adres klienta z `ip -br a`). Klient też musi mieć działający `sshd`: `zypper install openssh && systemctl enable --now sshd`.

### Problemy z SSH

| Komunikat | Przyczyna | Co zrobić |
|---|---|---|
| `Connection refused` | `sshd` nie działa albo zły port | `systemctl enable --now sshd`; pamiętaj o `-p 2222` przy połączeniu z hosta |
| `Connection timed out` | zła reguła przekierowania albo firewall | sprawdź regułę w VirtualBoxie i `firewall-cmd --list-services --zone=external` |
| `Permission denied` | zły login lub hasło, albo root zablokowany | wykonaj punkt 2 i wpisz właściwe hasło roota |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | system został zainstalowany od nowa, klucz jest inny | `ssh-keygen -R "[127.0.0.1]:2222"` i połącz się ponownie |
| `ssh -p 22 ... 127.0.0.1` łączy z czymś innym | port 22 na hoście to SSH hosta, nie maszyny wirtualnej | użyj `-p 2222` |

## Opcje skryptu

<a id="opcje-skryptu"></a>

| Opcja | Znaczenie |
|---|---|
| `-y` | bez pytań, wartości domyślne |
| `--skip-net` | nie zmienia adresów IP interfejsów |
| `--root-pass=HASLO` | ustawia inne hasło roota niż domyślne |
| `--no-root-pass` | nie zmienia hasła roota |

Domyślne hasło roota jest zmienną `ROOT_PASS` na początku skryptu. Skrypt można uruchamiać wielokrotnie.

<a id="co-skrypt-naprawia-sam"></a>
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

Skrypt nie naprawi tego, co jest poza systemem: źle ustawionego adaptera w VirtualBoxie (tryb inny niż NAT, odznaczony „Kabel podłączony”) albo braku internetu na hoście.

<a id="sprawdzenie"></a>
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

Poradnik zakłada czysty system openSUSE Leap 15.6 w VirtualBoxie, gdzie adapter z NAT-em daje zwykle adres `10.0.2.15`, bramę `10.0.2.2` i DNS `10.0.2.3`. Jeśli używasz „Sieci NAT” w VirtualBoxie, adresy mogą być inne (np. `10.0.3.15`, brama `10.0.3.2`). Zasada jest ta sama: brama to adres kończący się na `.2`. Komendy wpisuj jako root. Nazwy kart (`eth0`, `eth1`) sprawdzisz przez `ip -br a`.

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

Przy wyłączonej maszynie: *Ustawienia → Sieć → Adapter 1*: włącz kartę, **Podłączona do: NAT**, w *Zaawansowane* zaznacz **Kabel podłączony**. Sprawdź też, czy sam komputer-host ma internet. Bez niego NAT w maszynie też nie zadziała.

### Krok 3: uzyskanie adresu (DHCP)

`systemctl is-active NetworkManager wicked` pokaże, który menedżer sieci działa.

NetworkManager:

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

**Jeśli DHCP nie działa**, ustaw adresy ręcznie (domyślna sieć NAT VirtualBoxa):

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

`Nexthop has invalid gateway` oznacza, że karta nie ma adresu w tej podsieci (wróć do kroku 3). `File exists` oznacza, że trasa już jest.

### Krok 5: DNS

Doraźnie: `echo "nameserver 8.8.8.8" >> /etc/resolv.conf`.

Na stałe: w pliku `/etc/sysconfig/network/config` ustaw `NETCONFIG_DNS_STATIC_SERVERS="8.8.8.8 1.1.1.1"` i zastosuj `netconfig update -f`.

### Krok 6: test

```bash
ping -c2 8.8.8.8
ping -c2 github.com
```

Jeśli oba odpowiadają, uruchom skrypt ponownie.

### Klient bez internetu

Klient dostaje internet tylko przez serwer:

1. Na **serwerze**: `ping -c2 8.8.8.8` musi działać (jeśli nie, napraw serwer według kroków 1 do 6).
2. Na serwerze: `/usr/sbin/sysctl net.ipv4.ip_forward` ma pokazać `1`.
3. Na serwerze: `firewall-cmd --get-active-zones` ma pokazać WAN w `external` i LAN w `internal`.
4. Na serwerze: `systemctl is-active dnsmasq firewalld` ma pokazać `active`.
5. W VirtualBoxie klient i adapter 2 serwera mają **tę samą nazwę sieci wewnętrznej**.
6. Na **kliencie**: `ip route` ma pokazać `default via 192.168.50.1` (w razie braku: `ip route add default via 192.168.50.1`).

Najprościej uruchomić skrypt serwera jeszcze raz (`bash setup-www-ftp.sh server`), bo naprawia punkty 2 do 4 sam.

<a id="dodatek-reczna-konfiguracja"></a>
## Dodatek: ręczna konfiguracja serwera bez skryptu

To samo, co robi skrypt, wykonane ręcznie jako root. Za przykład przyjęto: WAN = `eth1`, LAN = `eth0`, adres serwera `192.168.50.1`. Podmień nazwy kart na swoje.

**1. Pakiety**

```bash
zypper refresh
zypper install apache2 vsftpd firewalld dnsmasq curl openssh
```

**2. Adres IP na karcie LAN** (NetworkManager, nazwa połączenia zwykle równa nazwie karty, sprawdź `nmcli con show`):

```bash
nmcli con mod eth0 ipv4.method manual ipv4.addresses 192.168.50.1/24 ipv4.never-default yes
nmcli con up eth0
```

Wariant wicked:

```bash
printf "BOOTPROTO='static'\nSTARTMODE='auto'\nIPADDR='192.168.50.1/24'\n" > /etc/sysconfig/network/ifcfg-eth0
wicked ifreload eth0
```

**3. Routing**

```bash
echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/90-ipforward.conf
sysctl -w net.ipv4.ip_forward=1
```

**4. Strona WWW**

```bash
echo '<h1>Serwer WWW na openSUSE działa!</h1>' > /srv/www/htdocs/index.html
systemctl enable --now apache2
```

**5. FTP**

```bash
useradd -d /srv/www/htdocs -s /usr/sbin/nologin ftpuser
passwd ftpuser
grep -qx /usr/sbin/nologin /etc/shells || echo /usr/sbin/nologin >> /etc/shells
chown -R ftpuser:users /srv/www/htdocs
echo ftpuser > /etc/vsftpd.userlist
```

Plik `/etc/vsftpd.conf`:

```
listen=YES
listen_ipv6=NO
anonymous_enable=NO
local_enable=YES
write_enable=YES
local_umask=022
chroot_local_user=YES
allow_writeable_chroot=YES
pam_service_name=vsftpd
userlist_enable=YES
userlist_file=/etc/vsftpd.userlist
userlist_deny=NO
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
xferlog_enable=YES
```

```bash
systemctl enable --now vsftpd
```

**6. DHCP i DNS (dnsmasq)**: plik `/etc/dnsmasq.conf`:

```
interface=eth0
bind-interfaces
domain-needed
bogus-priv
expand-hosts
dhcp-range=192.168.50.100,192.168.50.200,255.255.255.0,12h
dhcp-option=option:router,192.168.50.1
dhcp-option=option:dns-server,192.168.50.1
server=1.1.1.1
server=8.8.8.8
```

```bash
systemctl enable --now dnsmasq
```

**7. Firewall i NAT**

```bash
systemctl enable --now firewalld
firewall-cmd --permanent --zone=external --add-masquerade
firewall-cmd --permanent --zone=external --add-service=ssh
firewall-cmd --permanent --zone=external --add-service=http
for s in ssh http ftp dns dhcp; do firewall-cmd --permanent --zone=internal --add-service=$s; done
firewall-cmd --permanent --zone=internal --add-port=40000-40100/tcp
firewall-cmd --permanent --new-policy lan-to-wan
firewall-cmd --permanent --policy lan-to-wan --add-ingress-zone internal
firewall-cmd --permanent --policy lan-to-wan --add-egress-zone external
firewall-cmd --permanent --policy lan-to-wan --set-target ACCEPT
firewall-cmd --reload
# karty do stref (runtime, potem zapis na stałe)
firewall-cmd --zone=external --change-interface=eth1
firewall-cmd --zone=internal --change-interface=eth0
firewall-cmd --runtime-to-permanent
```

Jeśli karty są zarządzane przez NetworkManager, ustaw też strefy w połączeniach: `nmcli con mod eth1 connection.zone external` i `nmcli con mod eth0 connection.zone internal`. Jeśli `--new-policy` zwróci `NAME_CONFLICT`, polityka już istnieje, więc pomiń te trzy linie.

**8. Test:** `curl http://localhost`, `systemctl is-active apache2 vsftpd dnsmasq firewalld`, a z klienta `ping 8.8.8.8` i `curl http://192.168.50.1`.

<a id="problemy"></a>
## Rozwiązywanie innych problemów

| Objaw | Co zrobić |
|---|---|
| Klient nie dostaje adresu | Sprawdź nazwę sieci wewnętrznej w VirtualBoxie; na serwerze `systemctl status dnsmasq` |
| `PackageKit is blocking zypper` | Skrypt sam to obchodzi; ręcznie: `systemctl mask --now packagekit` |
| `no provider of git found` | Git nie jest potrzebny, użyj `curl` z archiwum, jak wyżej |
| `Permission denied` przy `sudo` | Na openSUSE `sudo` pyta o hasło roota; wejdź na roota przez `su -` |
| `lftp` i `ftp` w konflikcie przy instalacji | Skrypt instaluje tylko `lftp`; ręcznie zainstaluj jeden z nich |
| Ostrzeżenie `Repository metadata expired` | Normalne dla Leap 15.6 po zakończeniu wsparcia; można zignorować |
| `Authorization failed` przy `firewall-cmd` | Wpisujesz jako zwykły użytkownik; wejdź na roota (`su -`) |
