#!/usr/bin/env bash
# Установка одиночного сервера Hysteria 2 на Ubuntu 22.04 / Debian 12.

set -euo pipefail

readonly HYSTERIA_BIN="${HYSTERIA_BIN:-/usr/local/bin/hysteria}"
readonly HYSTERIA_CONFIG_DIR="${HYSTERIA_CONFIG_DIR:-/etc/hysteria}"
readonly HYSTERIA_CONFIG_FILE="${HYSTERIA_CONFIG_FILE:-${HYSTERIA_CONFIG_DIR}/config.yaml}"
readonly CLIENT_PORT="${CLIENT_PORT:-443}"
readonly MASQUERADE_URL_DEFAULT="${MASQUERADE_URL_DEFAULT:-https://www.cloudflare.com/}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()   { echo -e "${RED}[ERR]${NC} $*"; }

check_root() {
    [[ $EUID -eq 0 ]] || { log_err "Запустите скрипт с правами root (sudo)."; exit 1; }
}

get_hysteria_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l) echo "arm" ;;
        *) log_err "Неподдерживаемая архитектура: $(uname -m)"; exit 1 ;;
    esac
}

install_deps() {
    log_info "Установка зависимостей..."
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates jq openssl
}

install_hysteria() {
    if [[ -x "${HYSTERIA_BIN}" ]]; then
        log_info "Hysteria уже установлена: $(${HYSTERIA_BIN} version 2>/dev/null | head -1 || true)"
        return 0
    fi
    local arch url
    arch=$(get_hysteria_arch)
    url="https://download.hysteria.network/app/latest/hysteria-linux-${arch}"
    log_info "Скачивание Hysteria 2..."
    curl -fSL --connect-timeout 10 --max-time 300 -o "${HYSTERIA_BIN}" "${url}"
    chmod +x "${HYSTERIA_BIN}"
}

generate_secret() {
    openssl rand -base64 24 | tr -d '\n'
}

get_external_ip() {
    local ip
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
        ip=$(curl -fsSL --max-time 5 "${url}" 2>/dev/null) && break
    done
    [[ -z "${ip}" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "${ip}"
}

generate_tls() {
    local cert_dir="${HYSTERIA_CONFIG_DIR}/tls"
    local cn="${1:-hysteria.local}"
    mkdir -p "${cert_dir}"
    if [[ ! -f "${cert_dir}/cert.pem" || ! -f "${cert_dir}/key.pem" ]]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "${cert_dir}/key.pem" \
            -out "${cert_dir}/cert.pem" \
            -subj "/CN=${cn}" 2>/dev/null
        chmod 600 "${cert_dir}/key.pem"
    fi
    echo "${cert_dir}"
}

cert_pin() {
    local cert="$1"
    openssl x509 -in "${cert}" -pubkey -noout |
        openssl pkey -pubin -outform der |
        openssl dgst -sha256 -binary |
        openssl base64 -A
}

install_systemd() {
    cat > /etc/systemd/system/hysteria.service << SVCEOF
[Unit]
Description=Hysteria 2 VPN Service
Documentation=https://v2.hysteria.network/
After=network.target

[Service]
Type=simple
ExecStart=${HYSTERIA_BIN} server -c ${HYSTERIA_CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable hysteria
    systemctl restart hysteria
    sleep 1
    systemctl is-active --quiet hysteria || {
        log_err "Hysteria не запустилась. journalctl -u hysteria -n 50"
        exit 1
    }
}

setup_ufw() {
    local port="$1"
    command -v ufw &>/dev/null || return 0
    ufw allow "${port}/udp" 2>/dev/null || true
    ufw allow 22/tcp 2>/dev/null || true
    echo "y" | ufw enable 2>/dev/null || true
}

main() {
    check_root
    install_deps
    install_hysteria

    echo ""
    log_info "=== Установка Hysteria 2 (один сервер) ==="
    read -rp "UDP-порт Hysteria 2 [${CLIENT_PORT}]: " PORT
    PORT="${PORT:-$CLIENT_PORT}"
    read -rp "Masquerade URL [${MASQUERADE_URL_DEFAULT}]: " MASQUERADE_URL
    MASQUERADE_URL="${MASQUERADE_URL:-$MASQUERADE_URL_DEFAULT}"

    EXTERNAL_IP=$(get_external_ip)
    TLS_DIR=$(generate_tls "${EXTERNAL_IP}")
    AUTH_PASSWORD=$(generate_secret)
    OBFS_PASSWORD=$(generate_secret)
    CERT_PIN=$(cert_pin "${TLS_DIR}/cert.pem")

    cat > "${HYSTERIA_CONFIG_FILE}" << EOF
listen: :${PORT}

tls:
  cert: ${TLS_DIR}/cert.pem
  key: ${TLS_DIR}/key.pem

auth:
  type: password
  password: ${AUTH_PASSWORD}

obfs:
  type: salamander
  salamander:
    password: ${OBFS_PASSWORD}

masquerade:
  type: proxy
  proxy:
    url: ${MASQUERADE_URL}
    rewriteHost: true
EOF

    install_systemd
    setup_ufw "${PORT}"

    local client_info="${HYSTERIA_CONFIG_DIR}/hysteria-client-params.json"
    jq -n \
        --arg role "single" \
        --arg host "${EXTERNAL_IP}" \
        --argjson port "${PORT}" \
        --arg auth "${AUTH_PASSWORD}" \
        --arg obfs "${OBFS_PASSWORD}" \
        --arg pin "${CERT_PIN}" \
        --arg masquerade "${MASQUERADE_URL}" \
        '{
          protocol: "hysteria2",
          role: $role,
          serverHost: $host,
          serverPort: $port,
          auth: $auth,
          obfs: "salamander",
          obfsPassword: $obfs,
          insecure: true,
          pinSHA256: $pin,
          masqueradeUrl: $masquerade
        }' > "${client_info}"
    chmod 600 "${HYSTERIA_CONFIG_FILE}" "${client_info}"

    echo ""
    echo "=============================================="
    log_info "Hysteria 2 установлена."
    echo "=============================================="
    echo "Клиентские параметры:"
    echo "  ${client_info}"
    echo ""
    echo "Откройте UDP ${PORT} в панели хостинга."
    echo "=============================================="
}

main "$@"
