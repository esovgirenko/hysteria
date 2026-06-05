#!/usr/bin/env bash
# Общие функции для двухсерверной установки VPN на Hysteria 2 + Xray-router

set -euo pipefail

readonly XRAY_VERSION="${XRAY_VERSION:-26.2.6}"
readonly HYSTERIA_BIN="${HYSTERIA_BIN:-/usr/local/bin/hysteria}"
readonly HYSTERIA_CONFIG_DIR="${HYSTERIA_CONFIG_DIR:-/etc/hysteria}"
readonly HYSTERIA_CONFIG_FILE="${HYSTERIA_CONFIG_FILE:-${HYSTERIA_CONFIG_DIR}/config.yaml}"
readonly INSTALL_DIR="/usr/local/bin"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"
readonly GEODATA_DIR="${CONFIG_DIR}"

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
    apt-get install -y -qq curl ca-certificates jq unzip openssl xxd
}

get_hysteria_arch() {
    case "$(uname -m)" in
        x86_64) echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        armv7l) echo "arm" ;;
        *) log_err "Неподдерживаемая архитектура для Hysteria: $(uname -m)"; exit 1 ;;
    esac
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
    log_info "Hysteria установлена в ${HYSTERIA_BIN}"
}

install_xray() {
    if [[ -x "${INSTALL_DIR}/xray" ]]; then
        log_info "Xray уже установлен: $(${INSTALL_DIR}/xray version | head -1)"
        return 0
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
    log_info "Xray установлен."
}

install_geodata() {
    local geoip="${GEODATA_DIR}/geoip.dat"
    local geosite="${GEODATA_DIR}/geosite.dat"
    if [[ ! -f "${geoip}" || ! -f "${geosite}" ]]; then
        log_info "Загрузка geoip.dat и geosite.dat (Loyalsoldier)..."
        curl -fSL -o "${geoip}" \
            "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat"
        curl -fSL -o "${geosite}" \
            "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat"
    else
        log_info "Geo-данные уже установлены в ${GEODATA_DIR}."
    fi
    # Xray по умолчанию ищет geoip.dat рядом с бинарником — дублируем ссылками
    ln -sf "${geoip}" "${INSTALL_DIR}/geoip.dat"
    ln -sf "${geosite}" "${INSTALL_DIR}/geosite.dat"
}

generate_x25519() {
    local out
    if ! out=$("${INSTALL_DIR}/xray" x25519 2>&1); then
        log_err "Команда xray x25519 завершилась с ошибкой."
        exit 1
    fi
    echo "${out}"
}

parse_x25519() {
    local out="$1"
    PRIVATE_KEY=$(echo "${out}" | grep -iE "PrivateKey:" | sed 's/.*PrivateKey: *//i' | tr -d '\r\n')
    [[ -z "${PRIVATE_KEY}" ]] && PRIVATE_KEY=$(echo "${out}" | grep -i "Private key" | sed 's/.*: *//' | tr -d '\r\n')
    PUBLIC_KEY=$(echo "${out}" | grep -iE "Password:" | sed 's/.*Password: *//i' | tr -d '\r\n')
    [[ -z "${PUBLIC_KEY}" ]] && PUBLIC_KEY=$(echo "${out}" | grep -i "Public key" | sed 's/.*: *//' | tr -d '\r\n')
    if [[ -z "${PRIVATE_KEY}" || -z "${PUBLIC_KEY}" ]]; then
        log_err "Не удалось распарсить вывод xray x25519:"
        echo "${out}"
        exit 1
    fi
}

generate_short_id() {
    local len="${1:-8}"
    head -c $(( len / 2 )) /dev/urandom | xxd -p -c 256 | tr -d '\n' | head -c "${len}"
}

generate_uuid() {
    "${INSTALL_DIR}/xray" uuid 2>/dev/null || uuidgen
}

generate_secret() {
    openssl rand -base64 24 | tr -d '\n'
}

get_external_ip() {
    local ip
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
        ip=$(curl -fsSL --max-time 5 "${url}" 2>/dev/null) && break
    done
    [[ -z "${ip}" ]] && ip=$(hostname -I | awk '{print $1}')
    echo "${ip}"
}

