#!/usr/bin/env python3
"""
Генератор ссылок hysteria2:// и клиентских YAML-конфигов.
Принимает hysteria-client-params.json, созданный install-hysteria2.sh или Dual-скриптами.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from urllib.parse import quote

try:
    import qrcode
    HAS_QR = True
except ImportError:
    HAS_QR = False


def load_server_params(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def build_hysteria2_link(
    host: str,
    port: int,
    auth: str,
    *,
    obfs_password: str = "",
    insecure: bool = True,
    pin_sha256: str = "",
    sni: str = "",
    tag: str = "Hysteria2",
) -> str:
    params = {}
    if insecure:
        params["insecure"] = "1"
    if sni:
        params["sni"] = sni
    if obfs_password:
        params["obfs"] = "salamander"
        params["obfs-password"] = obfs_password
    if pin_sha256:
        params["pinSHA256"] = pin_sha256

    query = "&".join(f"{quote(k, safe='')}={quote(str(v), safe='')}" for k, v in params.items())
    suffix = f"?{query}" if query else ""
    return f"hysteria2://{quote(auth, safe='')}@{host}:{port}/{suffix}#{quote(tag, safe='')}"


def validate_link(link: str) -> tuple[bool, str]:
    if not link.startswith("hysteria2://"):
        return False, "Ссылка должна начинаться с hysteria2://"
    try:
        rest = link[len("hysteria2://"):]
        auth_host, _ = rest.split("/", 1)
        auth, host_port = auth_host.rsplit("@", 1)
        host, port_s = host_port.rsplit(":", 1)
        port = int(port_s)
        if not auth:
            return False, "Пустой пароль auth"
        if not host:
            return False, "Пустой host"
        if not (1 <= port <= 65535):
            return False, "Порт вне диапазона"
        return True, "OK"
    except Exception as exc:
        return False, str(exc)


def export_client_yaml(
    host: str,
    port: int,
    auth: str,
    *,
    obfs_password: str = "",
    insecure: bool = True,
    pin_sha256: str = "",
    sni: str = "",
    socks_port: int = 10808,
    http_port: int = 10809,
) -> str:
    lines = [
        f"server: {host}:{port}",
        "",
        "auth: " + auth,
        "",
        "tls:",
        f"  insecure: {'true' if insecure else 'false'}",
    ]
    if sni:
        lines.append(f"  sni: {sni}")
    if pin_sha256:
        lines.append(f"  pinSHA256: {pin_sha256}")
    if obfs_password:
        lines.extend([
            "",
            "obfs:",
            "  type: salamander",
            "  salamander:",
            f"    password: {obfs_password}",
        ])
    lines.extend([
        "",
        "socks5:",
        f"  listen: 127.0.0.1:{socks_port}",
        "",
        "http:",
        f"  listen: 127.0.0.1:{http_port}",
    ])
    return "\n".join(lines) + "\n"


def print_qr(link: str) -> None:
    if not HAS_QR:
        print("Установите qrcode: pip install qrcode[pil]", file=sys.stderr)
        return
    qr = qrcode.QRCode(box_size=1, border=2)
    qr.add_data(link)
    qr.make(fit=True)
    qr.print_ascii(invert=True)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Генератор hysteria2:// ссылок и YAML-конфигов для Hysteria 2"
    )
    parser.add_argument("input", nargs="?", help="hysteria-client-params.json")
    parser.add_argument("--host", help="IP или домен сервера")
    parser.add_argument("--port", type=int, default=None, help="UDP-порт")
    parser.add_argument("--auth", help="Пароль auth")
    parser.add_argument("--obfs-password", dest="obfs_password", help="Пароль salamander obfs")
    parser.add_argument("--sni", default="", help="SNI, если используется домен")
    parser.add_argument("--secure", action="store_true", help="Не включать insecure=1")
    parser.add_argument("--pin-sha256", dest="pin_sha256", default="", help="pinSHA256 сертификата")
    parser.add_argument("--tag", default="Hysteria2", help="Имя профиля")

    out = parser.add_argument_group("Вывод")
    out.add_argument("--link", action="store_true", help="Вывести только ссылку")
    out.add_argument("--yaml", action="store_true", help="Вывести клиентский config.yaml")
    out.add_argument("--qr", action="store_true", help="Показать QR-код")
    out.add_argument("--text", action="store_true", help="Показать параметры")
    out.add_argument("--validate", action="store_true", help="Проверить ссылку")

    args = parser.parse_args()

    data = {}
    if args.input and Path(args.input).is_file():
        data = load_server_params(args.input)

    host = args.host or data.get("serverHost", "")
    port = args.port if args.port is not None else int(data.get("serverPort", 443))
    auth = args.auth or data.get("auth", "")
    obfs_password = args.obfs_password or data.get("obfsPassword", "")
    insecure = not args.secure and bool(data.get("insecure", True))
    pin_sha256 = args.pin_sha256 or data.get("pinSHA256", "")
    sni = args.sni or data.get("sni", "")

    if not all([host, port, auth]):
        print("Задайте host, port и auth или укажите hysteria-client-params.json.", file=sys.stderr)
        sys.exit(1)

    link = build_hysteria2_link(
        host=host,
        port=port,
        auth=auth,
        obfs_password=obfs_password,
        insecure=insecure,
        pin_sha256=pin_sha256,
        sni=sni,
        tag=args.tag,
    )

    if args.validate:
        ok, msg = validate_link(link)
        print(f"Валидация: {'OK' if ok else 'Ошибка'} - {msg}")
        sys.exit(0 if ok else 1)

    if args.link:
        print(link)
    if args.yaml:
        print(export_client_yaml(host, port, auth, obfs_password=obfs_password, insecure=insecure, pin_sha256=pin_sha256, sni=sni), end="")
    if args.qr:
        print_qr(link)
    if args.text:
        print("\n--- Параметры подключения (Hysteria 2) ---")
        print(f"  Сервер:       {host}:{port}/udp")
        print(f"  Auth:         {auth}")
        print(f"  Obfs:         salamander")
        print(f"  Obfs password:{obfs_password}")
        print(f"  Insecure:     {insecure}")
        print(f"  pinSHA256:    {pin_sha256}")
        print("\n--- Ссылка hysteria2 ---")
        print(link)
        print()

    if not any([args.link, args.yaml, args.qr, args.text]):
        print(link)
        print("\nОпции: --yaml, --qr, --text, --validate", file=sys.stderr)


if __name__ == "__main__":
    main()
