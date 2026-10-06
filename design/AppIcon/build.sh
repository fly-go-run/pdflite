#!/bin/bash
set -euo pipefail

icon_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$icon_dir/../.." && pwd)"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/pdflite-icon.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT

swift "$icon_dir/render.swift" "$scratch_dir" >/dev/null

iconutil -c icns "$scratch_dir/AppIcon.iconset" \
    -o "$repo_dir/PDFLite/Resources/AppIcon.icns"
cp "$scratch_dir/source.png" "$scratch_dir/preview.png" "$icon_dir/"
cp "$scratch_dir"/extension/icon*.png "$repo_dir/browser-extension/icons/"
printf 'Generated PDFLite/Resources/AppIcon.icns and browser-extension/icons\n'
