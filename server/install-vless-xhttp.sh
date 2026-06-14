#!/usr/bin/env bash
# Установка VLESS + XHTTP за Caddy на Ubuntu 22.04 / Debian 12.
# Caddy принимает обычный HTTPS и отдаёт сайт, Xray слушает только localhost.

set -euo pipefail

readonly XRAY_VERSION="${XRAY_VERSION:-26.2.6}"
readonly INSTALL_DIR="/usr/local/bin"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly CLIENT_INFO="${CONFIG_DIR}/vless-xhttp-client-params.json"
readonly CADDYFILE="/etc/caddy/Caddyfile"
readonly WEB_ROOT="${WEB_ROOT:-/var/www/xhttp-site}"
readonly XRAY_LISTEN="${XRAY_LISTEN:-127.0.0.1}"
readonly XRAY_PORT="${XRAY_PORT:-10085}"
readonly XHTTP_MODE="${XHTTP_MODE:-packet-up}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()  { echo -e "${RED}[ERR]${NC} $*"; }

check_root() {
    [[ $EUID -eq 0 ]] || { log_err "Запустите скрипт с правами root (sudo)."; exit 1; }
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
    apt-get install -y -qq curl ca-certificates jq unzip openssl gnupg debian-keyring debian-archive-keyring apt-transport-https
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
    [[ -z "${ip}" ]] && ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "${ip}"
}

check_domain_dns() {
    local domain="$1"
    local external_ip="$2"
    local resolved
    resolved=$(getent ahosts "${domain}" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)
    if [[ -z "${resolved}" ]]; then
        log_warn "Не удалось проверить DNS для ${domain}. Убедитесь, что A/AAAA уже указывает на этот VPS."
        return 0
    fi
    if [[ " ${resolved} " != *" ${external_ip} "* ]]; then
        log_warn "DNS ${domain} сейчас резолвится в: ${resolved}"
        log_warn "Внешний IP этого VPS: ${external_ip}"
        log_warn "Let's Encrypt может не выдать сертификат, пока DNS не указывает на этот сервер."
        read -rp "Продолжить всё равно? (y/N): " answer
        [[ "${answer,,}" == "y" ]] || exit 1
    fi
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
    a { color: #2563eb; }
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
    mkdir -p "${CONFIG_DIR}"
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
            "email": "main@xhttp"
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
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ]
}
EOF
}

write_caddyfile() {
    local site_label="$1"
    local email="$2"
    local path="$3"
    local internal_tls="$4"
    local path_match="${path}*"
    mkdir -p "$(dirname "${CADDYFILE}")"
    if [[ "${internal_tls}" == "true" ]]; then
        cat > "${CADDYFILE}" << EOF
https://${site_label} {
  tls internal
  encode zstd gzip
  root * ${WEB_ROOT}

  header {
    X-Content-Type-Options "nosniff"
    Referrer-Policy "strict-origin-when-cross-origin"
  }

  handle ${path_match} {
    reverse_proxy ${XRAY_LISTEN}:${XRAY_PORT} {
      header_up Host {host}
      header_up X-Real-IP {remote_host}
    }
  }

  handle {
    file_server
  }
}
EOF
        return
    fi

    cat > "${CADDYFILE}" << EOF
{
  email ${email}
}

${site_label} {
  encode zstd gzip
  root * ${WEB_ROOT}

  header {
    Strict-Transport-Security "max-age=31536000; includeSubDomains; preload"
    X-Content-Type-Options "nosniff"
    Referrer-Policy "strict-origin-when-cross-origin"
  }

  handle ${path_match} {
    reverse_proxy ${XRAY_LISTEN}:${XRAY_PORT} {
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
Description=Xray VLESS XHTTP Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target

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
    local insecure="$4"
    local sni="$5"
    jq -n \
        --arg protocol "vless-xhttp" \
        --arg host "${host}" \
        --arg uuid "${uuid}" \
        --arg path "${path}" \
        --arg mode "${XHTTP_MODE}" \
        --argjson insecure "${insecure}" \
        --arg sni "${sni}" \
        '{
          protocol: $protocol,
          serverHost: $host,
          serverPort: 443,
          uuid: $uuid,
          security: "tls",
          network: "xhttp",
          path: $path,
          mode: $mode,
          insecure: $insecure,
          alpn: ["h2", "http/1.1"]
        } + (if $sni | length > 0 then {sni: $sni} else {} end)' > "${CLIENT_INFO}"
    chmod 600 "${CONFIG_FILE}" "${CLIENT_INFO}"
}

main() {
    check_root
    install_deps
    install_xray
    install_caddy

    echo ""
    log_info "=== Установка VLESS + XHTTP + Caddy ==="
    read -rp "Домен, который уже указывает A/AAAA на этот VPS (Enter = временно без домена): " DOMAIN
    EMAIL=""
    if [[ -n "${DOMAIN}" ]]; then
        read -rp "Email для Let's Encrypt: " EMAIL
        [[ -n "${EMAIL}" ]] || { log_err "Email обязателен для доменного режима."; exit 1; }
    else
        log_warn "Включён временный режим без домена: Caddy выпустит внутренний TLS-сертификат, клиенту нужен allowInsecure."
    fi
    read -rp "Скрытый XHTTP path [авто]: " XHTTP_PATH
    XHTTP_PATH="${XHTTP_PATH:-$(random_path)}"
    [[ "${XHTTP_PATH}" == /* ]] || XHTTP_PATH="/${XHTTP_PATH}"

    local uuid external_ip public_host insecure sni internal_tls site_label
    uuid=$(generate_uuid)
    external_ip=$(get_external_ip)
    if [[ -n "${DOMAIN}" ]]; then
        check_domain_dns "${DOMAIN}" "${external_ip}"
        public_host="${DOMAIN}"
        sni="${DOMAIN}"
        insecure=false
        internal_tls=false
        site_label="${DOMAIN}"
    else
        public_host="${external_ip}"
        sni=""
        insecure=true
        internal_tls=true
        site_label="${external_ip}"
    fi

    log_info "Внешний IP сервера: ${external_ip}"
    log_info "Адрес для клиента: ${public_host}:443"
    log_info "XHTTP path: ${XHTTP_PATH}"

    backup_file "${CONFIG_FILE}"
    backup_file "${CADDYFILE}"
    write_site "${site_label}"
    write_xray_config "${uuid}" "${XHTTP_PATH}"
    write_caddyfile "${site_label}" "${EMAIL}" "${XHTTP_PATH}" "${internal_tls}"

    log_info "Проверка Xray config.json..."
    "${INSTALL_DIR}/xray" run -test -config "${CONFIG_FILE}"

    install_xray_systemd
    caddy validate --config "${CADDYFILE}"
    caddy fmt --overwrite "${CADDYFILE}"
    systemctl enable caddy
    systemctl restart caddy
    setup_firewall
    write_client_params "${public_host}" "${uuid}" "${XHTTP_PATH}" "${insecure}" "${sni}"

    echo ""
    echo "=============================================="
    log_info "VLESS + XHTTP установлен."
    echo "=============================================="
    echo "Клиентские параметры:"
    echo "  ${CLIENT_INFO}"
    echo ""
    echo "Проверьте сайт: https://${public_host}/"
    echo "Ссылка: client/xhttp-link-gen.py ${CLIENT_INFO} --link"
    echo "=============================================="
}

main "$@"
