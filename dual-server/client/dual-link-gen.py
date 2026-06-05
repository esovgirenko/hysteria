#!/usr/bin/env python3
"""
Генератор ссылок для двухсерверной схемы на Hysteria 2:
  - основной профиль: сервер 1 (split RU / abroad)
  - резервный профиль: сервер 2 (полный выход за рубежом)
"""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path

_client_dir = Path(__file__).resolve().parents[2] / "client"
_spec = importlib.util.spec_from_file_location(
    "hysteria_link_gen", _client_dir / "hysteria-link-gen.py"
)
_mod = importlib.util.module_from_spec(_spec)
assert _spec and _spec.loader
_spec.loader.exec_module(_mod)

build_hysteria2_link = _mod.build_hysteria2_link
load_server_params = _mod.load_server_params
print_qr = _mod.print_qr
validate_link = _mod.validate_link


def profile_from_params(data: dict, tag: str) -> tuple[str, dict]:
    link = build_hysteria2_link(
        host=data["serverHost"],
        port=int(data.get("serverPort", 443)),
        auth=data["auth"],
        obfs_password=data.get("obfsPassword", ""),
        insecure=bool(data.get("insecure", True)),
        pin_sha256=data.get("pinSHA256", ""),
        sni=data.get("sni", ""),
        tag=tag,
    )
    meta = {
        "tag": tag,
        "host": data["serverHost"],
        "port": int(data.get("serverPort", 443)),
        "auth": data["auth"],
        "obfs": data.get("obfs", "salamander"),
        "obfsPassword": data.get("obfsPassword", ""),
        "insecure": bool(data.get("insecure", True)),
        "pinSHA256": data.get("pinSHA256", ""),
        "link": link,
    }
    return link, meta


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Ссылки hysteria2: сервер 1 (основной) + сервер 2 (резерв)"
    )
    parser.add_argument("server1_params", help="hysteria-client-params.json с сервера 1")
    parser.add_argument(
        "server2_params",
        nargs="?",
        help="hysteria-client-params.json с сервера 2",
    )
    parser.add_argument("--qr", action="store_true", help="QR основного профиля")
    parser.add_argument("--json-bundle", action="store_true", help="JSON с двумя профилями")
    args = parser.parse_args()

    p1 = load_server_params(args.server1_params)
    link1, meta1 = profile_from_params(p1, "VPN-Server1-RU-split")

    print("=== Основной (сервер 1): RU - локально, остальное - через сервер 2 ===")
    print(link1)
    ok, msg = validate_link(link1)
    print(f"Валидация: {'OK' if ok else msg}\n")

    meta2 = None
    if args.server2_params and Path(args.server2_params).is_file():
        p2 = load_server_params(args.server2_params)
        link2, meta2 = profile_from_params(p2, "VPN-Server2-Fallback")
        print("=== Резерв (сервер 2): весь трафик за рубежом ===")
        print(link2)
        ok2, msg2 = validate_link(link2)
        print(f"Валидация: {'OK' if ok2 else msg2}\n")
    else:
        print("(Добавьте путь к server2_params для резервной ссылки)\n")

    if args.qr:
        print("--- QR: основной ---")
        print_qr(link1)

    if args.json_bundle:
        bundle = {
            "remarks": "VPN-Hysteria2 dual",
            "profiles": [meta1] + ([meta2] if meta2 else []),
        }
        print(json.dumps(bundle, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
