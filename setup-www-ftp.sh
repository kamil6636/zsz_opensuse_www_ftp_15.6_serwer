#!/bin/bash
# =====================================================================
#  openSUSE Leap: serwer (router + NAT, DHCP/DNS, WWW, FTP) albo klient
#
#  Topologia:
#     INTERNET -- [WAN] SERWER [LAN] -- KLIENT
#
#  Użycie (jako root):
#     bash setup-www-ftp.sh server [-y] [--skip-net]
#     bash setup-www-ftp.sh client [-y] [--skip-net]
#
#     -y          bez pytań (używa wartości domyślnych)
#     --skip-net  nie rusza konfiguracji IP interfejsów
#     --root-pass=HASLO  ustaw inne hasło roota niż domyślne
#     --no-root-pass     nie zmieniaj hasła roota
#
#  Skrypt sam naprawia typowe problemy z internetem (karta wyłączona,
#  brak adresu IP z DHCP, brak trasy domyślnej, brak DNS).
#  Skrypt można uruchamiać wielokrotnie (jest idempotentny).
# =====================================================================
set -euo pipefail

FTP_USER="ftpuser"
WEB_ROOT="/srv/www/htdocs"
DEFAULT_LAN_IP="192.168.50.1"
ROOT_PASS='zaq1@WSX'     # domyślne hasło administratora (root)
SET_ROOT=1
SCRIPT_PATH="$(readlink -f "$0" 2>/dev/null || echo "$0")"

usage() { echo "Użycie: $0 {server|client} [-y] [--skip-net] [--root-pass=HASLO|--no-root-pass]"; exit 1; }

[[ $EUID -eq 0 ]] || { echo "Uruchom jako root (wpisz: su -  i hasło roota)."; exit 1; }

MODE=""; AUTO=0; SKIP_NET=0
for a in "$@"; do
    case "$a" in
        server|client) MODE="$a" ;;
        -y|--yes)      AUTO=1 ;;
        --skip-net)    SKIP_NET=1 ;;
        --root-pass=*) ROOT_PASS="${a#--root-pass=}" ;;
        --no-root-pass) SET_ROOT=0 ;;
        *) echo "Nieznana opcja: $a"; usage ;;
    esac
done
[[ -n "$MODE" ]] || usage

