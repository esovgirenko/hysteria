#!/usr/bin/env bash
# Патч существующей установки VPN-XRAY на сервере 2:
# добавляет Hysteria 2 fallback для клиентов и relay inbound :8443 для сервера 1.
#
# Запуск на уже работающем VPS с VPN-XRAY:
#   sudo ./patch-server2.sh
#   sudo ./patch-server2.sh --server1-ip 203.0.113.1
#   sudo ./patch-server2.sh --relay-port 8443

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

RELAY_PORT="${RELAY_PORT:-8443}"
HYSTERIA_PORT="${HYSTERIA_PORT:-443}"
MASQUERADE_URL="${MASQUERADE_URL:-https://www.cloudflare.com/}"
readonly RELAY_SNI="vpn-relay.internal"
readonly RELAY_PARAMS="${CONFIG_DIR}/relay-server1-params.json"
readonly HYSTERIA_CLIENT_PARAMS="${HYSTERIA_CONFIG_DIR}/hysteria-client-params.json"

SERVER1_IP=""

usage() {
    cat << 'EOF'
Использование: sudo ./patch-server2.sh [опции]

Добавляет на сервер 2 (уже с VPN-XRAY) Hysteria 2 fallback и relay от сервера 1.
Существующий REALITY TCP :443 и reality-client-params.json не меняются.

Опции:
  --server1-ip IP    Ограничить relay-порт 8443 в UFW только этим IP (рекомендуется)
  --relay-port PORT  Порт relay [8443]
  --hy2-port PORT    UDP-порт Hysteria 2 [443]
  --masquerade URL   URL маскировки Hysteria 2 [https://www.cloudflare.com/]
  -h, --help         Справка

После выполнения скопируйте на сервер 1:
  scp root@THIS_SERVER:/usr/local/etc/xray/relay-server1-params.json .
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --server1-ip) SERVER1_IP="$2"; shift 2 ;;
            --relay-port) RELAY_PORT="$2"; shift 2 ;;
            --hy2-port) HYSTERIA_PORT="$2"; shift 2 ;;
            --masquerade) MASQUERADE_URL="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) log_err "Неизвестный аргумент: $1"; usage; exit 1 ;;
        esac
    done
}

relay_already_exists() {
    jq -e '.inbounds[]? | select(.tag == "relay-in")' "${CONFIG_FILE}" >/dev/null 2>&1
}

get_existing_relay_uuid() {
    jq -r '.inbounds[] | select(.tag == "relay-in") | .settings.clients[0].id' "${CONFIG_FILE}" 2>/dev/null | head -1
}

get_existing_relay_port() {
    jq -r '.inbounds[] | select(.tag == "relay-in") | .port' "${CONFIG_FILE}" 2>/dev/null | head -1
}

apply_patch() {
    local relay_uuid="$1"
    local relay_tls_dir="$2"
    local tmp
    tmp=$(mktemp)

    jq \
        --argjson relay_port "${RELAY_PORT}" \
        --arg relay_uuid "${relay_uuid}" \
        --arg cert "${relay_tls_dir}/cert.pem" \
        --arg key "${relay_tls_dir}/key.pem" \
        --arg relay_sni "${RELAY_SNI}" \
        '
        # Тег freedom → direct (нужен для routing)
        .outbounds |= map(
            if .protocol == "freedom" then . + {"tag": "direct"}
            else .
            end
        )
        | if ([.outbounds[]? | select(.tag == "direct")] | length) == 0 then
            .outbounds += [{"protocol": "freedom", "tag": "direct"}]
          else . end
        | if ([.inbounds[]? | select(.tag == "relay-in")] | length) > 0 then
            .
          else
            .inbounds += [{
              "port": $relay_port,
              "listen": "0.0.0.0",
              "protocol": "vless",
              "settings": {
                "clients": [{"id": $relay_uuid, "flow": "xtls-rprx-vision"}],
                "decryption": "none"
              },
              "streamSettings": {
                "network": "tcp",
                "security": "tls",
                "tlsSettings": {
                  "certificates": [{
                    "certificateFile": $cert,
                    "keyFile": $key
                  }]
                }
              },
              "tag": "relay-in"
            }]
          end
        | .routing = (.routing // {"domainStrategy": "AsIs", "rules": []})
        | .routing.rules = (
            (.routing.rules // [])
            | map(select(.inboundTag != ["relay-in"]))
          ) + [{
            "type": "field",
            "inboundTag": ["relay-in"],
            "outboundTag": "direct"
          }]
        ' "${CONFIG_FILE}" > "${tmp}"

    mv "${tmp}" "${CONFIG_FILE}"
    chmod 600 "${CONFIG_FILE}"
}

write_relay_params() {
    local relay_uuid="$1"
    local external_ip
    external_ip=$(get_external_ip)

    jq -n \
        --arg host "${external_ip}" \
        --argjson port "${RELAY_PORT}" \
        --arg uuid "${relay_uuid}" \
        --arg sni "${RELAY_SNI}" \
        '{
          server2Host: $host,
          relayPort: ($port | tonumber),
          relayUuid: $uuid,
          relaySni: $sni
        }' > "${RELAY_PARAMS}"
    chmod 600 "${RELAY_PARAMS}"
}

write_hysteria_config() {
    local external_ip auth_password obfs_password tls_dir cert_pin
    external_ip=$(get_external_ip)
    auth_password=$(generate_secret)
    obfs_password=$(generate_secret)
    tls_dir=$(generate_hysteria_tls "${external_ip}")
    cert_pin=$(hysteria_cert_pin "${tls_dir}/cert.pem")

    mkdir -p "${HYSTERIA_CONFIG_DIR}"
    cat > "${HYSTERIA_CONFIG_FILE}" << EOF
listen: :${HYSTERIA_PORT}

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

masquerade:
  type: proxy
  proxy:
    url: ${MASQUERADE_URL}
    rewriteHost: true
EOF

    jq -n \
        --arg role "server2-fallback" \
        --arg host "${external_ip}" \
        --argjson port "${HYSTERIA_PORT}" \
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
        }' > "${HYSTERIA_CLIENT_PARAMS}"
    chmod 600 "${HYSTERIA_CONFIG_FILE}" "${HYSTERIA_CLIENT_PARAMS}"
}

