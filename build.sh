#!/bin/sh
# Сборка sing-box.app (universal: arm64 + x86_64) в ./build и архива в ./dist.
# Нужен Xcode Command Line Tools: xcode-select --install
set -eu
cd "$(dirname "$0")"

MIN=14.0
APP=build/sing-box.app

rm -rf build
mkdir -p "$APP/Contents/MacOS" dist
cp Info.plist "$APP/Contents/"

for arch in arm64 x86_64; do
    xcrun swiftc -O -target "$arch-apple-macos$MIN" -o "build/menubar-$arch" menubar.swift
done
lipo -create build/menubar-arm64 build/menubar-x86_64 -output "$APP/Contents/MacOS/singbox-menubar"
codesign --force -s - "$APP"

rm -f dist/sing-box.app.zip
ditto -c -k --keepParent "$APP" dist/sing-box.app.zip
(cd dist && shasum -a 256 sing-box.app.zip > sing-box.app.zip.sha256)

echo "готово: $APP, dist/sing-box.app.zip"
lipo -archs "$APP/Contents/MacOS/singbox-menubar"
