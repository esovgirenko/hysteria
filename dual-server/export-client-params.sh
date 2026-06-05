#!/usr/bin/env bash
# Показать hysteria-client-params.json из уже установленного сервера.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

check_root

CLIENT_INFO="${HYSTERIA_CONFIG_DIR}/hysteria-client-params.json"
if [[ ! -f "${CLIENT_INFO}" ]]; then
    log_err "Нет ${CLIENT_INFO}"
    log_err "Сначала установите сервер через install-server1.sh, install-server2.sh или server/install-hysteria2.sh."
    exit 1
fi

log_info "Клиентские параметры Hysteria 2: ${CLIENT_INFO}"
cat "${CLIENT_INFO}"
