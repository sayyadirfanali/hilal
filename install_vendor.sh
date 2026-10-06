#!/bin/sh
set -eu

TAILWIND_VERSION=v4.3.1
DAISYUI_VERSION=v5.6.0
# MapLibre 6 ships only as ES modules split across several files;
# version 5 is the last with a single browser bundle, which is simpler to embed.
MAPLIBRE_VERSION=5.24.0
INTER_VERSION=5.3.0
NOTO_ARABIC_VERSION=5.3.0

# Every Urdu word Hilal shows: prayer names (Hilal.Types), column headings
# (Hilal.Views), and Hijri months (Hilal.Hijri). The Urdu font is cut down to
# exactly these letters, so a new Urdu word must be added here, then this script re-run.
URDU_TEXT="فجر ظہر عصر مغرب عشاء جمعہ نماز اذان جماعت \
محرم صفر ربیع الاول الثانی جمادی رجب شعبان رمضان شوال ذوالقعدہ ذوالحجہ"

if ! command -v pyftsubset >/dev/null 2>&1 || ! python3 -c "import brotli" 2>/dev/null; then
  echo "needs fonttools and brotli: pip install fonttools brotli" >&2
  exit 1
fi

case "$(uname -s)-$(uname -m)" in
  Linux-x86_64)  platform=linux-x64 ;;
  Linux-aarch64) platform=linux-arm64 ;;
  Darwin-arm64)  platform=macos-arm64 ;;
  Darwin-x86_64) platform=macos-x64 ;;
  *) echo "unsupported platform: $(uname -s)-$(uname -m)" >&2; exit 1 ;;
esac

mkdir -p vendor

curl -fsSL -o vendor/tailwindcss \
  "https://github.com/tailwindlabs/tailwindcss/releases/download/$TAILWIND_VERSION/tailwindcss-$platform"
chmod +x vendor/tailwindcss

for f in daisyui.mjs daisyui-theme.mjs; do
  curl -fsSL -o "vendor/$f" \
    "https://github.com/saadeghi/daisyui/releases/download/$DAISYUI_VERSION/$f"
done

tmp=$(mktemp -d)
curl -fsSL -o "$tmp/maplibre.tgz" \
  "https://registry.npmjs.org/maplibre-gl/-/maplibre-gl-$MAPLIBRE_VERSION.tgz"
tar -xzf "$tmp/maplibre.tgz" -C "$tmp" package/dist/maplibre-gl.js package/dist/maplibre-gl.css
cp "$tmp/package/dist/maplibre-gl.js" "$tmp/package/dist/maplibre-gl.css" vendor/
rm -rf "$tmp"

tmp=$(mktemp -d)
curl -fsSL -o "$tmp/inter.tgz" \
  "https://registry.npmjs.org/@fontsource-variable/inter/-/inter-$INTER_VERSION.tgz"
tar -xzf "$tmp/inter.tgz" -C "$tmp" package/files/inter-latin-wght-normal.woff2
cp "$tmp/package/files/inter-latin-wght-normal.woff2" vendor/inter.woff2
rm -rf "$tmp"

tmp=$(mktemp -d)
curl -fsSL -o "$tmp/arabic.tgz" \
  "https://registry.npmjs.org/@fontsource-variable/noto-sans-arabic/-/noto-sans-arabic-$NOTO_ARABIC_VERSION.tgz"
tar -xzf "$tmp/arabic.tgz" -C "$tmp" package/files/noto-sans-arabic-arabic-wght-normal.woff2
pyftsubset "$tmp/package/files/noto-sans-arabic-arabic-wght-normal.woff2" \
  --text="$URDU_TEXT" --flavor=woff2 --output-file=vendor/urdu.woff2
rm -rf "$tmp"

echo "vendor/: tailwindcss $TAILWIND_VERSION, daisyUI $DAISYUI_VERSION, MapLibre $MAPLIBRE_VERSION, Inter $INTER_VERSION, Noto Sans Arabic $NOTO_ARABIC_VERSION (Urdu subset)"
