#!/usr/bin/env bash
# Сервер 1 (входной, РФ) для схемы Dual на Hysteria 2.
# Клиенты подключаются по Hysteria 2, локальный Xray-router делит трафик:
#   geoip:ru / geosite:category-ru -> direct
#   остальное -> relay на сервер 2

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly CLIENT_PORT="${CLIENT_PORT:-443}"
readonly XRAY_SOCKS_PORT="${XRAY_SOCKS_PORT:-10809}"
readonly RELAY_FILE_DEFAULT="${CONFIG_DIR}/relay-server1-params.json"
readonly MASQUERADE_URL_DEFAULT="${MASQUERADE_URL_DEFAULT:-https://music.yandex.ru/}"

RELAY_FILE=""
NON_INTERACTIVE=false

usage() {
    cat << 'EOF'
Использование: sudo ./install-server1.sh [опции]

Устанавливает сервер 1: Hysteria 2 для клиентов + Xray-router внутри.
Маршрутизация:
  geoip:ru / geosite:category-ru / geosite:yandex -> прямой выход
  остальное -> relay на сервер 2

Опции:
  --relay-file PATH   Файл relay-server1-params.json с сервера 2
  -y, --yes           Значения по умолчанию (порт 443)
  -h, --help          Справка

Перед запуском на сервере 2 выполните: sudo ./patch-server2.sh
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --relay-file) RELAY_FILE="$2"; shift 2 ;;
            -y|--yes) NON_INTERACTIVE=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) log_err "Неизвестный аргумент: $1"; usage; exit 1 ;;
        esac
    done
    [[ -z "${RELAY_FILE}" && -f "${RELAY_FILE_DEFAULT}" ]] && RELAY_FILE="${RELAY_FILE_DEFAULT}"
}

load_relay_params() {
    if [[ ! -f "${RELAY_FILE}" ]]; then
        log_err "Не найден ${RELAY_FILE}"
        log_err "Сначала на сервере 2: sudo ./patch-server2.sh"
        log_err "Затем скопируйте relay-server1-params.json в ${RELAY_FILE_DEFAULT}"
        exit 1
    fi
    SERVER2_HOST=$(jq -r '.server2Host' "${RELAY_FILE}")
    RELAY_PORT=$(jq -r '.relayPort' "${RELAY_FILE}")
    RELAY_UUID=$(jq -r '.relayUuid' "${RELAY_FILE}")
    RELAY_SNI=$(jq -r '.relaySni // "vpn-relay.internal"' "${RELAY_FILE}")
    local dest="${CONFIG_DIR}/relay-server1-params.json"
    local src_canon dest_canon
    src_canon=$(readlink -f "${RELAY_FILE}")
    dest_canon=$(readlink -f "${dest}" 2>/dev/null || true)
    if [[ "${src_canon}" != "${dest_canon}" ]]; then
        cp -f "${RELAY_FILE}" "${dest}"
        chmod 600 "${dest}"
    fi
    log_info "Relay: ${SERVER2_HOST}:${RELAY_PORT}"
}

prompt_or_default() {
    local var_name="$1"
    local prompt="$2"
    local default="$3"
    if [[ "${NON_INTERACTIVE}" == true ]]; then
        printf -v "${var_name}" '%s' "${default}"
        return
    fi
    read -rp "${prompt} [${default}]: " input
    printf -v "${var_name}" '%s' "${input:-$default}"
}

main() {
    parse_args "$@"
    check_root
    install_deps
    load_relay_params
    install_xray
    install_geodata
    install_hysteria

    echo ""
    log_info "=== Установка сервера 1 (Hysteria 2 + split RU / abroad) ==="
    echo ""

    local PORT MASQUERADE_URL
    prompt_or_default PORT "UDP-порт Hysteria 2 для клиентов" "${CLIENT_PORT}"
    prompt_or_default MASQUERADE_URL "Masquerade URL" "${MASQUERADE_URL_DEFAULT}"

    EXTERNAL_IP=$(get_external_ip)
    local tls_dir cert_pin auth_password obfs_password
    tls_dir=$(generate_hysteria_tls "${EXTERNAL_IP}")
    cert_pin=$(hysteria_cert_pin "${tls_dir}/cert.pem")
    auth_password=$(generate_secret)
    obfs_password=$(generate_secret)

    mkdir -p "${CONFIG_DIR}" "${HYSTERIA_CONFIG_DIR}"

    cat > "${CONFIG_FILE}" << EOF
{
  "log": { "loglevel": "error" },
  "dns": {
    "servers": [
      {
        "address": "https://dns.google/dns-query",
        "domains": ["geosite:geolocation-!cn"],
        "skipFallback": true
      },
      {
        "address": "https://common.dot.dns.yandex.net/dns-query",
        "domains": ["geosite:category-ru", "geosite:yandex"],
        "skipFallback": false
      },
      "localhost"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${XRAY_SOCKS_PORT},
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": true
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      },
      "tag": "hysteria-router-in"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${SERVER2_HOST}",
            "port": ${RELAY_PORT},
            "users": [
              {
                "id": "${RELAY_UUID}",
                "encryption": "none",
                "flow": "xtls-rprx-vision"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${RELAY_SNI}",
          "allowInsecure": true,
          "fingerprint": "chrome"
        }
      },
      "tag": "proxy-abroad"
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
        "ip": ["geoip:ru"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": ["geosite:category-ru", "geosite:yandex"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "proxy-abroad"
      }
    ]
  }
}
EOF

    cat > "${HYSTERIA_CONFIG_FILE}" << EOF
listen: :${PORT}

tls:
  cert: ${tls_dir}/cert.pem
  key: ${tls_dir}/key.pem

auth:
  type: password
  password: ${auth_password}

obfs:
  type: salamander
  salamander:
    password: ${obfs_password}

sniff:
  enable: true
  timeout: 2s
  rewriteDomain: false

outbounds:
  - name: xray-router
    type: socks5
    socks5:
      addr: 127.0.0.1:${XRAY_SOCKS_PORT}

acl:
  inline:
    - xray-router(all)

masquerade:
  type: proxy
  proxy:
    url: ${MASQUERADE_URL}
    rewriteHost: true
EOF

    log_info "Проверка Xray config.json..."
    validate_xray_config
    install_systemd
    install_hysteria_systemd
    setup_ufw_ports "${PORT}"

    local client_info="${HYSTERIA_CONFIG_DIR}/hysteria-client-params.json"
    jq -n \
        --arg role "server1-main" \
        --arg host "${EXTERNAL_IP}" \
        --argjson port "${PORT}" \
        --arg auth "${auth_password}" \
        --arg obfs "${obfs_password}" \
        --arg pin "${cert_pin}" \
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
    chmod 600 "${CONFIG_FILE}" "${HYSTERIA_CONFIG_FILE}" "${client_info}"

    echo ""
    echo "=============================================="
    log_info "Сервер 1 установлен."
    echo "=============================================="
    echo "Клиентские параметры:"
    echo "  ${client_info}"
    echo ""
    echo "Откройте UDP ${PORT} в панели хостинга, если firewall хостинга не управляется UFW."
    echo "=============================================="
}

main "$@"