main() {
    parse_args "$@"
    check_root
    require_xray_installed
    if ! command -v jq &>/dev/null || ! command -v curl &>/dev/null || ! command -v openssl &>/dev/null; then
        install_deps
    fi
    install_hysteria

    echo ""
    log_info "=== Патч сервера 2 (существующий VPN-XRAY) ==="
    log_info "REALITY для клиентов не изменяется; добавляется Hysteria 2 UDP :${HYSTERIA_PORT}."
    echo ""

    if relay_already_exists; then
        log_warn "Relay inbound (relay-in) уже есть в конфиге."
        RELAY_UUID=$(get_existing_relay_uuid)
        existing_port=$(get_existing_relay_port)
        [[ -n "${existing_port}" && "${existing_port}" != "null" ]] && RELAY_PORT="${existing_port}"
        log_info "Используем существующий relay UUID: ${RELAY_UUID}, порт: ${RELAY_PORT}"
    else
        RELAY_UUID=$(generate_uuid)
        log_info "Новый relay UUID: ${RELAY_UUID}"
    fi

    if [[ -z "${SERVER1_IP}" ]]; then
        read -rp "IP сервера 1 (для UFW, Enter = не ограничивать): " SERVER1_IP
    fi

    backup_config
    local relay_tls_dir
    relay_tls_dir=$(generate_relay_tls)
    apply_patch "${RELAY_UUID}" "${relay_tls_dir}"

    log_info "Проверка конфигурации..."
    validate_xray_config

    # Пишем параметры до restart/ufw — при обрыве SSH файл уже будет на диске
    write_relay_params "${RELAY_UUID}"
    log_info "Параметры для сервера 1: ${RELAY_PARAMS}"
    write_hysteria_config
    log_info "Параметры Hysteria 2 для клиентов: ${HYSTERIA_CLIENT_PARAMS}"

    restart_xray
    install_hysteria_systemd
    setup_ufw_relay_from_ip "${RELAY_PORT}" "${SERVER1_IP}"
    setup_ufw_ports "${HYSTERIA_PORT}"

    echo ""
    echo "=============================================="
    log_info "Сервер 2 обновлён."
    echo "=============================================="
    echo "Файл для сервера 1:"
    echo "  ${RELAY_PARAMS}"
    echo ""
    echo "Скопируйте на сервер 1 и запустите install-server1.sh:"
    echo "  scp root@$(get_external_ip):${RELAY_PARAMS} ."
    echo "  scp relay-server1-params.json root@SERVER1_IP:/usr/local/etc/xray/"
    echo "  ssh root@SERVER1_IP 'cd /opt/vpn-xray/dual-server && sudo ./install-server1.sh'"
    echo ""
    echo "Резервный профиль Hysteria 2:"
    echo "  ${HYSTERIA_CLIENT_PARAMS}"
    echo "=============================================="
}

main "$@"
