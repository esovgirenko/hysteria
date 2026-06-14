#!/usr/bin/env python3
"""
Генератор VLESS + XHTTP ссылок и клиентских JSON-конфигов.
Принимает /usr/local/etc/xray/vless-xhttp-client-params.json с сервера.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from urllib.parse import quote
from uuid import UUID

try:
    import qrcode
    HAS_QR = True
except ImportError:
    HAS_QR = False


def load_params(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def validate_uuid(value: str) -> bool:
    try:
        UUID(value)
        return True
    except (TypeError, ValueError):
        return False


def build_vless_xhttp_link(
    host: str,
    port: int,
    uuid: str,
    path: str,
    *,
    mode: str = "packet-up",
    sni: str = "",
    insecure: bool = False,
    tag: str = "VLESS-XHTTP",
) -> str:
    params = {
        "type": "xhttp",
        "security": "tls",
        "host": host,
        "path": path,
        "mode": mode,
        "alpn": "h2,http/1.1",
        "fp": "chrome",
    }
    if sni:
        params["sni"] = sni
    if insecure:
        params["allowInsecure"] = "1"
    query = "&".join(f"{quote(k, safe='')}={quote(str(v), safe='')}" for k, v in params.items())
    return f"vless://{quote(uuid, safe='')}@{host}:{port}?{query}#{quote(tag, safe='')}"


def validate_link(link: str) -> tuple[bool, str]:
    if not link.startswith("vless://"):
        return False, "Ссылка должна начинаться с vless://"
    try:
        rest = link[len("vless://"):]
        uuid, rest = rest.split("@", 1)
        if not validate_uuid(uuid):
            return False, "Некорректный UUID"
        host_port, query = rest.split("?", 1)
        host, port_s = host_port.rsplit(":", 1)
        port = int(port_s)
        if not host:
            return False, "Пустой host"
        if not (1 <= port <= 65535):
            return False, "Порт вне диапазона"
        required = ("type=xhttp", "security=tls", "path=", "mode=")
        for item in required:
            if item not in query:
                return False, f"Отсутствует параметр: {item}"
        return True, "OK"
    except Exception as exc:
        return False, str(exc)


def export_outbound_json(
    host: str,
    port: int,
    uuid: str,
    path: str,
    mode: str,
    tag: str,
    *,
    sni: str = "",
    insecure: bool = False,
) -> dict:
    return {
        "protocol": "vless",
        "settings": {
            "vnext": [
                {
                    "address": host,
                    "port": port,
                    "users": [
                        {
                            "id": uuid,
                            "encryption": "none",
                        }
                    ],
                }
            ]
        },
        "streamSettings": {
            "network": "xhttp",
            "security": "tls",
            "tlsSettings": {
                "serverName": sni or host,
                "alpn": ["h2", "http/1.1"],
                "fingerprint": "chrome",
                "allowInsecure": insecure,
            },
            "xhttpSettings": {
                "host": host,
                "path": path,
                "mode": mode,
            },
        },
        "tag": tag,
    }


def export_full_config(
    host: str,
    port: int,
    uuid: str,
    path: str,
    mode: str,
    *,
    sni: str = "",
    insecure: bool = False,
    socks_port: int = 10808,
) -> dict:
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "listen": "127.0.0.1",
                "port": socks_port,
                "protocol": "socks",
                "settings": {"udp": True},
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls", "quic"],
                },
            }
        ],
        "outbounds": [
            export_outbound_json(host, port, uuid, path, mode, "proxy", sni=sni, insecure=insecure)
        ],
    }


def print_qr(link: str) -> None:
    if not HAS_QR:
        print("Установите qrcode: pip install qrcode[pil]", file=sys.stderr)
        return
    qr = qrcode.QRCode(box_size=1, border=2)
    qr.add_data(link)
    qr.make(fit=True)
    qr.print_ascii(invert=True)


def main() -> None:
    parser = argparse.ArgumentParser(description="Генератор ссылок VLESS + XHTTP")
    parser.add_argument("input", nargs="?", help="vless-xhttp-client-params.json")
    parser.add_argument("--host", help="Домен сервера")
    parser.add_argument("--port", type=int, default=None, help="Порт, обычно 443")
    parser.add_argument("--uuid", help="UUID пользователя")
    parser.add_argument("--path", help="XHTTP path")
    parser.add_argument("--mode", default=None, help="XHTTP mode")
    parser.add_argument("--sni", default=None, help="SNI для TLS, если отличается от host")
    parser.add_argument("--insecure", action="store_true", help="Разрешить self-signed/internal TLS")
    parser.add_argument("--tag", default="VLESS-XHTTP", help="Имя профиля")

    out = parser.add_argument_group("Вывод")
    out.add_argument("--link", action="store_true", help="Вывести только vless:// ссылку")
    out.add_argument("--json", action="store_true", help="Вывести outbound JSON")
    out.add_argument("--full-config", action="store_true", help="Вывести полный клиентский JSON")
    out.add_argument("--qr", action="store_true", help="Показать QR")
    out.add_argument("--text", action="store_true", help="Показать параметры")
    out.add_argument("--validate", action="store_true", help="Проверить ссылку")
    args = parser.parse_args()

    data = {}
    if args.input and Path(args.input).is_file():
        data = load_params(args.input)

    host = args.host or data.get("serverHost", "")
    port = args.port if args.port is not None else int(data.get("serverPort", 443))
    uuid = args.uuid or data.get("uuid", "")
    path = args.path or data.get("path", "")
    mode = args.mode or data.get("mode", "packet-up")
    sni = args.sni if args.sni is not None else data.get("sni", "")
    insecure = bool(args.insecure or data.get("insecure", False))

    if not all([host, port, uuid, path]):
        print("Задайте host, port, uuid и path или укажите vless-xhttp-client-params.json.", file=sys.stderr)
        sys.exit(1)
    if not path.startswith("/"):
        print("Path должен начинаться с '/'.", file=sys.stderr)
        sys.exit(1)

    link = build_vless_xhttp_link(host, port, uuid, path, mode=mode, sni=sni, insecure=insecure, tag=args.tag)

    if args.validate:
        ok, msg = validate_link(link)
        print(f"Валидация: {'OK' if ok else 'Ошибка'} - {msg}")
        sys.exit(0 if ok else 1)

    if args.link:
        print(link)
    if args.json:
        print(json.dumps(export_outbound_json(host, port, uuid, path, mode, args.tag, sni=sni, insecure=insecure), ensure_ascii=False, indent=2))
    if args.full_config:
        print(json.dumps(export_full_config(host, port, uuid, path, mode, sni=sni, insecure=insecure), ensure_ascii=False, indent=2))
    if args.qr:
        print_qr(link)
    if args.text:
        print("\n--- Параметры подключения (VLESS + XHTTP) ---")
        print(f"  Сервер: {host}:{port}")
        print(f"  UUID:   {uuid}")
        print(f"  Path:   {path}")
        print(f"  Mode:   {mode}")
        print(f"  SNI:    {sni or '(empty)'}")
        print(f"  Insecure TLS: {insecure}")
        print("\n--- Ссылка vless ---")
        print(link)
        print()

    if not any([args.link, args.json, args.full_config, args.qr, args.text]):
        print(link)
        print("\nОпции: --json, --full-config, --qr, --text, --validate", file=sys.stderr)


if __name__ == "__main__":
    main()
