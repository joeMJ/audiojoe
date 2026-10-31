#!/usr/bin/env bash
# gen-icons.sh – renders design/icon.svg into the app icons (Android mipmaps, Windows .ico,
# Linux PNG) and the web app icons. Needs ImageMagick with SVG support (rsvg).
#
#   tools/gen-icons.sh
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
SVG=design/icon.svg
render() { convert -background none -density 384 "$SVG" -resize "$1x$1" "$2"; }

APP=clients/app
for d in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
    render "${d#*:}" "$APP/android/app/src/main/res/mipmap-${d%%:*}/ic_launcher.png"
done
mkdir -p "$APP/assets"
render 256 "$APP/assets/icon.png"
tmp=$(mktemp -d)
for s in 16 24 32 48 64 128 256; do render "$s" "$tmp/$s.png"; done
convert "$tmp"/{16,24,32,48,64,128,256}.png "$APP/windows/runner/resources/app_icon.ico"
rm -rf "$tmp"
mkdir -p clients/web/public
render 192 clients/web/public/icon-192.png
render 512 clients/web/public/icon-512.png
echo "icons written"
