#!/usr/bin/env bash
# Сервер 2 (зарубежный): Hysteria 2 резервный вход + Xray relay для сервера 1.
# Устанавливайте ПЕРВЫМ. Ubuntu 22.04 / Debian 12, root.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly RELAY_PORT="${RELAY_PORT:-8443}"
readonly CLIENT_PORT="${CLIENT_PORT:-443}"
readonly MASQUERADE_URL_DEFAULT="${MASQUERADE_URL_DEFAULT:-https://www.cloudflare.com/}"

main() {
    check_root
    install_deps
    install_xray
    install_geodata
    install_hysteria

    echo ""
    log_info "=== Сервер 2 (Hysteria 2 fallback + relay для сервера 1) ==="
    echo ""

    read -rp "UDP-порт Hysteria 2 для клиентов [${CLIENT_PORT}]: " PORT
    PORT="${PORT:-$CLIENT_PORT}"

    read -rp "Masquerade URL [${MASQUERADE_URL_DEFAULT}]: " MASQUERADE_URL
    MASQUERADE_URL="${MASQUERADE_URL:-$MASQUERADE_URL_DEFAULT}"

    RELAY_UUID=$(generate_uuid)
    EXTERNAL_IP=$(get_external_ip)
    RELAY_TLS_DIR=$(generate_relay_tls)
    HYSTERIA_TLS_DIR=$(generate_hysteria_tls "${EXTERNAL_IP}")
    AUTH_PASSWORD=$(generate_secret)
    OBFS_PASSWORD=$(generate_secret)
    CERT_PIN=$(hysteria_cert_pin "${HYSTERIA_TLS_DIR}/cert.pem")

    mkdir -p "${CONFIG_DIR}" "${HYSTERIA_CONFIG_DIR}"

    log_info "Внешний IP сервера 2: ${EXTERNAL_IP}"
    log_info "Relay UUID (для сервера 1): ${RELAY_UUID}"
    log_info "Relay порт: ${RELAY_PORT}"

    cat > "${CONFIG_FILE}" << EOF
{
  "log": { "loglevel": "error" },
  "inbounds": [
    {
      "port": ${RELAY_PORT},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${RELAY_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${RELAY_TLS_DIR}/cert.pem",
              "keyFile": "${RELAY_TLS_DIR}/key.pem"
            }
          ]
        }
      },
      "tag": "relay-in"
    }
  ],
  "outbounds": [
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
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["relay-in"],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

    cat > "${HYSTERIA_CONFIG_FILE}" << EOF
listen: :${PORT}

tls:
  cert: ${HYSTERIA_TLS_DIR}/cert.pem
  key: ${HYSTERIA_TLS_DIR}/key.pem

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

    validate_xray_config
    install_systemd
    install_hysteria_systemd
    setup_ufw_ports "${PORT}"
    setup_ufw_tcp_ports "${RELAY_PORT}"

    local client_info="${HYSTERIA_CONFIG_DIR}/hysteria-client-params.json"
    local relay_info="${CONFIG_DIR}/relay-server1-params.json"

    jq -n \
        --arg role "server2-fallback" \
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

    jq -n \
        --arg host "${EXTERNAL_IP}" \
        --argjson port "${RELAY_PORT}" \
        --arg uuid "${RELAY_UUID}" \
        --arg cert "${RELAY_TLS_DIR}/cert.pem" \
        '{
          server2Host: $host,
          relayPort: $port,
          relayUuid: $uuid,
          relayTlsCert: $cert,
          relaySni: "vpn-relay.internal"
        }' > "${relay_info}"

    chmod 600 "${CONFIG_FILE}" "${HYSTERIA_CONFIG_FILE}" "${client_info}" "${relay_info}"

    echo ""
    echo "=============================================="
    log_info "Сервер 2 установлен."
    echo "=============================================="
    echo "Файлы:"
    echo "  ${client_info}          — параметры для клиентов (резерв)"
    echo "  ${relay_info}           — передайте на сервер 1"
    echo ""
    echo "Откройте UDP ${PORT} и TCP ${RELAY_PORT} в панели хостинга."
    echo "Для безопасности TCP ${RELAY_PORT} лучше ограничить IP сервера 1."
    echo "=============================================="
}

main "$@"
