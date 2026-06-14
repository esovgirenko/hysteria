# VLESS-XHTTP: HTTPS-маскированный VPN на Xray + Caddy

Репозиторий переделан под связку **VLESS + XHTTP**. Цель — не держать отдельный “VPN-порт”, а прятать Xray за обычным HTTPS-сайтом:

- **Caddy** слушает `80/443`, получает нормальный сертификат Let's Encrypt и отдаёт реальную веб-страницу.
- **Xray** слушает только `127.0.0.1:10085`.
- Скрытый `XHTTP path` проксируется Caddy в Xray.
- Для постороннего посетителя домен выглядит как обычный сайт.

Важно: нельзя честно гарантировать, что “ни одна DPI система не вычислит” туннель. Но эта схема снижает заметность: TLS завершает обычный веб-сервер, на домене есть сайт, Xray не торчит наружу, а трафик идёт как HTTPS-запросы к реальному домену.

---

## Требования

- VPS: Ubuntu 22.04 или Debian 12.
- Домен, A/AAAA-запись которого уже указывает на IP VPS.
- Открытые порты: `80/tcp`, `443/tcp`, `22/tcp`.
- Клиент с поддержкой **VLESS + XHTTP**.

---

## Быстрая Установка

На чистом VPS:

```bash
git clone https://github.com/esovgirenko/hysteria.git
cd hysteria
chmod +x server/install-vless-xhttp.sh
sudo ./server/install-vless-xhttp.sh
```

Скрипт спросит:

- домен, например `example.com`;
- email для Let's Encrypt;
- скрытый XHTTP path, можно нажать Enter и получить случайный.

Перед запуском A/AAAA-запись домена должна уже указывать на VPS. Скрипт проверит DNS и предупредит, если домен смотрит на другой IP.

После установки:

```text
/usr/local/etc/xray/config.json
/usr/local/etc/xray/vless-xhttp-client-params.json
/etc/caddy/Caddyfile
/var/www/xhttp-site/
```

Если на сервере уже были `/usr/local/etc/xray/config.json` или `/etc/caddy/Caddyfile`, скрипт сохранит копии рядом с суффиксом `.bak.ДАТА`.

Сайт должен открываться:

```bash
curl -I https://example.com/
```

---

## Клиентская Ссылка

Скачайте с VPS:

```bash
scp root@example.com:/usr/local/etc/xray/vless-xhttp-client-params.json .
```

На компьютере:

```bash
cd client
./setup-venv.sh
.venv/bin/python xhttp-link-gen.py /path/to/vless-xhttp-client-params.json --link --qr
```

Для клиента, которому нужен полный JSON:

```bash
.venv/bin/python xhttp-link-gen.py /path/to/vless-xhttp-client-params.json --full-config > config.json
```

---

## Что Делает Маскировку Лучше

Используйте практичные меры, которые не ломают совместимость:

- Держите на домене реальную страницу, а не пустую заглушку.
- Не публикуйте и не переиспользуйте XHTTP path.
- Используйте обычный домен, валидный TLS и стандартный порт `443`.
- Не открывайте Xray наружу: он должен слушать только `127.0.0.1`.
- Не ставьте подозрительные заголовки и нестандартные TLS-сертификаты.
- Следите, чтобы DNS домена соответствовал VPS и сайт отвечал обычным браузером.

По умолчанию используется `packet-up`, потому что это самый совместимый режим XHTTP через обычные HTTP reverse proxy. Если вы точно знаете, что ваш клиент и промежуточная сеть нормально работают с другим режимом:

```bash
XHTTP_MODE=stream-up sudo ./server/install-vless-xhttp.sh
```

---

## Проверка На Сервере

```bash
sudo systemctl status caddy
sudo systemctl status xray
sudo /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
sudo journalctl -u xray -n 50 --no-pager
sudo journalctl -u caddy -n 50 --no-pager
```

Обычный публичный сайт:

```bash
curl -I https://YOUR_DOMAIN/
curl https://YOUR_DOMAIN/status/health.json
```

---

## Старые Скрипты

Файлы для Hysteria 2 и прежнего REALITY оставлены в репозитории как архив/совместимость, но основной путь установки теперь:

```bash
sudo ./server/install-vless-xhttp.sh
```

Dual-режим будет лучше переносить отдельно после проверки одиночного профиля на реальном домене.
