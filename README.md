# sing-box menubar

Индикатор [sing-box](https://github.com/SagerNet/sing-box) в менюбаре macOS: видно, работает ли туннель, через какой узел идёт трафик и кто именно в него ходит. Один файл на Swift, без зависимостей.

*A tiny macOS menu bar indicator for a sing-box daemon: status, server picker, latency, live traffic per exit and per process. UI is in Russian.*

## Что умеет

- Значок-щит: зелёный — sing-box работает, серый — выключен.
- Выбор сервера из группы `proxy` одним кликом, задержки узлов, «Перепроверить задержки».
- Скорость сейчас, объём за сессию, число соединений.
- Подменю на каждый выход (узел) и «Напрямую»: строки «хост · процесс · объём», самые тяжёлые сверху.
- Блок «Правила → выход»: какая группа (selector/urltest) куда сейчас ведёт.
- Включить и выключить демон, открыть конфиг, показать лог.
- По желанию — скорость прямо в строке меню.

Индикатор ничего не туннелирует сам: он читает Clash API работающего sing-box и управляет его демоном через `launchctl`.

## Установка

```sh
curl -fsSL https://raw.githubusercontent.com/kkdclaw/singbox-menubar/main/install.sh | sh
```

Скрипт ставит `~/Applications/sing-box.app` и автозапуск (`~/Library/LaunchAgents/com.kkd.singbox-menubar.plist`). `sudo` не нужен, sing-box и его конфиг скрипт не трогает. Нужен macOS 14 или новее; сборка универсальная (Apple Silicon и Intel).

Обновление — та же команда. Собрать из исходника на своей машине вместо готовой сборки (нужен `xcode-select --install`):

```sh
curl -fsSL https://raw.githubusercontent.com/kkdclaw/singbox-menubar/main/install.sh | SINGBOX_MENUBAR_BUILD=1 sh
```

Удаление:

```sh
curl -fsSL https://raw.githubusercontent.com/kkdclaw/singbox-menubar/main/uninstall.sh | sh
```

## Что нужно, чтобы он работал

Индикатор рассчитан на sing-box, запущенный системным демоном. Он ожидает:

| Что | Где |
|---|---|
| Демон | LaunchDaemon `com.kkd.singbox`, файл `/Library/LaunchDaemons/com.kkd.singbox.plist` |
| Конфиг | `~/.config/sing-box/config.json` |
| Лог | `~/.local/share/sing-box/sing-box.log` |
| Clash API | `127.0.0.1:9190` (`experimental.clash_api.external_controller`) |
| Группа серверов | outbound типа `selector` с тегом `proxy` |
| Беспарольный `launchctl` | четыре строки в `/etc/sudoers.d/singbox` — для кнопки «Включить/Выключить» |

Необязательно, но полезно: `"find_process": true` в `route` — тогда в подменю видны имена процессов; `urltest` с тегом `Авто` внутри `proxy` — в меню он подписан «самый быстрый».

Если sing-box ещё не стоит, вот путь с нуля (проверено на sing-box 1.14.0).

**1. Бинарник** — под root, потому что демон работает от root:

```sh
curl -sL -o /tmp/sb.tgz https://github.com/SagerNet/sing-box/releases/download/v1.14.0/sing-box-1.14.0-darwin-arm64.tar.gz
tar xzf /tmp/sb.tgz -C /tmp
sudo mkdir -p /usr/local/bin
sudo install -o root -g wheel -m 755 /tmp/sing-box-1.14.0-darwin-arm64/sing-box /usr/local/bin/sing-box
```

Для Intel — архив `darwin-amd64`.

**2. Конфиг** — возьмите [examples/config.example.json](examples/config.example.json), впишите свои узлы вместо `node-1` и `node-2`:

```sh
mkdir -p ~/.config/sing-box ~/.local/share/sing-box
curl -fsSL https://raw.githubusercontent.com/kkdclaw/singbox-menubar/main/examples/config.example.json \
  | sed "s/USERNAME/$(whoami)/g" > ~/.config/sing-box/config.json
chmod 600 ~/.config/sing-box/config.json
# …правка узлов…
sing-box check -c ~/.config/sing-box/config.json
```

**3. Демон** — [examples/com.kkd.singbox.plist](examples/com.kkd.singbox.plist):

```sh
curl -fsSL https://raw.githubusercontent.com/kkdclaw/singbox-menubar/main/examples/com.kkd.singbox.plist \
  | sed "s/USERNAME/$(whoami)/g" > /tmp/com.kkd.singbox.plist
sudo install -o root -g wheel -m 644 /tmp/com.kkd.singbox.plist /Library/LaunchDaemons/com.kkd.singbox.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/com.kkd.singbox.plist
```

**4. Беспарольный launchctl** — [examples/sudoers-singbox](examples/sudoers-singbox). Правило разрешает четыре команды `launchctl` для одного этого демона и больше ничего:

```sh
curl -fsSL https://raw.githubusercontent.com/kkdclaw/singbox-menubar/main/examples/sudoers-singbox \
  | sed "s/USERNAME/$(whoami)/g" > /tmp/sudoers-singbox
sudo visudo -c -f /tmp/sudoers-singbox && sudo install -o root -g wheel -m 440 /tmp/sudoers-singbox /etc/sudoers.d/singbox
```

**Проверка:**

```sh
sudo -n launchctl print system/com.kkd.singbox >/dev/null && echo daemon-ok
curl -s --max-time 3 http://127.0.0.1:9190/version
```

## Грабли

- **Два TUN одновременно ломают сеть.** Прежний VPN-клиент со своим TUN надо именно закрыть, а не свернуть: иначе в логе `dial 198.18.0.x: i/o timeout`, а снаружи «интернет частично отвалился».
- **Порт 9090 часто занят** другим клиентом, поэтому Clash API здесь на 9190. Другой порт — поменять константу `API` в `menubar.swift` и пересобрать.
- **`sing-box check` ловит не всё.** Часть ошибок конфига всплывает только при запуске — после правки смотрите лог.
- **Выбранный сервер не переживает перезапуск демона** — селектор возвращается к значению `default`.
- **Перезапускать индикатор** — `launchctl kickstart -k gui/$(id -u)/com.kkd.singbox-menubar`, а не `open`: агент с `KeepAlive` поднимет вторую копию, и значков станет два.

## Сборка

```sh
./build.sh    # universal-сборка в build/ и архив в dist/
```

Пути, метка демона и порт API — константы в первых строках `menubar.swift`.

## Лицензия

MIT. Проект не связан с авторами sing-box.
