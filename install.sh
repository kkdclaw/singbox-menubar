#!/bin/sh
# Установка индикатора sing-box в менюбар macOS.
#
#   curl -fsSL https://raw.githubusercontent.com/kkdclaw/singbox-menubar/main/install.sh | sh
#
# Ставит ~/Applications/sing-box.app и LaunchAgent com.kkd.singbox-menubar.
# sudo не нужен. Сам sing-box, его конфиг и демон скрипт не трогает.
#
# Переменные окружения:
#   SINGBOX_MENUBAR_BUILD=1    собрать из исходника на этой машине (нужен swiftc)
#   SINGBOX_MENUBAR_NOSTART=1  поставить файлы, но не запускать агент
#   SINGBOX_MENUBAR_BASE=URL   откуда брать файлы (по умолчанию — этот репозиторий)
set -eu

BASE="${SINGBOX_MENUBAR_BASE:-https://raw.githubusercontent.com/kkdclaw/singbox-menubar/main}"
BUNDLE_ID="com.kkd.singbox-menubar"
DAEMON="com.kkd.singbox"
APP="$HOME/Applications/sing-box.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"
API="http://127.0.0.1:9190"

say() { printf '%s\n' "$*"; }
die() { printf 'ошибка: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "нужен macOS"
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 14 ] || die "нужен macOS 14 или новее (здесь $(sw_vers -productVersion))"

# не затираем чужое приложение с тем же именем
if [ -d "$APP" ]; then
    have=$(/usr/bin/defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
    [ "$have" = "$BUNDLE_ID" ] || die "$APP уже существует и это не индикатор ($have) — уберите его и запустите снова"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if [ "${SINGBOX_MENUBAR_BUILD:-0}" = "1" ]; then
    command -v xcrun >/dev/null 2>&1 && xcrun --find swiftc >/dev/null 2>&1 \
        || die "нет swiftc — поставьте Command Line Tools: xcode-select --install"
    say "скачиваю исходник…"
    curl -fsSL "$BASE/menubar.swift" -o "$tmp/menubar.swift"
    curl -fsSL "$BASE/Info.plist" -o "$tmp/Info.plist"
    say "собираю…"
    mkdir -p "$tmp/sing-box.app/Contents/MacOS"
    cp "$tmp/Info.plist" "$tmp/sing-box.app/Contents/"
    xcrun swiftc -O -o "$tmp/sing-box.app/Contents/MacOS/singbox-menubar" "$tmp/menubar.swift"
else
    say "скачиваю готовую сборку…"
    curl -fsSL "$BASE/dist/sing-box.app.zip" -o "$tmp/sing-box.app.zip"
    curl -fsSL "$BASE/dist/sing-box.app.zip.sha256" -o "$tmp/sing-box.app.zip.sha256"
    want=$(cut -d' ' -f1 "$tmp/sing-box.app.zip.sha256")
    got=$(shasum -a 256 "$tmp/sing-box.app.zip" | cut -d' ' -f1)
    [ -n "$want" ] && [ "$want" = "$got" ] || die "контрольная сумма архива не сошлась"
    ditto -x -k "$tmp/sing-box.app.zip" "$tmp/"
fi
[ -x "$tmp/sing-box.app/Contents/MacOS/singbox-menubar" ] || die "в сборке нет исполняемого файла"

uid=$(id -u)
launchctl bootout "gui/$uid/$BUNDLE_ID" 2>/dev/null || true
i=0
while launchctl print "gui/$uid/$BUNDLE_ID" >/dev/null 2>&1 && [ $i -lt 10 ]; do sleep 0.5; i=$((i + 1)); done

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
rm -rf "$APP"
ditto "$tmp/sing-box.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true
codesign --force -s - "$APP" 2>/dev/null || die "не удалось подписать $APP"

cat > "$AGENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$BUNDLE_ID</string>
	<key>ProgramArguments</key>
	<array>
		<string>$APP/Contents/MacOS/singbox-menubar</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<key>ProcessType</key>
	<string>Interactive</string>
</dict>
</plist>
EOF

say "установлено: $APP"

if [ "${SINGBOX_MENUBAR_NOSTART:-0}" = "1" ]; then
    say "агент не запущен (SINGBOX_MENUBAR_NOSTART=1)"
elif launchctl bootstrap "gui/$uid" "$AGENT" 2>/dev/null; then
    say "индикатор запущен — значок-щит в менюбаре"
else
    say "агент поставлен, но не запустился из этой сессии (нет графического входа?) — появится после входа в систему"
fi

# что ещё нужно индикатору — только подсказки, ничего не меняем
say ""
ok=1
if [ ! -f "/Library/LaunchDaemons/$DAEMON.plist" ]; then
    ok=0; say "• нет демона /Library/LaunchDaemons/$DAEMON.plist — индикатор будет показывать «выключен»"
elif ! curl -s --max-time 2 "$API/version" >/dev/null 2>&1; then
    ok=0; say "• Clash API на 127.0.0.1:9190 не отвечает — демон выключен или в конфиге другой порт"
fi
if ! sudo -n /bin/launchctl print "system/$DAEMON" >/dev/null 2>&1; then
    ok=0; say "• нет беспарольного launchctl для $DAEMON (sudoers) или демон не загружен — кнопка «Включить/Выключить» не сработает"
fi
if [ $ok = 1 ]; then
    say "демон sing-box найден, API отвечает — всё готово"
else
    say "как настроить демон: https://github.com/kkdclaw/singbox-menubar#что-нужно-чтобы-он-работал"
fi
