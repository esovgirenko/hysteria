#!/usr/bin/env bash
# Server 2: fast WireGuard exit node for Server 1.
# Run this first on the exit VPS, then copy the exported params JSON to Server 1.

set -euo pipefail

readonly WG_IF="${WG_IF:-wg0}"
readonly WG_PORT="${WG_PORT:-51820}"
readonly WG_NET="${WG_NET:-10.77.0.0/24}"
readonly SERVER1_WG_IP="${SERVER1_WG_IP:-10.77.0.1}"
readonly SERVER2_WG_IP="${SERVER2_WG_IP:-10.77.0.2}"
readonly WG_MTU="${WG_MTU:-1420}"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly EXPORT_FILE="${CONFIG_DIR}/xhttp-wg-server1-params.json"
readonly WG_CONF="/etc/wireguard/${WG_IF}.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERR]${NC} $*"; }

check_root() {
    [[ $EUID -eq 0 ]] || { log_err "Запустите скрипт через sudo."; exit 1; }
}

install_deps() {
    log_info "Установка WireGuard и зависимостей..."
    apt-get update -qq
    apt-get install -y -qq wireguard-tools iproute2 iptables curl jq
}

get_external_ip() {
    local ip
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
        ip=$(curl -fsSL --max-time 5 "${url}" 2>/dev/null) && break
    done
    [[ -z "${ip:-}" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "${ip}"
}

get_default_iface() {
    ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i=="dev") {print $(i+1); exit}}'
}

setup_sysctl() {
    cat > /etc/sysctl.d/99-xhttp-wg-exit.conf << EOF
net.ipv4.ip_forward=1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
    sysctl --system >/dev/null
}

setup_firewall() {
    local default_iface="$1"
    command -v ufw >/dev/null 2>&1 || return 0
    ufw allow 22/tcp 2>/dev/null || true
    ufw allow "${WG_PORT}/udp" 2>/dev/null || true
    ufw route allow in on "${WG_IF}" out on "${default_iface}" 2>/dev/null || true
    ufw status | grep -q "Status: active" || echo "y" | ufw enable 2>/dev/null || true
}

main() {
    check_root
    install_deps

    local external_ip default_iface server_private server_public server1_private server1_public
    external_ip=$(get_external_ip)
    default_iface=$(get_default_iface)
    [[ -n "${default_iface}" ]] || { log_err "Не удалось определить внешний сетевой интерфейс."; exit 1; }

    umask 077
    server_private=$(wg genkey)
    server_public=$(printf '%s' "${server_private}" | wg pubkey)
    server1_private=$(wg genkey)
    server1_public=$(printf '%s' "${server1_private}" | wg pubkey)

    mkdir -p /etc/wireguard "${CONFIG_DIR}"

    if [[ -f "${WG_CONF}" ]]; then
        local ts
        ts=$(date +%Y%m%d-%H%M%S)
        cp -a "${WG_CONF}" "${WG_CONF}.bak.${ts}"
        log_warn "Сохранена резервная копия: ${WG_CONF}.bak.${ts}"
    fi

    cat > "${WG_CONF}" << EOF
[Interface]
Address = ${SERVER2_WG_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${server_private}
MTU = ${WG_MTU}
PostUp = iptables -A FORWARD -i ${WG_IF} -o ${default_iface} -j ACCEPT; iptables -A FORWARD -i ${default_iface} -o ${WG_IF} -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s ${WG_NET} -o ${default_iface} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${WG_IF} -o ${default_iface} -j ACCEPT; iptables -D FORWARD -i ${default_iface} -o ${WG_IF} -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s ${WG_NET} -o ${default_iface} -j MASQUERADE

[Peer]
PublicKey = ${server1_public}
AllowedIPs = ${SERVER1_WG_IP}/32
EOF
    chmod 600 "${WG_CONF}"

    setup_sysctl
    systemctl enable "wg-quick@${WG_IF}"
    systemctl restart "wg-quick@${WG_IF}"
    setup_firewall "${default_iface}"

    jq -n \
        --arg protocol "wireguard-exit" \
        --arg server2Host "${external_ip}" \
        --argjson wireguardPort "${WG_PORT}" \
        --arg serverPublicKey "${server_public}" \
        --arg server1PrivateKey "${server1_private}" \
        --arg server1Address "${SERVER1_WG_IP}/32" \
        --arg server2Address "${SERVER2_WG_IP}" \
        --argjson mtu "${WG_MTU}" \
        --arg table "51820" \
        '{
          protocol: $protocol,
          server2Host: $server2Host,
          wireguardPort: $wireguardPort,
          serverPublicKey: $serverPublicKey,
          server1PrivateKey: $server1PrivateKey,
          server1Address: $server1Address,
          server2Address: $server2Address,
          mtu: $mtu,
          routingTable: ($table | tonumber)
        }' > "${EXPORT_FILE}"
    chmod 600 "${EXPORT_FILE}"

    echo ""
    echo "=============================================="
    log_info "Сервер 2 готов как WireGuard exit-node."
    echo "=============================================="
    echo "Передайте этот файл на Сервер 1:"
    echo "  ${EXPORT_FILE}"
    echo ""
    echo "Откройте UDP ${WG_PORT} в панели хостинга."
    echo "Для безопасности ограничьте UDP ${WG_PORT} IP-адресом Сервера 1, если панель это умеет."
    echo "=============================================="
}

main "$@"
