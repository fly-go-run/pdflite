#!/bin/bash
set -euo pipefail

icon_dir="$(cd "$(dirname "$0")" && pwd)"
repo_dir="$(cd "$icon_dir/../.." && pwd)"
scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/pdflite-icon.XXXXXX")"
trap 'rm -rf "$scratch_dir"' EXIT
iconset_dir="$scratch_dir/AppIcon.iconset"
mkdir -p "$iconset_dir"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_dir/source.png" \
        --out "$iconset_dir/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" "$icon_dir/source.png" \
        --out "$iconset_dir/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset_dir" \
    -o "$repo_dir/PDFLite/Resources/AppIcon.icns"
printf 'Generated PDFLite/Resources/AppIcon.icns\n'
