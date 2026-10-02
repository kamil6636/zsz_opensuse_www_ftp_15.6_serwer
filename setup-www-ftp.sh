#!/bin/bash
# =====================================================================
#  openSUSE: serwer (router + NAT, DHCP/DNS, WWW, FTP) albo klient
#
#  Topologia:
#     INTERNET -- [WAN] SERWER [LAN] -- KLIENT
#
#  Użycie:
#     sudo ./setup-www-ftp.sh server [-y] [--skip-net]
#     sudo ./setup-www-ftp.sh client [-y] [--skip-net]
#
#     -y          bez pytań (używa wartości domyślnych)
#     --skip-net  nie rusza konfiguracji IP interfejsów
# =====================================================================
set -euo pipefail

FTP_USER="ftpuser"
WEB_ROOT="/srv/www/htdocs"
DEFAULT_LAN_IP="192.168.50.1"

usage() { echo "Użycie: $0 {server|client} [-y] [--skip-net]"; exit 1; }

[[ $EUID -eq 0 ]] || { echo "Uruchom jako root (sudo)."; exit 1; }

MODE=""; AUTO=0; SKIP_NET=0
for a in "$@"; do
    case "$a" in
        server|client) MODE="$a" ;;
        -y|--yes)      AUTO=1 ;;
        --skip-net)    SKIP_NET=1 ;;
        *) echo "Nieznana opcja: $a"; usage ;;
    esac
done
[[ -n "$MODE" ]] || usage

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

backup() { if [[ -f "$1" && ! -f "$1.bak" ]]; then cp "$1" "$1.bak"; fi; }

use_nm() { command -v nmcli &>/dev/null && systemctl is-active --quiet NetworkManager; }

