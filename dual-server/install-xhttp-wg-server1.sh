#!/usr/bin/env bash
# Server 1: public VLESS + XHTTP behind Caddy, with client traffic exiting through Server 2 over WireGuard.

set -euo pipefail

readonly XRAY_VERSION="${XRAY_VERSION:-26.2.6}"
readonly INSTALL_DIR="/usr/local/bin"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly CLIENT_INFO="${CONFIG_DIR}/vless-xhttp-client-params.json"
readonly WG_PARAMS_DEFAULT="${CONFIG_DIR}/xhttp-wg-server1-params.json"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly WEB_ROOT="${WEB_ROOT:-/var/www/xhttp-site}"
readonly XRAY_LISTEN="${XRAY_LISTEN:-127.0.0.1}"
readonly XRAY_PORT="${XRAY_PORT:-10085}"
readonly XHTTP_MODE="${XHTTP_MODE:-packet-up}"
readonly WG_IF="${WG_IF:-wg0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERR]${NC} $*"; }

WG_PARAMS=""
NON_INTERACTIVE=false

usage() {
    cat << 'EOF'
Использование: sudo ./dual-server/install-xhttp-wg-server1.sh [опции]

Сервер 1:
  - принимает клиентов по VLESS + XHTTP + Caddy на домене;
  - отправляет клиентский трафик через Сервер 2 по WireGuard;
  - не меняет системный default route, SSH остаётся через обычный интерфейс.

Опции:
  --wg-params PATH   JSON с сервера 2, по умолчанию /usr/local/etc/xray/xhttp-wg-server1-params.json
  -y, --yes          Не задавать лишних вопросов, кроме домена/email/path
  -h, --help         Справка
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --wg-params) WG_PARAMS="$2"; shift 2 ;;
            -y|--yes) NON_INTERACTIVE=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) log_err "Неизвестный аргумент: $1"; usage; exit 1 ;;
        esac
    done
    [[ -z "${WG_PARAMS}" ]] && WG_PARAMS="${WG_PARAMS_DEFAULT}"
}

check_root() {
    [[ $EUID -eq 0 ]] || { log_err "Запустите скрипт через sudo."; exit 1; }
}

get_xray_arch() {
    case "$(uname -m)" in
        x86_64) echo "64" ;;
        aarch64|arm64) echo "arm64-v8a" ;;
        armv7l) echo "arm32-v7a" ;;
        *) log_err "Неподдерживаемая архитектура: $(uname -m)"; exit 1 ;;
    esac
}

install_deps() {
    log_info "Установка зависимостей..."
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates jq unzip openssl gnupg debian-keyring debian-archive-keyring apt-transport-https wireguard-tools iproute2
}

install_caddy() {
    if command -v caddy >/dev/null 2>&1; then
        log_info "Caddy уже установлен: $(caddy version | head -1)"
        return
    fi

    log_info "Установка Caddy..."
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor \
        > /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt-get install -y -qq caddy
}

install_xray() {
    if [[ -x "${INSTALL_DIR}/xray" ]]; then
        log_info "Xray уже установлен: $(${INSTALL_DIR}/xray version | head -1)"
        return
    fi

    local arch_suffix url zip_file
    arch_suffix=$(get_xray_arch)
    url="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${arch_suffix}.zip"
    zip_file="/tmp/xray-${XRAY_VERSION}.zip"

    log_info "Скачивание Xray-core v${XRAY_VERSION}..."
    curl -fSL --connect-timeout 10 --max-time 300 -o "${zip_file}" "${url}"
    mkdir -p "${CONFIG_DIR}"
    rm -rf /tmp/xray-extract
    unzip -o -q "${zip_file}" -d /tmp/xray-extract
    local xray_bin
    xray_bin=$(find /tmp/xray-extract -maxdepth 2 -type f \( -name 'xray' -o -name 'Xray' \) | head -1)
    cp -f "${xray_bin}" "${INSTALL_DIR}/xray"
    chmod +x "${INSTALL_DIR}/xray"
    rm -rf /tmp/xray-extract "${zip_file}"
}

backup_file() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    cp -a "${file}" "${file}.bak.${ts}"
    log_info "Резервная копия: ${file}.bak.${ts}"
}

generate_uuid() {
    "${INSTALL_DIR}/xray" uuid 2>/dev/null || uuidgen
}

random_path() {
    printf "/assets/%s/api" "$(openssl rand -hex 8)"
}

