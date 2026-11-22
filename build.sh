#!/bin/bash
# HexShot.app'i derler, yerel (ad-hoc) olarak imzalar ve /Applications'a kurar.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/HexShot.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -target arm64-apple-macos14.0 -o "$APP/Contents/MacOS/HexShot" Sources/main.swift
cp Info.plist "$APP/Contents/Info.plist"
# Sabit kural: izin her derlemede sıfırlanmasın diye imza kuralı paket kimliğine bağlanır.
codesign --force --sign - -r='designated => identifier "local.hexshot.app"' "$APP"
echo "Derlendi: $(pwd)/$APP"

if [[ "${1:-}" != "--no-install" ]]; then
  pkill -x HexShot 2>/dev/null || true
  rm -rf /Applications/HexShot.app
  cp -R "$APP" /Applications/HexShot.app
  echo "Kuruldu: /Applications/HexShot.app"
fi