# apply_iface IFACE dhcp|static [IP/MASKA] [BRAMA] [DNS]
apply_iface() {
    local ifc="$1" method="$2" ip="${3:-}" gw="${4:-}" dns="${5:-}"
    if use_nm; then
        local con
        con=$(nmcli -g GENERAL.CONNECTION device show "$ifc" 2>/dev/null || true)
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
        nmcli con up "$con"
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

# =====================================================================
#  SERWER
# =====================================================================
setup_server() {
    local def_wan def_lan wan_ip suggest_lan
    def_wan=$(default_iface || true)
    [[ -n "$def_wan" ]] || { echo "BŁĄD: serwer nie ma trasy domyślnej (brak internetu na interfejsie WAN)."; exit 1; }

    echo "==> Konfiguracja serwera"
    ask "Interfejs WAN (wychodzi do internetu)" "$def_wan" WAN_IF
    def_lan=$(phys_iface_except "$WAN_IF" || true)
    ask "Interfejs LAN (do klienta)" "${def_lan:-}" LAN_IF
    if [[ -z "$LAN_IF" ]]; then
        echo "BŁĄD: nie znaleziono drugiego interfejsu sieciowego dla LAN."
        echo "      Potrzebna jest druga karta sieciowa (w VM: drugi adapter, np. sieć wewnętrzna)."
        exit 1
    fi

    wan_ip=$(ip -4 -o addr show dev "$WAN_IF" | awk '{print $4; exit}' || true)
    suggest_lan="$DEFAULT_LAN_IP"
    [[ "$wan_ip" == 192.168.50.* ]] && suggest_lan="192.168.60.1"
    ask "Adres IP serwera w LAN (maska /24)" "$suggest_lan" LAN_IP
    BASE="${LAN_IP%.*}"
    ask "Nazwa hosta serwera" "serwer" NEW_HOSTNAME

    echo
    echo "  WAN: $WAN_IF (bez zmian)   LAN: $LAN_IF = $LAN_IP/24"
    echo "  DHCP dla klientów: ${BASE}.100 - ${BASE}.200, brama i DNS = $LAN_IP"
    confirm "Zastosować?" || { echo "Przerwano."; exit 0; }

    # 1. Sieć LAN + nazwa hosta
    hostnamectl set-hostname "$NEW_HOSTNAME"
    if [[ $SKIP_NET -eq 0 ]]; then
        echo "==> Ustawianie IP na $LAN_IF..."
        apply_iface "$LAN_IF" static "$LAN_IP/24" "" ""
    fi
    add_hosts_entry "$LAN_IP" "$NEW_HOSTNAME"

    # 2. Pakiety
    echo "==> Instalacja pakietów..."
    zypper --non-interactive install apache2 vsftpd firewalld dnsmasq curl

    # 3. Routing IPv4
    echo "==> Włączanie przekazywania pakietów (routing)..."
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/90-ipforward.conf
    sysctl -w net.ipv4.ip_forward=1 >/dev/null

    # 4. WWW
    echo "==> Strona testowa WWW..."
    cat > "$WEB_ROOT/index.html" <<'EOF'
<!DOCTYPE html>
<html><head><meta charset="utf-8"><title>Działa</title></head>
<body><h1>Serwer WWW na openSUSE działa!</h1></body></html>
EOF

    # 5. FTP
    echo "==> FTP: użytkownik $FTP_USER i vsftpd..."
    FTP_PASS=""
    if ! id "$FTP_USER" &>/dev/null; then
        useradd -d "$WEB_ROOT" -s /usr/sbin/nologin "$FTP_USER"
        if [[ $AUTO -eq 1 ]]; then
            FTP_PASS=$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 12 || true)
            echo "$FTP_USER:$FTP_PASS" | chpasswd
        else
            echo "Ustaw hasło dla $FTP_USER:"
            passwd "$FTP_USER"
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

    # 6. DHCP + DNS (dnsmasq)
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

    # 7. Firewall + NAT
    echo "==> Firewall i NAT..."
    systemctl enable --now firewalld
    firewall-cmd --permanent --zone=external --change-interface="$WAN_IF"
    firewall-cmd --permanent --zone=internal --change-interface="$LAN_IF"
    firewall-cmd --permanent --zone=external --add-masquerade
    for s in ssh http ftp dns dhcp; do
        firewall-cmd --permanent --zone=internal --add-service="$s"
    done
    firewall-cmd --permanent --zone=internal --add-port=40000-40100/tcp
    if ! firewall-cmd --permanent --get-policies 2>/dev/null | grep -qw lan-to-wan; then
        if firewall-cmd --permanent --new-policy lan-to-wan &>/dev/null; then
            firewall-cmd --permanent --policy lan-to-wan --add-ingress-zone internal
            firewall-cmd --permanent --policy lan-to-wan --add-egress-zone external
            firewall-cmd --permanent --policy lan-to-wan --set-target ACCEPT
        else
            echo "   (starszy firewalld bez polityk - używam samego maskowania)"
        fi
    fi
    firewall-cmd --reload

    # 8. Usługi
    echo "==> Uruchamianie usług..."
    systemctl enable apache2 vsftpd dnsmasq
    systemctl restart apache2 vsftpd dnsmasq

    # 9. Testy
    echo
    echo "==> Testy"
    for s in firewalld apache2 vsftpd dnsmasq; do
        printf "  %-10s %s\n" "$s" "$(systemctl is-active "$s" || true)"
    done
    if curl -fsS -o /dev/null http://localhost; then echo "  WWW lokalnie: OK"; else echo "  WWW lokalnie: BŁĄD"; fi
    if [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]]; then echo "  Routing:      OK"; else echo "  Routing:      BŁĄD"; fi
    if ping -c1 -W2 8.8.8.8 &>/dev/null; then echo "  Internet:     OK"; else echo "  Internet:     BRAK (sprawdź WAN)"; fi

    echo
    echo "GOTOWE. Klient dostanie IP z puli ${BASE}.100-200 przez DHCP (brama/DNS: $LAN_IP)."
    echo "FTP: login $FTP_USER${FTP_PASS:+, hasło: $FTP_PASS}"
    echo "Na kliencie uruchom: sudo ./setup-www-ftp.sh client"
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
    confirm "Zastosować?" || { echo "Przerwano."; exit 0; }

    hostnamectl set-hostname "$NEW_HOSTNAME"
    if [[ $SKIP_NET -eq 0 ]]; then
        echo "==> Ustawianie sieci..."
        if [[ "$USE_DHCP" == "t" ]]; then
            apply_iface "$IFACE" dhcp
        else
            apply_iface "$IFACE" static "$CLIENT_IP" "$SRV_IP" "$SRV_IP,8.8.8.8"
        fi
        echo "==> Czekam na połączenie z serwerem..."
        for _ in $(seq 1 30); do
            ping -c1 -W1 "$SRV_IP" &>/dev/null && break
            sleep 1
        done
    fi
    add_hosts_entry "$SRV_IP" "$SRV_NAME"

    echo "==> Instalacja narzędzi klienckich..."
    zypper --non-interactive install curl wget lftp ftp

    echo
    echo "==> Testy"
    if ping -c1 -W2 "$SRV_IP" &>/dev/null;  then echo "  Serwer ($SRV_IP): OK";  else echo "  Serwer ($SRV_IP): BRAK"; fi
    if ping -c1 -W2 8.8.8.8 &>/dev/null;    then echo "  Internet:         OK";  else echo "  Internet:         BRAK"; fi
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