cleanup() { systemctl unmask packagekit &>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------
# Pomocnicze
# ---------------------------------------------------------------------
ask() {  # ask "Pytanie" "domyślna" nazwa_zmiennej
    local val=""
    if [[ $AUTO -eq 0 ]]; then read -r -p "$1 [$2]: " val; fi
    printf -v "$3" '%s' "${val:-$2}"
}

confirm() {  # confirm "Pytanie"
    [[ $AUTO -eq 1 ]] && return 0
    local a; read -r -p "$1 (t/n) [t]: " a
    [[ "${a:-t}" == "t" ]]
}

default_iface() { ip -o route show default | awk '{print $5; exit}'; }

phys_iface_except() {  # pierwszy fizyczny (nie-Wi-Fi) interfejs inny niż $1
    local i
    for i in $(ls /sys/class/net); do
        [[ "$i" == "lo" || "$i" == "${1:-}" ]] && continue
        [[ -e "/sys/class/net/$i/device" ]] || continue
        [[ -d "/sys/class/net/$i/wireless" ]] && continue
        echo "$i"; return
    done
}

add_hosts_entry() {  # add_hosts_entry IP nazwa
    sed -i "/[[:space:]]$2\$/d" /etc/hosts
    echo "$1 $2" >> /etc/hosts
}

set_root_password() {
    if [[ $SET_ROOT -eq 1 ]]; then
        if echo "root:$ROOT_PASS" | chpasswd; then
            echo "==> Hasło administratora (root) ustawione."
        else
            echo "UWAGA: nie udało się ustawić hasła roota."
        fi
    fi
}

backup() { if [[ -f "$1" && ! -f "$1.bak" ]]; then cp "$1" "$1.bak"; fi; }

use_nm() { command -v nmcli &>/dev/null && systemctl is-active --quiet NetworkManager; }

nm_con_of() { nmcli -g GENERAL.CONNECTION device show "$1" 2>/dev/null || true; }

wait_for() {  # wait_for host sekundy
    local _
    for _ in $(seq 1 "$2"); do
        if ping -c1 -W1 "$1" &>/dev/null; then return 0; fi
        sleep 1
    done
    return 1
}

# ---------------------------------------------------------------------
# Pakiety: omija blokadę PackageKit, dodaje repozytoria jeśli brak
# ---------------------------------------------------------------------
stop_packagekit() {
    systemctl mask --now packagekit &>/dev/null || true
    pkill packagekitd 2>/dev/null || true
    local _
    for _ in $(seq 1 30); do
        if [[ -f /run/zypp.pid ]] && kill -0 "$(cat /run/zypp.pid)" 2>/dev/null; then
            sleep 1
        else
            break
        fi
    done
}

zy() { stop_packagekit; zypper --non-interactive --gpg-auto-import-keys "$@"; }

ensure_repos() {
    if zypper lr -u 2>/dev/null | grep -qE 'https?://'; then return; fi
    local ver id
    ver=$(. /etc/os-release; echo "${VERSION_ID:-}")
    id=$(. /etc/os-release; echo "${ID:-}")
    if [[ "$id" == "opensuse-leap" && -n "$ver" ]]; then
        echo "==> Brak repozytoriów online - dodaję Leap $ver"
        zypper ar -f "http://download.opensuse.org/distribution/leap/$ver/repo/oss" repo-oss || true
        zypper ar -f "http://download.opensuse.org/update/leap/$ver/oss" repo-update || true
    fi
}

install_packages() {
    ensure_repos
    zy refresh || true
    zy install "$@"
}

# ---------------------------------------------------------------------
# Sieć: apply_iface IFACE dhcp|static [IP/MASKA] [BRAMA] [DNS]
# ---------------------------------------------------------------------
apply_iface() {
    local ifc="$1" method="$2" ip="${3:-}" gw="${4:-}" dns="${5:-}"
    if use_nm; then
        local con
        con=$(nm_con_of "$ifc")
        if [[ -z "$con" || "$con" == "--" ]]; then
            con="net-$ifc"
            nmcli con add type ethernet ifname "$ifc" con-name "$con" >/dev/null
        fi
        if [[ "$method" == "dhcp" ]]; then
            nmcli con mod "$con" ipv4.method auto ipv4.addresses "" ipv4.gateway "" ipv4.dns ""
        else
            nmcli con mod "$con" ipv4.method manual ipv4.addresses "$ip" \
                ipv4.gateway "$gw" ipv4.dns "$dns"
            if [[ -z "$gw" ]]; then nmcli con mod "$con" ipv4.never-default yes; fi
        fi
        nmcli -w 30 con up "$con"
    else
        local f="/etc/sysconfig/network/ifcfg-$ifc" r="/etc/sysconfig/network/ifroute-$ifc"
        if [[ "$method" == "dhcp" ]]; then
            printf "BOOTPROTO='dhcp'\nSTARTMODE='auto'\n" > "$f"
            rm -f "$r"
        else
            printf "BOOTPROTO='static'\nSTARTMODE='auto'\nIPADDR='%s'\n" "$ip" > "$f"
            if [[ -n "$gw" ]]; then echo "default $gw - -" > "$r"; else rm -f "$r"; fi
            if [[ -n "$dns" ]]; then
                sed -i "s|^NETCONFIG_DNS_STATIC_SERVERS=.*|NETCONFIG_DNS_STATIC_SERVERS=\"${dns//,/ }\"|" \
                    /etc/sysconfig/network/config
                netconfig update -f || true
            fi
        fi
        wicked ifreload "$ifc" || systemctl restart network
    fi
}

# ---------------------------------------------------------------------
# Samonaprawa internetu
# ---------------------------------------------------------------------
net_ok() { ping -c1 -W2 8.8.8.8 &>/dev/null; }
dns_ok() { getent hosts download.opensuse.org &>/dev/null; }

# fix_internet IFACE [BRAMA_PODPOWIEDZ]  - zwraca 0, gdy internet i DNS działają
fix_internet() {
    local ifc="$1" gw_hint="${2:-}" attempt ip4 gw carrier cfg=/etc/sysconfig/network/config
    if net_ok && dns_ok; then return 0; fi
    echo "==> Naprawiam internet na $ifc..."

    for attempt in 1 2; do
        # 1. karta włączona i podłączona
        ip link set "$ifc" up 2>/dev/null || true
        sleep 2
        carrier=$(cat "/sys/class/net/$ifc/carrier" 2>/dev/null || echo 0)
        if [[ "$carrier" != "1" ]]; then
            echo "   $ifc nie ma połączenia. VirtualBox: Ustawienia > Sieć > Adapter > 'Kabel podłączony'."
        fi

        # 2. adres IPv4 (DHCP)
        ip4=$(ip -4 -o addr show dev "$ifc" scope global | awk '{print $4; exit}' || true)
        if [[ -z "$ip4" ]]; then
            echo "   Brak adresu IPv4 - uruchamiam DHCP (próba $attempt)..."
            apply_iface "$ifc" dhcp || true
            sleep 3
            ip4=$(ip -4 -o addr show dev "$ifc" scope global | awk '{print $4; exit}' || true)
        fi

        # 3. trasa domyślna
        if [[ -n "$ip4" ]] && ! ip route show default | grep -q '^default'; then
            gw="$gw_hint"
            [[ -n "$gw" ]] || gw="${ip4%.*}.2"     # w sieci NAT VirtualBoxa brama kończy się na .2
            if ping -c1 -W2 "$gw" &>/dev/null; then
                echo "   Brak trasy domyślnej - dodaję bramę $gw"
                ip route add default via "$gw" dev "$ifc" || true
            fi
        fi

        # 4. DNS
        if net_ok && ! dns_ok; then
            echo "   Internet jest, ale DNS nie działa - ustawiam 8.8.8.8"
            if [[ -f "$cfg" ]] && grep -q '^NETCONFIG_DNS_STATIC_SERVERS=""' "$cfg"; then
                sed -i 's|^NETCONFIG_DNS_STATIC_SERVERS=.*|NETCONFIG_DNS_STATIC_SERVERS="8.8.8.8 1.1.1.1"|' "$cfg"
                netconfig update -f || true
            fi
            dns_ok || echo "nameserver 8.8.8.8" >> /etc/resolv.conf
        fi

        if net_ok && dns_ok; then echo "   Internet działa."; return 0; fi
    done

    echo "BŁĄD: nie udało się naprawić internetu na $ifc."
    echo "      Sprawdź ustawienia sieci w VirtualBoxie i README (sekcja 'Poradnik: internet')."
    return 1
}

# Próbuje naprawić internet po kolei na każdej fizycznej karcie (serwer: nie wiadomo, która to WAN)
fix_internet_any() {
    local i first
    for i in $(ls /sys/class/net); do
        [[ "$i" == "lo" ]] && continue
        [[ -e "/sys/class/net/$i/device" ]] || continue
        [[ -d "/sys/class/net/$i/wireless" ]] && continue
        echo "   Sprawdzam kartę $i..."
        if fix_internet "$i"; then return 0; fi
    done
    # ostatnia deska ratunku: domyślne adresy sieci NAT VirtualBoxa na pierwszej karcie
    first=$(phys_iface_except "" || true)
    if [[ -n "$first" ]]; then
        echo "   DHCP nie zadziałał - ustawiam adresy domyślnej sieci NAT VirtualBoxa na $first..."
        apply_iface "$first" static "10.0.2.15/24" "10.0.2.2" "10.0.2.3,8.8.8.8" || true
        sleep 3
        net_ok && return 0
    fi
    return 1
}

# =====================================================================
#  SERWER
# =====================================================================
setup_server() {
    local def_wan def_lan wan_ip suggest_lan
    def_wan=$(default_iface || true)
    if [[ -z "$def_wan" ]]; then
        echo "==> Serwer nie ma trasy domyślnej - próbuję samodzielnie naprawić internet..."
        fix_internet_any || true
        def_wan=$(default_iface || true)
    fi
    [[ -n "$def_wan" ]] || { echo "BŁĄD: serwer nie ma internetu. Zobacz README, sekcja 'Poradnik: internet'."; exit 1; }

    echo "==> Konfiguracja serwera"
    ask "Interfejs WAN (wychodzi do internetu)" "$def_wan" WAN_IF
    def_lan=$(phys_iface_except "$WAN_IF" || true)
    ask "Interfejs LAN (do klienta)" "${def_lan:-}" LAN_IF
    if [[ -z "$LAN_IF" ]]; then
        echo "BŁĄD: nie znaleziono drugiego interfejsu sieciowego dla LAN."
        echo "      Potrzebna jest druga karta (w VirtualBoxie: adapter 2 = sieć wewnętrzna)."
        exit 1
    fi

    wan_ip=$(ip -4 -o addr show dev "$WAN_IF" | awk '{print $4; exit}' || true)
    suggest_lan="$DEFAULT_LAN_IP"
    [[ "$wan_ip" == 192.168.50.* ]] && suggest_lan="192.168.60.1"
    ask "Adres IP serwera w LAN (maska /24)" "$suggest_lan" LAN_IP
    BASE="${LAN_IP%.*}"
    ask "Nazwa hosta serwera" "serwer" NEW_HOSTNAME
    ask "Otworzyć WWW także od strony WAN (np. dla przekierowania portów z hosta)? (t/n)" "t" OPEN_WAN

    echo
    echo "  WAN: $WAN_IF (bez zmian)   LAN: $LAN_IF = $LAN_IP/24"
    echo "  DHCP dla klientów: ${BASE}.100 - ${BASE}.200, brama i DNS = $LAN_IP"
    if [[ $SET_ROOT -eq 1 ]]; then echo "  Hasło roota: zostanie ustawione na domyślne ze skryptu"; fi
    confirm "Zastosować?" || { echo "Przerwano."; exit 0; }

    set_root_password

    # 1. Nazwa hosta + sieć LAN
    hostnamectl set-hostname "$NEW_HOSTNAME"
    if [[ $SKIP_NET -eq 0 ]]; then
        echo "==> Ustawianie IP na $LAN_IF..."
        apply_iface "$LAN_IF" static "$LAN_IP/24" "" ""
    fi
    add_hosts_entry "$LAN_IP" "$NEW_HOSTNAME"

    # 2. Internet na WAN + pakiety
    echo "==> Sprawdzanie internetu na serwerze..."
    fix_internet "$WAN_IF" || { echo "Bez internetu nie da się zainstalować pakietów."; exit 1; }
    echo "==> Instalacja pakietów..."
    install_packages apache2 vsftpd firewalld dnsmasq curl openssh

    # 3. SSH
    systemctl enable --now sshd

    # 4. Routing IPv4
    echo "==> Włączanie routingu..."
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/90-ipforward.conf
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    # 5. WWW
    echo "==> Strona testowa WWW..."
    cat > "$WEB_ROOT/index.html" <<'EOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Działa</title></head>
<body><h1>Serwer WWW na openSUSE działa!</h1></body></html>
EOF
    # kopia skryptu na serwerze WWW - klient pobierze go przez http://serwer/
    if [[ -f "$SCRIPT_PATH" ]]; then
        cp -f "$SCRIPT_PATH" "$WEB_ROOT/setup-www-ftp.sh"
    fi

    # 6. FTP
    echo "==> FTP: użytkownik $FTP_USER i vsftpd..."
    FTP_PASS=""
    if ! id "$FTP_USER" &>/dev/null; then
        useradd -d "$WEB_ROOT" -s /usr/sbin/nologin "$FTP_USER"
        if [[ $AUTO -eq 1 ]]; then
            FTP_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12 || true)
            echo "$FTP_USER:$FTP_PASS" | chpasswd
        else
            echo "Ustaw hasło dla $FTP_USER:"
            until passwd "$FTP_USER"; do echo "Spróbuj ponownie."; done
        fi
    fi
    grep -qx /usr/sbin/nologin /etc/shells || echo /usr/sbin/nologin >> /etc/shells
    chown -R "$FTP_USER":users "$WEB_ROOT"

    backup /etc/vsftpd.conf
    cat > /etc/vsftpd.conf <<EOF
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
EOF
    echo "$FTP_USER" > /etc/vsftpd.userlist

    # 7. DHCP + DNS (dnsmasq)
    echo "==> DHCP i DNS dla klientów (dnsmasq)..."
    backup /etc/dnsmasq.conf
    cat > /etc/dnsmasq.conf <<EOF
interface=$LAN_IF
bind-interfaces
domain-needed
bogus-priv
expand-hosts
dhcp-range=${BASE}.100,${BASE}.200,255.255.255.0,12h
dhcp-option=option:router,$LAN_IP
dhcp-option=option:dns-server,$LAN_IP
server=1.1.1.1
server=8.8.8.8
EOF
    mkdir -p /etc/systemd/system/dnsmasq.service.d
    cat > /etc/systemd/system/dnsmasq.service.d/override.conf <<EOF
[Unit]
After=network-online.target
Wants=network-online.target
EOF
    systemctl daemon-reload

    # 8. Firewall + NAT
    echo "==> Firewall i NAT..."
    systemctl enable --now firewalld
    firewall-cmd --permanent --zone=external --add-masquerade >/dev/null
    firewall-cmd --permanent --zone=external --add-service=ssh >/dev/null
    if [[ "$OPEN_WAN" == "t" ]]; then
        firewall-cmd --permanent --zone=external --add-service=http >/dev/null
    fi
    for s in ssh http ftp dns dhcp; do
        firewall-cmd --permanent --zone=internal --add-service="$s" >/dev/null
    done
    firewall-cmd --permanent --zone=internal --add-port=40000-40100/tcp >/dev/null

    if firewall-cmd --permanent --get-policies 2>/dev/null | grep -qw lan-to-wan \
       || firewall-cmd --permanent --new-policy lan-to-wan &>/dev/null; then
        firewall-cmd --permanent --policy lan-to-wan --add-ingress-zone internal &>/dev/null || true
        firewall-cmd --permanent --policy lan-to-wan --add-egress-zone external &>/dev/null || true
        firewall-cmd --permanent --policy lan-to-wan --set-target ACCEPT &>/dev/null || true
    else
        echo "   (starszy firewalld bez polityk - używam samego maskowania)"
    fi
    firewall-cmd --reload >/dev/null

    # Przypisanie kart do stref (karty zarządzane przez NetworkManager wymagają
    # ustawienia strefy w połączeniu oraz zmiany w działającym firewallu)
    if use_nm; then
        local pair ifc zone con
        for pair in "$WAN_IF:external" "$LAN_IF:internal"; do
            ifc="${pair%%:*}"; zone="${pair##*:}"
            con=$(nm_con_of "$ifc")
            if [[ -n "$con" && "$con" != "--" ]]; then
                nmcli con mod "$con" connection.zone "$zone" || true
            fi
        done
    fi
    firewall-cmd --zone=external --change-interface="$WAN_IF" >/dev/null
    firewall-cmd --zone=internal --change-interface="$LAN_IF" >/dev/null
    firewall-cmd --runtime-to-permanent >/dev/null

    # 9. Usługi
    echo "==> Uruchamianie usług..."
    systemctl enable apache2 vsftpd dnsmasq
    systemctl restart apache2 vsftpd dnsmasq

    # 10. Testy
    echo
    echo "==> Testy"
    for s in firewalld apache2 vsftpd dnsmasq sshd; do
        printf "  %-10s %s\n" "$s" "$(systemctl is-active "$s" || true)"
    done
    if curl -fsS -o /dev/null http://localhost; then echo "  WWW lokalnie: OK"; else echo "  WWW lokalnie: BŁĄD"; fi
    if [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]]; then echo "  Routing:      OK"; else echo "  Routing:      BŁĄD"; fi
    if ping -c1 -W2 8.8.8.8 &>/dev/null; then echo "  Internet:     OK"; else echo "  Internet:     BRAK (sprawdź WAN)"; fi
    echo "  Strefy firewalla:"
    firewall-cmd --get-active-zones | sed 's/^/    /'

    echo
    echo "GOTOWE."
    echo "  Klienci dostaną IP z puli ${BASE}.100-200 (brama/DNS: $LAN_IP)."
    echo "  FTP: login $FTP_USER${FTP_PASS:+, hasło: $FTP_PASS}"
    echo "  Skrypt dla klienta: http://$LAN_IP/setup-www-ftp.sh"
    echo "  Na kliencie: curl -O http://$LAN_IP/setup-www-ftp.sh && bash setup-www-ftp.sh client"
}

