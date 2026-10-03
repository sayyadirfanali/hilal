#!/bin/sh
set -eu

TAILWIND_VERSION=v4.3.1
DAISYUI_VERSION=v5.6.0

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

echo "vendor/: tailwindcss $TAILWIND_VERSION, daisyUI $DAISYUI_VERSION"