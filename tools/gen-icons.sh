#!/usr/bin/env bash
# gen-icons.sh – renders the logo (design/icon.png) into the app icons (Android mipmaps,
# Windows .ico, Linux PNG) and the web app icons. Sizes up to 32 px use a crop of the head
# with headphones (design/icon-small.png, generated here), larger ones the full logo.
#
#   tools/gen-icons.sh
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")/.."
SRC=design/icon.png
SMALL=design/icon-small.png
convert "$SRC" -crop 600x600+160+110 +repage \
    \( -size 600x600 xc:none -fill white -draw "circle 300,300 300,2" \) -compose DstIn -composite "$SMALL"
render() {
    local src=$SRC
    [ "$1" -le 32 ] && src=$SMALL
    convert "$src" -filter Lanczos -resize "$1x$1" -strip "$2"
}

APP=clients/app
for d in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
    render "${d#*:}" "$APP/android/app/src/main/res/mipmap-${d%%:*}/ic_launcher.png"
done
# Adaptive icon (Android 8+): without it launchers shrink the round logo into a white disc.
# Foreground canvas 108 dp; the logo covers 78 % so its circle fills the launcher mask.
for d in mdpi:108 hdpi:162 xhdpi:216 xxhdpi:324 xxxhdpi:432; do
    n=${d#*:}
    convert "$SRC" -filter Lanczos -resize "$((n * 78 / 100))x$((n * 78 / 100))" -background none -gravity center \
        -extent "${n}x${n}" -strip "$APP/android/app/src/main/res/mipmap-${d%%:*}/ic_launcher_foreground.png"
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
render 32 clients/web/public/favicon.png
echo "icons written"
