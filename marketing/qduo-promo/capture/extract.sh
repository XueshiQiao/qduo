#!/usr/bin/env bash
# Takes (ProRes, BT.709 video range) → 60 fps sRGB JPEG frames the film reads.
# Frame N (1-based) is the take at (N-1)/60 s.
set -euo pipefail
cd "$(dirname "$0")/.."
for n in ${@:-liquid donut polish read}; do
  for take in $n; do
    [ -f "capture/takes/$take.mov" ] || { echo "no take $take" >&2; exit 1; }
    mkdir -p "frames/$take"; rm -f "frames/$take"/*.jpg
    ffmpeg -v error -i "capture/takes/$take.mov" \
      -vf "fps=60,scale=in_color_matrix=bt709:in_range=tv:out_range=pc,format=rgb24" -q:v 3 "frames/$take/%04d.jpg"
    echo "$take: $(ls "frames/$take" | wc -l | tr -d ' ') frames"
  done
done
# The film reads the frame counts from here (file:// pages cannot list a folder).
{ printf 'window.FRAMES={'; for d in frames/*/; do t=$(basename "$d"); printf '"%s":%s,' "$t" "$(ls "$d" | wc -l | tr -d ' ')"; done; printf '};\n'; } > frames/manifest.js
cat frames/manifest.js
