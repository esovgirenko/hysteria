# VLESS-XHTTP: HTTPS-маскированный VPN на Xray + Caddy

Репозиторий переделан под связку **VLESS + XHTTP**. Цель — не держать отдельный “VPN-порт”, а прятать Xray за обычным HTTPS-сайтом:

- **Caddy** слушает `443`, отдаёт реальную веб-страницу и при наличии домена получает нормальный сертификат Let's Encrypt.
- **Xray** слушает только `127.0.0.1:10085`.
- Скрытый `XHTTP path` проксируется Caddy в Xray.
- Для постороннего посетителя домен выглядит как обычный сайт.

Важно: нельзя честно гарантировать, что “ни одна DPI система не вычислит” туннель. Лучший режим — с доменом и валидным публичным TLS. Режим без домена нужен как быстрый временный старт по IP: он работает, но требует pinned certificate SHA-256 на клиенте и маскируется слабее.

---

## Требования

- VPS: Ubuntu 22.04 или Debian 12.
- Домен желательно, но не обязательно для временного IP-only режима.
- Открытые порты: `443/tcp`, `22/tcp`. Для доменного режима также нужен `80/tcp` для Let's Encrypt.
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

- домен, например `example.com`; можно нажать Enter и временно работать без домена по IP;
- email для Let's Encrypt, только если указан домен;
- скрытый XHTTP path, можно нажать Enter и получить случайный.

Если домен указан, A/AAAA-запись должна уже указывать на VPS. Скрипт проверит DNS и предупредит, если домен смотрит на другой IP.

### Временно Без Домена

Если домена ещё нет, на вопрос о домене нажмите Enter. Скрипт:

- возьмёт внешний IP VPS как адрес клиента;
- настроит Caddy на `:443`;
- создаст self-signed IP-сертификат в `/etc/caddy/selfsigned/`;
- выдаст Caddy права на чтение приватного ключа;
- запишет `pinnedPeerCert-Sha256` в клиентские параметры.

Это удобно для теста, но не равноценно доменному режиму. Когда домен появится, лучше переустановить/перезапустить скрипт с доменом и новым клиентским профилем.

После установки:

```text
/usr/local/etc/xray/config.json
/usr/local/etc/xray/vless-xhttp-client-params.json
/etc/caddy/Caddyfile
/var/www/xhttp-site/
```

Если на сервере уже были `/usr/local/etc/xray/config.json` или `/etc/caddy/Caddyfile`, скрипт сохранит копии рядом с суффиксом `.bak.ДАТА`.

Сайт должен открываться. В IP-only режиме нужен `-k`, потому что сертификат внутренний:

```bash
curl -I https://example.com/
curl -k -I https://YOUR_SERVER_IP/
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

Для Happ Plus в IP-only режиме используйте pin из `vless-xhttp-client-params.json`. Значение должно быть в hex, например `5f5400...`, а не в base64 вроде `X1QA...=`.

---

## Что Делает Маскировку Лучше

Используйте практичные меры, которые не ломают совместимость:

- Держите на домене реальную страницу, а не пустую заглушку.
- Не публикуйте и не переиспользуйте XHTTP path.
- Используйте обычный домен, валидный TLS и стандартный порт `443`, как только домен будет готов.
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

IP-only режим:

```bash
curl -k -I https://YOUR_SERVER_IP/
curl -k https://YOUR_SERVER_IP/status/health.json
```

---

## Два Сервера

Для схемы, где клиент подключается к Серверу 1 по **VLESS + XHTTP + домен**, а весь клиентский трафик выходит через Сервер 2 по быстрому **WireGuard**-туннелю, используйте:

```bash
sudo ./dual-server/install-xhttp-wg-server2.sh
sudo ./dual-server/install-xhttp-wg-server1.sh
```

Подробный порядок установки: [dual-server/README.md](dual-server/README.md).

---

## Старые Скрипты

Файлы для Hysteria 2 и прежнего REALITY оставлены в репозитории как архив/совместимость, но основной путь установки теперь:

```bash
sudo ./server/install-vless-xhttp.sh
```

Dual-режим будет лучше переносить отдельно после проверки одиночного профиля на реальном домене.