install_systemd() {
    cat > /etc/systemd/system/xray.service << SVCEOF
[Unit]
Description=Xray-core VPN Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target

[Service]
Type=simple
Environment=XRAY_LOCATION_ASSET=${GEODATA_DIR}
ExecStart=${INSTALL_DIR}/xray run -config ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
    sleep 1
    systemctl is-active --quiet xray || {
        log_err "Xray не запустился. journalctl -u xray -n 50"
        exit 1
    }
    log_info "Сервис xray запущен."
}

validate_xray_config() {
    XRAY_LOCATION_ASSET="${GEODATA_DIR}" "${INSTALL_DIR}/xray" run -test -config "${CONFIG_FILE}"
}

setup_ufw_ports() {
    local ports=("$@")
    command -v ufw &>/dev/null || return 0
    for p in "${ports[@]}"; do
        ufw allow "${p}/tcp" 2>/dev/null || true
        ufw allow "${p}/udp" 2>/dev/null || true
    done
    ufw allow 22/tcp 2>/dev/null || true
    echo "y" | ufw enable 2>/dev/null || true
}

setup_ufw_tcp_ports() {
    local ports=("$@")
    command -v ufw &>/dev/null || return 0
    for p in "${ports[@]}"; do
        ufw allow "${p}/tcp" 2>/dev/null || true
    done
    ufw allow 22/tcp 2>/dev/null || true
    echo "y" | ufw enable 2>/dev/null || true
}

generate_hysteria_tls() {
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

hysteria_cert_pin() {
    local cert="$1"
    openssl x509 -in "${cert}" -pubkey -noout |
        openssl pkey -pubin -outform der |
        openssl dgst -sha256 -binary |
        openssl base64 -A
}

validate_hysteria_config() {
    "${HYSTERIA_BIN}" server -c "${HYSTERIA_CONFIG_FILE}" --check
}

install_hysteria_systemd() {
    cat > /etc/systemd/system/hysteria.service << SVCEOF
[Unit]
Description=Hysteria 2 VPN Service
Documentation=https://v2.hysteria.network/
After=network.target xray.service

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
    log_info "Сервис hysteria запущен."
}

generate_relay_tls() {
    local cert_dir="${CONFIG_DIR}/relay-tls"
    mkdir -p "${cert_dir}"
    if [[ ! -f "${cert_dir}/cert.pem" || ! -f "${cert_dir}/key.pem" ]]; then
        openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
            -keyout "${cert_dir}/key.pem" \
            -out "${cert_dir}/cert.pem" \
            -subj "/CN=vpn-relay.internal" 2>/dev/null
    fi
    echo "${cert_dir}"
}

backup_config() {
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    cp -a "${CONFIG_FILE}" "${CONFIG_FILE}.bak.${ts}"
    log_info "Резервная копия: ${CONFIG_FILE}.bak.${ts}"
}

require_xray_installed() {
    [[ -x "${INSTALL_DIR}/xray" ]] || {
        log_err "Xray не найден. Для Dual установите server2 через install-server2.sh или мигрируйте старый server2 через patch-server2.sh"
        exit 1
    }
    [[ -f "${CONFIG_FILE}" ]] || {
        log_err "Нет ${CONFIG_FILE}. Сначала установите Dual server2 или выполните миграционный patch-server2.sh."
        exit 1
    }
}

restart_xray() {
    systemctl restart xray
    sleep 1
    systemctl is-active --quiet xray || {
        log_err "Xray не запустился после изменений. Откат: cp ${CONFIG_FILE}.bak.* ${CONFIG_FILE}"
        journalctl -u xray -n 30 --no-pager
        exit 1
    }
    log_info "Xray перезапущен."
}

setup_ufw_relay_from_ip() {
    local relay_port="$1"
    local allow_ip="$2"
    command -v ufw &>/dev/null || return 0
    ufw delete allow "${relay_port}/tcp" 2>/dev/null || true
    if [[ -n "${allow_ip}" ]]; then
        ufw allow from "${allow_ip}" to any port "${relay_port}" proto tcp
        log_info "UFW: порт ${relay_port} только с ${allow_ip}"
    else
        ufw allow "${relay_port}/tcp"
        log_warn "UFW: порт ${relay_port} открыт для всех (укажите IP сервера 1 при повторном запуске)"
    fi
}