# =====================================================================
#  KLIENT
# =====================================================================
setup_client() {
    local def_if
    def_if=$(default_iface || true)
    [[ -n "$def_if" ]] || def_if=$(phys_iface_except "" || true)

    echo "==> Konfiguracja klienta"
    ask "Interfejs sieciowy" "${def_if:-eth0}" IFACE
    ask "Adres IP serwera" "$DEFAULT_LAN_IP" SRV_IP
    ask "Nazwa serwera" "serwer" SRV_NAME
    ask "Nazwa hosta klienta" "klient" NEW_HOSTNAME
    ask "Pobrać IP automatycznie z serwera (DHCP)? (t/n)" "t" USE_DHCP

    CLIENT_IP=""
    if [[ "$USE_DHCP" != "t" ]]; then
        ask "Adres IP klienta z maską" "${SRV_IP%.*}.20/24" CLIENT_IP
    fi

    echo
    echo "  Interfejs: $IFACE | ${CLIENT_IP:-DHCP} | brama/DNS: $SRV_IP | serwer: $SRV_NAME"
    if [[ $SET_ROOT -eq 1 ]]; then echo "  Hasło roota: zostanie ustawione na domyślne ze skryptu"; fi
    confirm "Zastosować?" || { echo "Przerwano."; exit 0; }

    set_root_password

    hostnamectl set-hostname "$NEW_HOSTNAME"
    if [[ $SKIP_NET -eq 0 ]]; then
        echo "==> Ustawianie sieci..."
        if [[ "$USE_DHCP" == "t" ]]; then
            apply_iface "$IFACE" dhcp
        else
            apply_iface "$IFACE" static "$CLIENT_IP" "$SRV_IP" "$SRV_IP,8.8.8.8"
        fi
    fi

    echo "==> Czekam na połączenie z serwerem i internetem..."
    wait_for "$SRV_IP" 30 || echo "   UWAGA: serwer $SRV_IP nie odpowiada (sprawdź nazwę sieci wewnętrznej w VirtualBoxie)."
    fix_internet "$IFACE" "$SRV_IP" || { echo "Klient nie ma internetu przez serwer - sprawdź, czy serwer działa (README: Poradnik: internet)."; exit 1; }
    add_hosts_entry "$SRV_IP" "$SRV_NAME"

    echo "==> Instalacja narzędzi klienckich..."
    install_packages curl wget lftp openssh

    echo
    echo "==> Testy"
    if ping -c1 -W2 "$SRV_IP" &>/dev/null;    then echo "  Serwer ($SRV_IP): OK";  else echo "  Serwer ($SRV_IP): BRAK"; fi
    if ping -c1 -W2 8.8.8.8 &>/dev/null;      then echo "  Internet:         OK";  else echo "  Internet:         BRAK"; fi
    if getent hosts opensuse.org &>/dev/null; then echo "  DNS:              OK";  else echo "  DNS:              BŁĄD"; fi
    if curl -fsS -o /dev/null "http://$SRV_NAME"; then echo "  WWW:              OK"; else echo "  WWW:              BŁĄD"; fi

    echo
    echo "GOTOWE. Przykłady:"
    echo "  curl http://$SRV_NAME"
    echo "  lftp -u $FTP_USER $SRV_NAME"
    echo "  curl -T plik.txt ftp://$FTP_USER@$SRV_NAME/"
}

case "$MODE" in
    server) setup_server ;;
    client) setup_client ;;
esac
