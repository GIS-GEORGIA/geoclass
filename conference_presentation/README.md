# GeoClass: conference presentation

This folder holds the talk for the scientific conference "Modern Problems of Geography" (19 December 2026): 15 minutes of talk and 5 minutes of discussion. There are two equivalent decks, one in Georgian and one in English.

| File | What it is |
|---|---|
| `GeoClass_Conference_KA.pptx` / `_EN.pptx` | Editable decks (16:9), with speaker notes on every slide |
| `GeoClass_Conference_KA.pdf` / `_EN.pdf` | PDF export, with the fonts embedded |
| `slide_content_KA.md` / `_EN.md` | The slide text as plain Markdown |
| `speaker_notes_KA.md` / `_EN.md` | The speaker notes, with a word count and an estimated duration |
| `presentation_sources.md` | Evidence for every claim, status codes and references |
| `assets/` | Real app screenshots and generated backgrounds and QR codes |
| `_build/` | Scripts that regenerate everything |

## Before the talk

1. **Speaker.** Slides 1 and 15 name Giorgi Kapanadze, Associate Professor at BTU, with the ORCID (as in `CITATION.cff`). To change this, edit `speaker` and `aff` in `_build/content.mjs` and rebuild. Rebuilding overwrites edits made only in the `.pptx`.
2. **Present from the PDF if you are not sure about the conference computer.** The `.pptx` uses Noto Sans, Noto Serif, Noto Sans Georgian and Noto Serif Georgian. If these fonts are missing, PowerPoint substitutes others and the Georgian layout may shift. All four are free (SIL OFL), and the Georgian ones are also in `assets/fonts/` of this repository.
3. **Check the timing.**
   - English notes: about 1,670 words, roughly 12 minutes.
   - Georgian notes: about 1,180 words, roughly 12 minutes at a measured pace.

## Rebuild

You need Node.js, Python 3 (with matplotlib and qrcode), LibreOffice and `pdftoppm`. The build uses `pptxgenjs` 4.0.1, the copy already installed in `~/Projects/GIS Day/node_modules`. In a fresh environment, run `npm install pptxgenjs@4.0.1` in `_build/` and leave out `NODE_PATH`.

```bash
cd conference_presentation/_build
python3 make_backgrounds.py ../assets/generated
NODE_PATH="$HOME/Projects/GIS Day/node_modules" node build.mjs
./render.sh
```

- `build.mjs` writes both `.pptx` files and the four Markdown files from `content.mjs`. All the text lives in `content.mjs`, so the two languages cannot drift apart.
- `render.sh` exports the PDFs and writes slide previews to `_build/preview_*`.

## Retaking the screenshots

The screenshots come from a local development server, never from the live site:

1. Start `wrangler dev` on port 8788 with a local database and a local-only teacher key (`local-check-key`).
2. Seed it with made-up demonstration sessions.
3. Capture with headless Chromium through `playwright-core`.

```bash
python3 _build/seed.py _build/tokens.json
```

```bash
_build/capture.sh en
```

```bash
_build/capture.sh ka
```

`capture.sh` clicks at fixed screen positions, so check the images after any change to the app's layout.