get_external_ip() {
    local ip
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
        ip=$(curl -fsSL --max-time 5 "${url}" 2>/dev/null) && break
    done
    [[ -z "${ip:-}" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "${ip}"
}

check_domain_dns() {
    local domain="$1"
    local external_ip="$2"
    local resolved
    resolved=$(getent ahosts "${domain}" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)
    if [[ -z "${resolved}" ]]; then
        log_warn "Не удалось проверить DNS для ${domain}. Убедитесь, что A/AAAA указывает на этот VPS."
        return 0
    fi
    if [[ " ${resolved} " != *" ${external_ip} "* ]]; then
        log_warn "DNS ${domain} сейчас резолвится в: ${resolved}"
        log_warn "Внешний IP этого VPS: ${external_ip}"
        read -rp "Продолжить всё равно? (y/N): " answer
        [[ "${answer,,}" == "y" ]] || exit 1
    fi
}

load_wg_params() {
    [[ -f "${WG_PARAMS}" ]] || {
        log_err "Не найден ${WG_PARAMS}"
        log_err "Сначала выполните на Сервере 2: sudo ./dual-server/install-xhttp-wg-server2.sh"
        log_err "Затем скопируйте xhttp-wg-server1-params.json на Сервер 1 в ${WG_PARAMS_DEFAULT}"
        exit 1
    }
    WG_SERVER2_HOST=$(jq -r '.server2Host' "${WG_PARAMS}")
    WG_PORT=$(jq -r '.wireguardPort' "${WG_PARAMS}")
    WG_SERVER_PUBLIC_KEY=$(jq -r '.serverPublicKey' "${WG_PARAMS}")
    WG_PRIVATE_KEY=$(jq -r '.server1PrivateKey' "${WG_PARAMS}")
    WG_ADDRESS=$(jq -r '.server1Address' "${WG_PARAMS}")
    WG_SOURCE_IP="${WG_ADDRESS%%/*}"
    WG_MTU=$(jq -r '.mtu // 1420' "${WG_PARAMS}")
    WG_TABLE=$(jq -r '.routingTable // 51820' "${WG_PARAMS}")
    [[ -n "${WG_SERVER2_HOST}" && -n "${WG_PORT}" && -n "${WG_SERVER_PUBLIC_KEY}" && -n "${WG_PRIVATE_KEY}" && -n "${WG_SOURCE_IP}" ]] || {
        log_err "Файл WireGuard-параметров неполный: ${WG_PARAMS}"
        exit 1
    }
}

write_wireguard_config() {
    local wg_conf="/etc/wireguard/${WG_IF}.conf"
    mkdir -p /etc/wireguard
    backup_file "${wg_conf}"
    cat > "${wg_conf}" << EOF
[Interface]
Address = ${WG_ADDRESS}
PrivateKey = ${WG_PRIVATE_KEY}
MTU = ${WG_MTU}
Table = off
PostUp = ip route replace default dev ${WG_IF} table ${WG_TABLE}; ip rule add from ${WG_SOURCE_IP}/32 table ${WG_TABLE} priority 100 2>/dev/null || true
PostDown = ip rule del from ${WG_SOURCE_IP}/32 table ${WG_TABLE} priority 100 2>/dev/null || true; ip route flush table ${WG_TABLE}

[Peer]
PublicKey = ${WG_SERVER_PUBLIC_KEY}
Endpoint = ${WG_SERVER2_HOST}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    chmod 600 "${wg_conf}"
    systemctl enable "wg-quick@${WG_IF}"
    systemctl restart "wg-quick@${WG_IF}"
}

write_site() {
    local domain="$1"
    mkdir -p "${WEB_ROOT}/assets" "${WEB_ROOT}/status"
    cat > "${WEB_ROOT}/index.html" << EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${domain}</title>
  <style>
    body { margin: 0; font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; color: #1f2937; background: #f8fafc; }
    main { max-width: 760px; margin: 12vh auto; padding: 0 24px; }
    h1 { font-size: 32px; font-weight: 650; margin: 0 0 12px; }
    p { font-size: 17px; line-height: 1.6; margin: 0 0 12px; }
  </style>
</head>
<body>
  <main>
    <h1>${domain}</h1>
    <p>This service is online.</p>
    <p>Static assets and status pages are served normally over HTTPS.</p>
  </main>
</body>
</html>
EOF
    cat > "${WEB_ROOT}/status/health.json" << EOF
{"status":"ok","service":"${domain}"}
EOF
}

write_xray_config() {
    local uuid="$1"
    local path="$2"
    cat > "${CONFIG_FILE}" << EOF
{
  "log": {
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "listen": "${XRAY_LISTEN}",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${uuid}",
            "email": "main@xhttp-wg"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "${path}",
          "mode": "${XHTTP_MODE}"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      },
      "tag": "vless-xhttp-in"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "sendThrough": "${WG_SOURCE_IP}",
      "settings": {
        "domainStrategy": "UseIPv4"
      },
      "tag": "wg-exit"
    },
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": ["geosite:private"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "wg-exit"
      }
    ]
  }
}
EOF
}

