#!/bin/sh
# Удаление индикатора sing-box из менюбара.
#
#   curl -fsSL https://raw.githubusercontent.com/kkdclaw/singbox-menubar/main/uninstall.sh | sh
#
# Убирает LaunchAgent и ~/Applications/sing-box.app. Сам sing-box, его конфиг и демон не трогает.
set -eu

BUNDLE_ID="com.kkd.singbox-menubar"
APP="$HOME/Applications/sing-box.app"
AGENT="$HOME/Library/LaunchAgents/$BUNDLE_ID.plist"

launchctl bootout "gui/$(id -u)/$BUNDLE_ID" 2>/dev/null || true
rm -f "$AGENT"

if [ -d "$APP" ]; then
    have=$(/usr/bin/defaults read "$APP/Contents/Info" CFBundleIdentifier 2>/dev/null || true)
    if [ "$have" = "$BUNDLE_ID" ]; then
        rm -rf "$APP"
    else
        echo "$APP — не индикатор ($have), не трогаю" >&2
    fi
fi
defaults delete "$BUNDLE_ID" 2>/dev/null || true

echo "индикатор удалён; sing-box и его конфиг остались как были"
