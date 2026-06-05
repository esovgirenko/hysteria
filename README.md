# VPN-Hysteria2-Dual: VPN на Hysteria 2 с двухсерверным split-routing

Репозиторий переделан с клиентского входа **Xray REALITY** на **Hysteria 2**.

Основная идея осталась прежней:

| Режим | Документация | Когда использовать |
|-------|--------------|-------------------|
| **Один сервер** | этот README, `server/install-hysteria2.sh` | Один VPS, весь трафик через него |
| **Два сервера (Dual)** | [dual-server/README.md](dual-server/README.md) | Сервер 1 ближе к РФ: RU-трафик локально, остальное через сервер 2 |

В Dual-режиме клиенты подключаются к серверам по **Hysteria 2**. Xray больше не является клиентским протоколом, но используется внутри сервера 1 как маршрутизатор и между серверами как relay.

---

## Требования

- Сервер: Ubuntu 22.04 или Debian 12, root или sudo.
- Клиент: приложение с поддержкой **Hysteria 2**.
- Порты:
  - клиентский вход Hysteria 2: **UDP 443** по умолчанию;
  - Dual relay между серверами: **TCP 8443** с сервера 1 на сервер 2.

Важно: Hysteria 2 работает поверх UDP. Откройте UDP-порт не только в UFW, но и в панели хостинга.

---

## Структура проекта

```text
├── dual-server/
│   ├── README.md
│   ├── install-server1.sh       # Сервер 1: Hysteria 2 + split-routing
│   ├── install-server2.sh       # Сервер 2: Hysteria 2 fallback + relay
│   ├── patch-server2.sh         # Миграция существующего server2
│   ├── export-client-params.sh  # Показать hysteria-client-params.json
│   ├── export-relay-params.sh   # Восстановить relay-server1-params.json
│   └── client/dual-link-gen.py  # Две hysteria2:// ссылки
├── server/
│   └── install-hysteria2.sh     # Один VPS
├── client/
│   ├── hysteria-link-gen.py     # hysteria2://, QR, YAML
│   ├── reality-link-gen.py      # Старый генератор VLESS REALITY оставлен для совместимости
│   └── setup-venv.sh
├── install-server1.sh           # Обёртка dual-server/install-server1.sh
└── patch-server2.sh             # Обёртка dual-server/patch-server2.sh
```

---

## Один Сервер

На чистом VPS:

```bash
git clone https://github.com/esovgirenko/hysteria.git
cd hysteria
chmod +x server/install-hysteria2.sh
sudo ./server/install-hysteria2.sh
```

Скрипт:

- скачает Hysteria 2;
- создаст `/etc/hysteria/config.yaml`;
- сгенерирует пароль, obfs salamander и самоподписанный TLS-сертификат;
- запустит `hysteria.service`;
- сохранит параметры клиента в `/etc/hysteria/hysteria-client-params.json`.

Скопируйте `hysteria-client-params.json` на компьютер и сгенерируйте ссылку:

```bash
cd client
./setup-venv.sh
.venv/bin/python hysteria-link-gen.py /path/to/hysteria-client-params.json --link --qr
```

Для клиента, которому нужен YAML:

```bash
.venv/bin/python hysteria-link-gen.py /path/to/hysteria-client-params.json --yaml > config.yaml
```

---

## Dual-Режим

Кратко:

1. Сервер 2 за рубежом:

   ```bash
   sudo ./dual-server/install-server2.sh
   ```

   или миграция уже существующего сервера 2:

   ```bash
   sudo ./patch-server2.sh --server1-ip IP_СЕРВЕРА_1
   ```

2. Скопировать `/usr/local/etc/xray/relay-server1-params.json` с сервера 2 на сервер 1 в `/usr/local/etc/xray/`.

3. Сервер 1:

   ```bash
   sudo ./install-server1.sh -y
   ```

4. Скопировать `/etc/hysteria/hysteria-client-params.json` с обоих серверов на компьютер.

5. Сгенерировать две ссылки:

   ```bash
   cd dual-server/client
   ../../client/.venv/bin/python dual-link-gen.py \
     /path/to/server1-hysteria-client-params.json \
     /path/to/server2-hysteria-client-params.json
   ```

Подробности: [dual-server/README.md](dual-server/README.md).

---

## Клиенты

Подойдут клиенты с поддержкой Hysteria 2, например:

| Платформа | Клиенты |
|-----------|---------|
| iOS | Shadowrocket, Streisand, Hiddify |
| macOS | Shadowrocket, Hiddify, NekoRay/NekoBox |
| Android | Hiddify, NekoBox, v2rayNG версии с поддержкой Hysteria 2 |

Импортируйте `hysteria2://` ссылку или YAML-конфиг, если приложение поддерживает импорт файла.

---

## Проверка

На сервере:

```bash
sudo systemctl status hysteria
sudo journalctl -u hysteria -n 50 --no-pager
```

В Dual-режиме дополнительно:

```bash
sudo systemctl status xray
sudo XRAY_LOCATION_ASSET=/usr/local/etc/xray /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
```

Если клиент не подключается, первым делом проверьте, что открыт именно **UDP** порт Hysteria 2.
