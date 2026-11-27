#!/bin/bash
# Converts both decks to PDF with LibreOffice and renders slide previews to PNG.
cd "$(dirname "$0")/.."
for L in KA EN; do
  soffice --headless --convert-to pdf --outdir . GeoClass_Conference_$L.pptx >/dev/null 2>&1
  mkdir -p _build/preview_$L && rm -f _build/preview_$L/*.png
  pdftoppm -r 60 -png GeoClass_Conference_$L.pdf _build/preview_$L/s
done