write_caddyfile() {
    local domain="$1"
    local email="$2"
    local path="$3"
    local path_match="${path}*"
    cat > "${CADDYFILE}" << EOF
{
  email ${email}
  servers {
    protocols h1 h2
  }
}

${domain} {
  encode zstd gzip
  root * ${WEB_ROOT}

  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    X-Content-Type-Options "nosniff"
    Referrer-Policy "strict-origin-when-cross-origin"
  }

  handle ${path_match} {
    reverse_proxy ${XRAY_LISTEN}:${XRAY_PORT} {
      transport http {
        versions h2c 2
      }
      header_up Host {host}
      header_up X-Real-IP {remote_host}
    }
  }

  handle {
    file_server
  }
}
EOF
}

install_xray_systemd() {
    cat > /etc/systemd/system/xray.service << EOF
[Unit]
Description=Xray VLESS XHTTP WireGuard Exit Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target wg-quick@${WG_IF}.service
Wants=wg-quick@${WG_IF}.service

[Service]
Type=simple
ExecStart=${INSTALL_DIR}/xray run -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
    sleep 1
    systemctl is-active --quiet xray || {
        log_err "Xray не запустился. journalctl -u xray -n 50"
        exit 1
    }
}

setup_firewall() {
    command -v ufw >/dev/null 2>&1 || return 0
    ufw allow 22/tcp 2>/dev/null || true
    ufw allow 80/tcp 2>/dev/null || true
    ufw allow 443/tcp 2>/dev/null || true
    ufw status | grep -q "Status: active" || echo "y" | ufw enable 2>/dev/null || true
}

write_client_params() {
    local host="$1"
    local uuid="$2"
    local path="$3"
    jq -n \
        --arg protocol "vless-xhttp" \
        --arg role "server1-xhttp-wg" \
        --arg host "${host}" \
        --arg uuid "${uuid}" \
        --arg path "${path}" \
        --arg mode "${XHTTP_MODE}" \
        '{
          protocol: $protocol,
          role: $role,
          serverHost: $host,
          serverPort: 443,
          uuid: $uuid,
          security: "tls",
          network: "xhttp",
          path: $path,
          mode: $mode,
          sni: $host,
          insecure: false,
          alpn: ["h2", "http/1.1"]
        }' > "${CLIENT_INFO}"
    chmod 600 "${CONFIG_FILE}" "${CLIENT_INFO}"
}

main() {
    parse_args "$@"
    check_root
    load_wg_params
    install_deps
    install_xray
    install_caddy

    echo ""
    log_info "=== Сервер 1: VLESS + XHTTP + домен, выход через WireGuard Server 2 ==="
    read -rp "Домен, который уже указывает A/AAAA на Сервер 1: " DOMAIN
    [[ -n "${DOMAIN}" ]] || { log_err "Для маскирования нужен домен на Сервере 1."; exit 1; }
    read -rp "Email для Let's Encrypt: " EMAIL
    [[ -n "${EMAIL}" ]] || { log_err "Email обязателен для Let's Encrypt."; exit 1; }
    read -rp "Скрытый XHTTP path [авто]: " XHTTP_PATH
    XHTTP_PATH="${XHTTP_PATH:-$(random_path)}"
    [[ "${XHTTP_PATH}" == /* ]] || XHTTP_PATH="/${XHTTP_PATH}"

    local external_ip uuid
    external_ip=$(get_external_ip)
    uuid=$(generate_uuid)
    check_domain_dns "${DOMAIN}" "${external_ip}"

    mkdir -p "${CONFIG_DIR}" "$(dirname "${CADDYFILE}")"
    backup_file "${CONFIG_FILE}"
    backup_file "${CADDYFILE}"

    log_info "Настройка WireGuard до Server 2: ${WG_SERVER2_HOST}:${WG_PORT}"
    write_wireguard_config
    write_site "${DOMAIN}"
    write_xray_config "${uuid}" "${XHTTP_PATH}"
    write_caddyfile "${DOMAIN}" "${EMAIL}" "${XHTTP_PATH}"

    log_info "Проверка Xray config.json..."
    "${INSTALL_DIR}/xray" run -test -config "${CONFIG_FILE}"

    install_xray_systemd
    caddy validate --config "${CADDYFILE}"
    caddy fmt --overwrite "${CADDYFILE}"
    systemctl enable caddy
    systemctl restart caddy
    setup_firewall
    write_client_params "${DOMAIN}" "${uuid}" "${XHTTP_PATH}"

    echo ""
    echo "=============================================="
    log_info "Сервер 1 установлен."
    echo "=============================================="
    echo "Клиентские параметры:"
    echo "  ${CLIENT_INFO}"
    echo ""
    echo "Проверка:"
    echo "  curl -I https://${DOMAIN}/"
    echo "  wg show ${WG_IF}"
    echo "  ip rule | grep ${WG_SOURCE_IP}"
    echo "=============================================="
}

main "$@"
