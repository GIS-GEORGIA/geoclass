// Builds GeoClass_Conference_{KA,EN}.pptx and the Markdown companions from content.mjs.
// Usage: NODE_PATH=<dir with pptxgenjs> node build.mjs
import { createRequire } from 'module';
import fs from 'fs';
import path from 'path';
import { T, GAMES, MATRIX } from './content.mjs';

const require = createRequire(import.meta.url);
const PptxGenJS = require('pptxgenjs');
const OUT = path.resolve('..');
const A = (p) => path.join(OUT, 'assets', p);

const C = { navy: '1B2A41', navy2: '24385A', green: '2E7D5B', green2: 'E3EFE8', bg: 'F6F2EA', card: 'FFFDF8', line: 'D9CFBC', text: '1F2733', mute: '5B6472', accent: 'C27C2C', accent2: 'F5E6D0', white: 'FFFFFF' };
const W = 13.333, H = 7.5, M = 0.55;

// Noto Sans/Serif Georgian have no Latin letters or digits, so in the Georgian deck every Latin/digit run gets
// the matching Noto Latin face; otherwise viewers fall back glyph by glyph and digits come out spaced.
const LATIN = /([A-Za-z0-9@#][A-Za-z0-9@#.,:/\-–()°′″%+_&·'’ ]*[A-Za-z0-9)%°′″.]|[A-Za-z0-9])/;
function splitRuns(content, face, geoFaces) {
  if (!geoFaces.includes(face)) return content;
  const latin = face.includes('Serif') ? 'Noto Serif' : 'Noto Sans';
  const pieces = (text, options = {}) => {
    const parts = String(text).split(LATIN).filter((x) => x !== '');
    return parts.map((t, i) => ({ text: t, options: { ...options, ...(LATIN.test(t) && /^[A-Za-z0-9@#]/.test(t) ? { fontFace: latin } : {}), breakLine: i === parts.length - 1 ? options.breakLine : false, ...(i > 0 ? { bullet: undefined, paraSpaceAfter: undefined } : {}) } }));
  };
  if (typeof content === 'string') return pieces(content);
  return content.flatMap((r) => pieces(r.text, r.options));
}

function build(lang) {
  const L = T[lang];
  const F = L.font, HF = L.head;
  const pptx0 = new PptxGenJS();
  pptx0.layout = 'LAYOUT_WIDE';
  const geo = lang === 'ka' ? [F, HF] : [];
  const pptx = new Proxy(pptx0, { get(t, k) {
    if (k !== 'addSlide') { const v = t[k]; return typeof v === 'function' ? v.bind(t) : v; }
    return (...a) => { const sl = t.addSlide(...a); const orig = sl.addText.bind(sl); sl.addText = (c, o) => orig(splitRuns(c, o.fontFace, geo), o); return sl; };
  }, set(t, k, v) { t[k] = v; return true; } });
  pptx.author = '[Speaker name]';
  pptx.title = L.title;
  pptx.subject = L.confLine;
  const S = Object.fromEntries(L.s.map((x) => [x.key, x]));
  const total = L.s.length;
  let n = 0;

  const base = (slide, s, opts = {}) => {
    n += 1;
    slide.background = { path: A(opts.plain ? 'generated/bg_section.png' : 'generated/bg_light.png') };
    slide.addShape('rect', { x: 0, y: 0, w: 0.16, h: H, fill: { color: C.green }, line: { color: C.green } });
    slide.addText(s.title, { x: M, y: 0.32, w: W - 2 * M, h: 0.7, fontFace: HF, fontSize: lang === 'ka' ? 25 : 28, bold: true, color: C.navy, margin: 0, valign: 'middle' });
    if (s.lead) slide.addText(s.lead, { x: M, y: 1.02, w: W - 2 * M, h: 0.45, fontFace: F, fontSize: lang === 'ka' ? 14 : 15, color: C.green, margin: 0, valign: 'top' });
    slide.addShape('line', { x: M, y: 6.95, w: W - 2 * M, h: 0, line: { color: C.line, width: 0.75 } });
    slide.addText(L.footer, { x: M, y: 7.0, w: 6, h: 0.3, fontFace: F, fontSize: 9, color: C.mute, margin: 0 });
    if (s.cite) slide.addText(s.cite, { x: 6.2, y: 7.0, w: W - M - 6.2 - 0.6, h: 0.3, fontFace: 'Noto Sans', fontSize: 8.5, italic: true, color: C.mute, align: 'right', margin: 0 });
    slide.addText(`${n}/${total}`, { x: W - M - 0.55, y: 7.0, w: 0.55, h: 0.3, fontFace: 'Noto Sans', fontSize: 9, bold: true, color: C.navy, align: 'right', margin: 0 });
    slide.addNotes(s.notes);
  };
  const tag = (slide, kind, x, y) => {
    const colors = { impl: [C.green, C.white], rationale: [C.accent2, C.accent], hyp: ['EDE3F3', '6B4C8A'], plan: ['E2E8F2', C.navy2] };
    const [fill, color] = colors[kind];
    slide.addText(L.tags[kind], { x, y, w: 2.3, h: 0.28, fontFace: F, fontSize: 9.5, bold: true, color, fill: { color: fill }, align: 'center', valign: 'middle', margin: 0, rectRadius: 0.06, shape: 'roundRect' });
  };
  const shot = (slide, file, x, y, h, cap, ratio) => {
    const w = h * ratio;
    slide.addShape('rect', { x: x - 0.04, y: y - 0.04, w: w + 0.08, h: h + 0.08, fill: { color: C.white }, line: { color: C.line, width: 1 }, shadow: { type: 'outer', blur: 4, offset: 2, angle: 90, color: '000000', opacity: 0.15 } });
    slide.addImage({ path: A('screens/' + file), x, y, w, h });
    if (cap) slide.addText(cap, { x: x - 0.3, y: y + h + 0.08, w: w + 0.6, h: 0.42, fontFace: F, fontSize: 9.5, color: C.mute, align: 'center', valign: 'top', margin: 0 });
    return w;
  };
  const phone = 412 / 915, desk = 1440 / 900;

  // 1 Title
  {
    const s = S.title; const slide = pptx.addSlide(); n += 1;
    slide.background = { path: A('generated/bg_title.png') };
    slide.addText(L.confLine, { x: M, y: 0.45, w: 12, h: 0.35, fontFace: F, fontSize: 13, color: 'A9C3DA', margin: 0 });
    slide.addText(L.title, { x: M, y: 1.05, w: 7.9, h: 2.2, fontFace: HF, fontSize: lang === 'ka' ? 32 : 36, bold: true, color: C.white, margin: 0, valign: 'top' });
    slide.addShape('rect', { x: M, y: 3.45, w: 1.2, h: 0.07, fill: { color: C.accent }, line: { color: C.accent } });
    slide.addText(L.subtitle, { x: M, y: 3.7, w: 8.2, h: 0.9, fontFace: F, fontSize: 16, color: 'DCE6EF', margin: 0, valign: 'top' });
    slide.addText(L.speaker, { x: M, y: 4.85, w: 8.2, h: 0.4, fontFace: F, fontSize: 15, bold: true, color: C.white, margin: 0 });
    slide.addText(L.orgs, { x: M, y: 5.6, w: 8.2, h: 0.65, fontFace: F, fontSize: 11, color: 'A9C3DA', margin: 0, valign: 'top' });
    slide.addText(L.anniv, { x: M, y: 6.35, w: 8.2, h: 0.4, fontFace: F, fontSize: 12, italic: true, color: 'E8C48F', margin: 0 });
    slide.addImage({ path: A(`screens/${lang}_teacher_travel.png`), x: 8.75, y: 1.35, w: 4.2, h: 4.2 / desk });
    slide.addImage({ path: A(`screens/${lang}_st_travel.png`), x: 11.55, y: 2.75, w: 1.75, h: 1.75 / phone });
    slide.addText('geoclass.qgis.ge · doi.org/10.5281/zenodo.24144115', { x: 8.75, y: 6.75, w: 4.4, h: 0.3, fontFace: 'Noto Sans', fontSize: 9.5, color: 'A9C3DA', align: 'right', margin: 0 });
    slide.addNotes(s.notes);
  }

  // 2 Challenge
  {
    const s = S.challenge; const slide = pptx.addSlide(); base(slide, s);
    const tw = (W - 2 * M - 3 * 0.25) / 4;
    s.tiles.forEach(([h, b], i) => {
      const x = M + i * (tw + 0.25), y = 1.75;
      slide.addShape('rect', { x, y, w: tw, h: 3.55, fill: { color: C.card }, line: { color: C.line, width: 1 } });
      slide.addShape('rect', { x, y, w: tw, h: 0.09, fill: { color: [C.navy, C.green, C.accent, C.navy2][i] }, line: { type: 'none' } });
      slide.addText(String(i + 1).padStart(2, '0'), { x: x + 0.25, y: y + 0.3, w: 1, h: 0.5, fontFace: 'Noto Serif', fontSize: 26, bold: true, color: C.line, margin: 0 });
      slide.addText(h, { x: x + 0.25, y: y + 0.9, w: tw - 0.5, h: 0.9, fontFace: HF, fontSize: lang === 'ka' ? 16 : 18, bold: true, color: C.navy, margin: 0, valign: 'top' });
      slide.addText(b, { x: x + 0.25, y: y + 1.85, w: tw - 0.5, h: 1.6, fontFace: F, fontSize: 12.5, color: C.text, margin: 0, valign: 'top' });
    });
    slide.addShape('rect', { x: M, y: 5.6, w: W - 2 * M, h: 0.8, fill: { color: C.accent2 }, line: { type: 'none' } });
    slide.addText(s.note, { x: M + 0.3, y: 5.6, w: W - 2 * M - 0.6, h: 0.8, fontFace: F, fontSize: 14, color: C.text, margin: 0, valign: 'middle' });
    tag(slide, 'rationale', W - M - 2.3, 0.08);
  }

  // 3 Ladder
  {
    const s = S.ladder; const slide = pptx.addSlide(); base(slide, s);
    const k = s.steps.length, sw = 1.92, gap = 0.12;
    s.steps.forEach(([h, sub, games], i) => {
      const x = M + i * (sw + gap), hgt = 1.95 + i * 0.44, y = 6.15 - hgt;
      const last = i === k - 1;
      const fill = last ? C.navy : i === k - 2 ? C.green : C.card;
      slide.addShape('rect', { x, y, w: sw, h: hgt, fill: { color: fill }, line: { color: last ? C.navy : C.line, width: 1 } });
      slide.addText(h, { x: x + 0.12, y: y + 0.12, w: sw - 0.24, h: 0.75, fontFace: HF, fontSize: lang === 'ka' ? 13 : 14.5, bold: true, color: last || i === k - 2 ? C.white : C.navy, margin: 0, valign: 'top' });
      slide.addText(sub, { x: x + 0.12, y: y + 0.85, w: sw - 0.24, h: 0.55, fontFace: F, fontSize: 11, color: last || i === k - 2 ? 'E5ECF2' : C.mute, margin: 0, valign: 'top' });
      slide.addText(games, { x: x + 0.12, y: 6.15 - 0.62, w: sw - 0.24, h: 0.52, fontFace: F, fontSize: 10, bold: true, color: last ? 'E8C48F' : i === k - 2 ? C.white : C.green, margin: 0, valign: 'bottom' });
    });
    slide.addText(s.foot, { x: M, y: 6.3, w: W - 2 * M, h: 0.5, fontFace: F, fontSize: 10, italic: true, color: C.mute, margin: 0, valign: 'top' });
    tag(slide, 'impl', M, 1.55); tag(slide, 'rationale', M + 2.45, 1.55);
  }

  // 4 Workflow
  {
    const s = S.workflow; const slide = pptx.addSlide(); base(slide, s);
    const bw = 4.6, bh = 0.62, x0 = M, y0 = 1.7;
    s.flow.forEach((t, i) => {
      const y = y0 + i * (bh + 0.2);
      slide.addShape('roundRect', { x: x0, y, w: bw, h: bh, rectRadius: 0.08, fill: { color: i === 4 ? C.green : i === 5 ? C.navy : C.card }, line: { color: i >= 4 ? (i === 4 ? C.green : C.navy) : C.line, width: 1 } });
      slide.addText(String(i + 1), { x: x0 + 0.12, y: y + 0.11, w: 0.4, h: 0.4, fontFace: 'Noto Sans', fontSize: 13, bold: true, color: i >= 4 ? C.navy : C.white, fill: { color: i >= 4 ? C.white : C.green }, align: 'center', valign: 'middle', shape: 'ellipse', margin: 0 });
      slide.addText(t, { x: x0 + 0.65, y, w: bw - 0.8, h: bh, fontFace: F, fontSize: 13.5, bold: i >= 4, color: i >= 4 ? C.white : C.text, margin: 0, valign: 'middle' });
      if (i < 5) slide.addShape('downArrow', { x: x0 + bw / 2 - 0.1, y: y + bh + 0.02, w: 0.2, h: 0.16, fill: { color: C.accent }, line: { type: 'none' } });
    });
    slide.addText(s.tech, { x: M, y: 6.45, w: W - 2 * M, h: 0.38, fontFace: 'Noto Sans', fontSize: 11, color: C.navy, fill: { color: C.green2 }, margin: 0.08, valign: 'middle' });
    shot(slide, `${lang}_qr.png`, 5.65, 1.75, 3.3, s.cap1, desk);
    shot(slide, `${lang}_st_travel.png`, 11.2, 1.65, 3.95, s.cap2, phone);
    tag(slide, 'impl', W - M - 2.3, 0.08);
  }

  // 5 Games
  {
    const s = S.games; const slide = pptx.addSlide(); base(slide, s);
    const icons = { travel: '✈', coords: '⌖', aerial: '◩', mapping: '✎', cards: '▣', detective: '⌕', plates: '◍', puzzle: '◈', layout: '▤' };
    const cw = 3.95, ch = 1.45, gx = 0.17, gy = 0.13, x0 = M, y0 = 1.55;
    GAMES.forEach((g, i) => {
      const G = L.games[g]; const r = Math.floor(i / 3), c = i % 3;
      const x = x0 + c * (cw + gx), y = y0 + r * (ch + gy);
      slide.addShape('rect', { x, y, w: cw, h: ch, fill: { color: C.card }, line: { color: C.line, width: 1 } });
      slide.addShape('rect', { x, y, w: 0.07, h: ch, fill: { color: [C.navy, C.green, C.accent][r] }, line: { type: 'none' } });
      slide.addText(String(i + 1), { x: x + 0.2, y: y + 0.12, w: 0.38, h: 0.38, fontFace: 'Noto Sans', fontSize: 12, bold: true, color: C.white, fill: { color: [C.navy, C.green, C.accent][r] }, shape: 'ellipse', align: 'center', valign: 'middle', margin: 0 });
      slide.addText(G.n, { x: x + 0.7, y: y + 0.1, w: cw - 0.85, h: 0.42, fontFace: HF, fontSize: lang === 'ka' ? 13 : 14, bold: true, color: C.navy, margin: 0, valign: 'middle' });
      slide.addText([
        { text: '▸ ', options: { color: C.green, bold: true } }, { text: G.a, options: { breakLine: true } },
        { text: '◆ ', options: { color: C.accent, bold: true } }, { text: G.s, options: { breakLine: true } },
        { text: '? ', options: { color: C.navy2, bold: true } }, { text: G.r },
      ], { x: x + 0.22, y: y + 0.56, w: cw - 0.35, h: 0.85, fontFace: F, fontSize: 10.5, color: C.text, margin: 0, valign: 'top', paraSpaceAfter: 1 });
    });
    slide.addText([
      { text: '▸ ' + s.legend[0] + '    ', options: { color: C.green } }, { text: '◆ ' + s.legend[1] + '    ', options: { color: C.accent } }, { text: '? ' + s.legend[2], options: { color: C.navy2 } },
    ], { x: M, y: 6.33, w: 4.3, h: 0.5, fontFace: F, fontSize: 10, bold: true, margin: 0, valign: 'middle' });
    slide.addText(s.more, { x: 4.95, y: 6.3, w: W - M - 4.95, h: 0.6, fontFace: F, fontSize: 9, color: C.navy, fill: { color: C.green2 }, margin: 0.06, valign: 'middle' });
    tag(slide, 'impl', W - M - 2.3, 0.08);
  }

  // 6 Matrix
  {
    const s = S.matrix; const slide = pptx.addSlide(); base(slide, s);
    const lx = M, lw = lang === 'ka' ? 2.75 : 2.55, cw = 0.6, rh = 0.47, y0 = 1.95;
    GAMES.forEach((g, j) => slide.addText(s.short[g], { x: lx + lw + j * cw, y: y0 - 0.42, w: cw, h: 0.38, fontFace: F, fontSize: 9, bold: true, color: C.navy, align: 'center', valign: 'bottom', margin: 0 }));
    Object.keys(MATRIX).forEach((k, i) => {
      const y = y0 + i * rh;
      if (i % 2 === 0) slide.addShape('rect', { x: lx, y, w: lw + 9 * cw, h: rh, fill: { color: 'EFE8DA' }, line: { type: 'none' } });
      slide.addText(s.skills[k], { x: lx + 0.1, y, w: lw - 0.1, h: rh, fontFace: F, fontSize: 11, color: C.text, margin: 0, valign: 'middle' });
      MATRIX[k].forEach((v, j) => {
        if (!v) return;
        const d = v === 2 ? 0.26 : 0.22;
        slide.addShape('ellipse', { x: lx + lw + j * cw + (cw - d) / 2, y: y + (rh - d) / 2, w: d, h: d, fill: { color: v === 2 ? C.green : C.card }, line: { color: C.green, width: 1.5 } });
      });
    });
    const ky = y0 + 8 * rh + 0.12;
    slide.addShape('ellipse', { x: lx, y: ky + 0.05, w: 0.2, h: 0.2, fill: { color: C.green }, line: { color: C.green } });
    slide.addText(s.key2, { x: lx + 0.28, y: ky, w: 2, h: 0.3, fontFace: F, fontSize: 10, color: C.mute, margin: 0, valign: 'middle' });
    slide.addShape('ellipse', { x: lx + 2.3, y: ky + 0.05, w: 0.2, h: 0.2, fill: { color: C.card }, line: { color: C.green, width: 1.5 } });
    slide.addText(s.key1, { x: lx + 2.58, y: ky, w: 2.2, h: 0.3, fontFace: F, fontSize: 10, color: C.mute, margin: 0, valign: 'middle' });
    slide.addText(s.caveat, { x: lx, y: ky + 0.38, w: lw + 9 * cw, h: 0.3, fontFace: F, fontSize: 10, italic: true, color: C.accent, margin: 0 });
    // cycle
    const cx = 10.45, cy = 3.55, rad = 1.35;
    slide.addShape('ellipse', { x: cx - rad, y: cy - rad, w: 2 * rad, h: 2 * rad, fill: { type: 'none' }, line: { color: C.line, width: 2, dashType: 'dash' } });
    s.cycle.forEach((t, i) => {
      const a = -Math.PI / 2 + (i * Math.PI) / 2;
      const bx = cx + rad * Math.cos(a) - 0.95, by = cy + rad * Math.sin(a) - 0.33;
      slide.addShape('roundRect', { x: bx, y: by, w: 1.9, h: 0.66, rectRadius: 0.1, fill: { color: [C.navy, C.green, C.accent, C.navy2][i] }, line: { type: 'none' } });
      slide.addText(t, { x: bx + 0.05, y: by, w: 1.8, h: 0.66, fontFace: F, fontSize: 11, bold: true, color: C.white, align: 'center', valign: 'middle', margin: 0 });
    });
    slide.addText('↻', { x: cx - 0.5, y: cy - 0.5, w: 1, h: 1, fontFace: 'DejaVu Sans', fontSize: 34, color: C.line, align: 'center', valign: 'middle', margin: 0 });
    slide.addText(s.example, { x: 8.3, y: 5.45, w: W - M - 8.3, h: 1.3, fontFace: F, fontSize: 11, italic: true, color: C.text, fill: { color: C.accent2 }, margin: 0.1, valign: 'middle' });
    tag(slide, 'rationale', W - M - 2.3, 0.08);
  }

  // 7 Teacher
  {
    const s = S.teacher; const slide = pptx.addSlide(); base(slide, s);
    const rw = 2.2, rh2 = 0.6;
    s.roles.forEach((t, i) => {
      const c = i % 2, r = Math.floor(i / 2), x = M + c * (rw + 0.12), y = 1.6 + r * (rh2 + 0.08);
      slide.addShape('rect', { x, y, w: rw, h: rh2, fill: { color: i < 3 ? C.card : i < 6 ? C.green2 : C.accent2 }, line: { color: C.line, width: 0.75 } });
      slide.addText(t, { x: x + 0.1, y, w: rw - 0.2, h: rh2, fontFace: F, fontSize: 10.5, bold: true, color: C.navy, margin: 0, valign: 'middle' });
    });
    slide.addText(s.lessonTitle, { x: M, y: 4.4, w: 4.3, h: 0.35, fontFace: HF, fontSize: 13, bold: true, color: C.navy, margin: 0 });
    s.lesson.forEach(([t, d], i) => {
      const y = 4.8 + i * 0.4;
      slide.addText(t, { x: M, y, w: 0.75, h: 0.34, fontFace: 'Noto Sans', fontSize: 10.5, bold: true, color: C.white, fill: { color: C.green }, align: 'center', valign: 'middle', margin: 0 });
      slide.addText(d, { x: M + 0.85, y, w: 3.4, h: 0.34, fontFace: F, fontSize: 10.5, color: C.text, margin: 0, valign: 'middle' });
    });
    shot(slide, `${lang}_teacher_travel.png`, 5.3, 1.7, 4.55, s.cap, desk);
    tag(slide, 'impl', W - M - 2.3, 0.08);
  }

  // 8 Privacy
  {
    const s = S.privacy; const slide = pptx.addSlide(); base(slide, s);
    slide.addText(s.measures.map((t, i) => ({ text: t, options: { bullet: { code: '2713' }, breakLine: i < s.measures.length - 1 } })), { x: M, y: 1.6, w: 6.3, h: 3.55, fontFace: F, fontSize: 11.5, color: C.text, margin: 0, valign: 'top', paraSpaceAfter: 3 });
    const px = 7.05, pw = 3.15;
    s.principles.forEach((t, i) => {
      const y = 1.6 + i * 0.52;
      slide.addShape('rect', { x: px, y, w: pw, h: 0.44, fill: { color: i % 2 ? C.green2 : C.card }, line: { color: C.line, width: 0.75 } });
      slide.addText(t, { x: px + 0.1, y, w: pw - 0.2, h: 0.44, fontFace: F, fontSize: 10.5, bold: true, color: C.navy, margin: 0, valign: 'middle' });
    });
    slide.addText(s.pseudo, { x: M, y: 5.3, w: 9.65, h: 0.7, fontFace: F, fontSize: 11, color: C.text, fill: { color: C.accent2 }, margin: 0.1, valign: 'middle' });
    slide.addText(s.legal, { x: M, y: 6.08, w: 9.65, h: 0.7, fontFace: F, fontSize: 11, color: C.white, fill: { color: C.navy }, margin: 0.1, valign: 'middle' });
    shot(slide, `${lang}_st_privacy.png`, 10.75, 1.6, 4.65, s.cap, phone);
    tag(slide, 'impl', W - M - 2.3, 0.08);
  }

  // 9 Standards
  {
    const s = S.standards; const slide = pptx.addSlide(); base(slide, s);
    slide.addShape('rect', { x: M, y: 1.65, w: 5.6, h: 3.75, fill: { color: C.navy }, line: { type: 'none' } });
    slide.addText(s.place, { x: M + 0.3, y: 1.8, w: 5.0, h: 0.45, fontFace: F, fontSize: 14, bold: true, color: 'E8C48F', margin: 0 });
    s.formats.forEach(([k, v], i) => {
      const y = 2.4 + i * 0.72;
      slide.addText(k, { x: M + 0.3, y, w: 1.25, h: 0.52, fontFace: 'Noto Sans', fontSize: 12, bold: true, color: C.navy, fill: { color: 'A9D3BE' }, align: 'center', valign: 'middle', margin: 0 });
      slide.addText(v, { x: M + 1.7, y, w: 3.75, h: 0.52, fontFace: 'Noto Sans Mono', fontSize: k === 'UTM 38N' ? 10.5 : 12.5, color: C.white, margin: 0, valign: 'middle' });
    });
    s.rows.forEach(([k, v], i) => {
      const y = 1.65 + i * 0.95;
      slide.addShape('rect', { x: 6.45, y, w: W - M - 6.45, h: 0.85, fill: { color: C.card }, line: { color: C.line, width: 0.75 } });
      slide.addText(k, { x: 6.6, y, w: 1.95, h: 0.85, fontFace: F, fontSize: 11.5, bold: true, color: C.green, margin: 0, valign: 'middle' });
      slide.addText(v, { x: 8.6, y, w: W - M - 8.75, h: 0.85, fontFace: F, fontSize: 11, color: C.text, margin: 0, valign: 'middle' });
    });
    slide.addText(s.caveat, { x: M, y: 5.65, w: W - 2 * M, h: 0.65, fontFace: F, fontSize: 12, italic: true, color: C.text, fill: { color: C.accent2 }, margin: 0.12, valign: 'middle' });
    tag(slide, 'impl', W - M - 2.3, 0.08);
  }

  // 10 Platforms
  {
    const s = S.platforms; const slide = pptx.addSlide(); base(slide, s);
    const pw = 2.85;
    s.plats.forEach(([t, d], i) => {
      const x = M + i * (pw + 0.2);
      slide.addShape('rect', { x, y: 1.65, w: pw, h: 1.25, fill: { color: i === 0 ? C.navy : C.card }, line: { color: i === 0 ? C.navy : C.line, width: 1 } });
      slide.addText(t, { x: x + 0.2, y: 1.75, w: pw - 0.4, h: 0.5, fontFace: HF, fontSize: 17, bold: true, color: i === 0 ? C.white : C.navy, margin: 0, valign: 'middle' });
      slide.addText(d, { x: x + 0.2, y: 2.25, w: pw - 0.4, h: 0.55, fontFace: F, fontSize: 11, color: i === 0 ? 'DCE6EF' : C.mute, margin: 0, valign: 'top' });
    });
    slide.addText(s.why.map((t, i) => ({ text: t, options: { bullet: { code: '25B8' }, breakLine: i < s.why.length - 1 } })), { x: M, y: 3.25, w: 5.6, h: 2.2, fontFace: F, fontSize: 14, color: C.text, margin: 0, valign: 'top', paraSpaceAfter: 6 });
    tag(slide, 'rationale', M, 5.55);
    slide.addShape('rect', { x: 6.45, y: 3.2, w: W - M - 6.45, h: 3.45, fill: { color: C.green2 }, line: { type: 'none' } });
    slide.addText(s.connTitle, { x: 6.7, y: 3.3, w: 5.5, h: 0.45, fontFace: HF, fontSize: 14, bold: true, color: C.navy, margin: 0, valign: 'middle' });
    s.conn.forEach((t, i) => {
      const y = 3.9 + i * 0.85;
      slide.addText(i < 2 ? '✓' : '!', { x: 6.7, y, w: 0.4, h: 0.4, fontFace: 'DejaVu Sans', fontSize: 14, bold: true, color: C.white, fill: { color: i < 2 ? C.green : C.accent }, shape: 'ellipse', align: 'center', valign: 'middle', margin: 0 });
      slide.addText(t, { x: 7.25, y: y - 0.12, w: W - M - 7.45, h: 0.7, fontFace: F, fontSize: 12, color: C.text, margin: 0, valign: 'middle' });
    });
    tag(slide, 'impl', W - M - 2.3, 0.08);
  }

  // 11 Innovation
  {
    const s = S.innovation; const slide = pptx.addSlide(); base(slide, s);
    const gap = 0.12, cw = (W - 2 * M - 5 * gap) / 6, y = 1.6;
    s.cards.forEach(([t, d, img], i) => {
      const x = M + i * (cw + gap);
      slide.addShape('rect', { x, y, w: cw, h: 4.2, fill: { color: C.card }, line: { color: C.line, width: 1 } });
      const imgFile = img === 'detective' ? (lang === 'ka' ? 'ka_phone_detective.png' : null) : img ? `${lang}_st_${img}.png` : null;
      if (imgFile) {
        const ih = 2.3, ratio = img === 'detective' ? 1368 / 2432 : phone, iw = ih * ratio;
        slide.addImage({ path: A('screens/' + imgFile), x: x + (cw - iw) / 2, y: y + 0.1, w: iw, h: ih });
      } else {
        slide.addShape('rect', { x: x + 0.12, y: y + 0.1, w: cw - 0.24, h: 2.3, fill: { color: 'EFE8DA' }, line: { type: 'none' } });
        slide.addText(img === 'detective' ? 'DD → DMS → UTM' : i === 1 ? '•  ⟋  ⬠' : '◩ → ⌖', { x: x + 0.12, y: y + 0.1, w: cw - 0.24, h: 2.3, fontFace: 'DejaVu Sans', fontSize: 22, color: C.green, align: 'center', valign: 'middle', margin: 0 });
        slide.addText(L.illus, { x: x + 0.12, y: y + 2.05, w: cw - 0.24, h: 0.3, fontFace: F, fontSize: 8.5, italic: true, color: C.mute, align: 'center', margin: 0 });
      }
      slide.addText(t, { x: x + 0.1, y: y + 2.5, w: cw - 0.2, h: 0.55, fontFace: HF, fontSize: lang === 'ka' ? 11.5 : 12.5, bold: true, color: C.navy, margin: 0, valign: 'top' });
      slide.addText(d, { x: x + 0.1, y: y + 3.08, w: cw - 0.2, h: 1.05, fontFace: F, fontSize: 9.5, color: C.text, margin: 0, valign: 'top' });
    });
    s.ped.forEach((t, i) => {
      const pw = (W - 2 * M - 4 * 0.12) / 5;
      slide.addText(t, { x: M + i * (pw + 0.12), y: 5.95, w: pw, h: 0.42, fontFace: F, fontSize: 10.5, bold: true, color: C.white, fill: { color: [C.navy, C.green, C.accent, C.navy2, C.green][i] }, align: 'center', valign: 'middle', margin: 0 });
    });
    slide.addText(s.caveat, { x: M, y: 6.45, w: W - 2 * M, h: 0.38, fontFace: F, fontSize: 11, italic: true, color: C.accent, margin: 0, valign: 'middle' });
    tag(slide, 'impl', W - M - 2.3, 0.08);
  }

  // 12 Limits
  {
    const s = S.limits; const slide = pptx.addSlide(); base(slide, s);
    const colw = (W - 2 * M - 0.4) / 2;
    [[s.limTitle, s.lims, C.accent, 'rationale'], [s.resTitle, s.res, C.navy, 'plan']].forEach(([h, items, color, tg], c) => {
      const x = M + c * (colw + 0.4);
      slide.addShape('rect', { x, y: 1.65, w: colw, h: 0.55, fill: { color }, line: { type: 'none' } });
      slide.addText(h, { x: x + 0.2, y: 1.65, w: colw - 2.7, h: 0.55, fontFace: HF, fontSize: 16, bold: true, color: C.white, margin: 0, valign: 'middle' });
      if (tg === 'plan') tag(slide, 'plan', x + colw - 2.45, 1.78);
      items.forEach((t, i) => {
        const y = 2.35 + i * 0.6;
        slide.addShape('rect', { x, y, w: colw, h: 0.52, fill: { color: C.card }, line: { color: C.line, width: 0.75 } });
        slide.addText(c === 0 ? '–' : String(i + 1), { x: x + 0.1, y: y + 0.08, w: 0.36, h: 0.36, fontFace: 'Noto Sans', fontSize: 11, bold: true, color: C.white, fill: { color }, shape: 'ellipse', align: 'center', valign: 'middle', margin: 0 });
        slide.addText(t, { x: x + 0.6, y, w: colw - 0.75, h: 0.52, fontFace: F, fontSize: 12, color: C.text, margin: 0, valign: 'middle' });
      });
    });
  }

  // 13 Conclusion
  {
    const s = S.conclusion; const slide = pptx.addSlide(); base(slide, s, { plain: true });
    const bw = (W - 2 * M - 2 * 0.25) / 3;
    s.words.forEach((t, i) => {
      const x = M + (i % 3) * (bw + 0.25), y = 1.75 + Math.floor(i / 3) * 1.2;
      slide.addShape('rect', { x, y, w: bw, h: 1.0, fill: { color: i % 2 ? C.green2 : C.card }, line: { color: C.line, width: 1 } });
      slide.addShape('rect', { x, y, w: 0.08, h: 1.0, fill: { color: [C.navy, C.green, C.accent][i % 3] }, line: { type: 'none' } });
      slide.addText(t, { x: x + 0.3, y, w: bw - 0.45, h: 1.0, fontFace: HF, fontSize: lang === 'ka' ? 15 : 18, bold: true, color: C.navy, margin: 0, valign: 'middle' });
    });
    slide.addShape('rect', { x: M, y: 4.55, w: W - 2 * M, h: 1.9, fill: { color: C.navy }, line: { type: 'none' } });
    slide.addText(s.closing, { x: M + 0.5, y: 4.55, w: W - 2 * M - 1.0, h: 1.9, fontFace: HF, fontSize: lang === 'ka' ? 21 : 24, italic: true, color: C.white, align: 'center', valign: 'middle', margin: 0 });
  }

  // 14 References
  {
    const s = S.refs; const slide = pptx.addSlide(); base(slide, s, { plain: true });
    slide.addText(s.refs.map((t, i) => ({ text: t, options: { breakLine: i < s.refs.length - 1, indentLevel: 0 } })), { x: M, y: 1.15, w: W - 2 * M, h: 5.7, fontFace: 'Noto Sans', fontSize: 10, color: C.text, margin: 0, valign: 'top', paraSpaceAfter: 5 });
  }

  // 15 Questions
  {
    const s = S.questions; const slide = pptx.addSlide(); n += 1;
    slide.background = { path: A('generated/bg_title.png') };
    slide.addText(s.title, { x: M, y: 1.0, w: 8, h: 1.0, fontFace: HF, fontSize: lang === 'ka' ? 36 : 40, bold: true, color: C.white, margin: 0 });
    slide.addText(s.lead, { x: M, y: 2.05, w: 8, h: 0.5, fontFace: F, fontSize: 18, color: 'E8C48F', margin: 0 });
    slide.addText(s.q.map((t, i) => ({ text: t, options: { bullet: { code: '25B8' }, breakLine: i < s.q.length - 1 } })), { x: M, y: 3.0, w: 7.6, h: 2.0, fontFace: F, fontSize: 17, color: 'DCE6EF', margin: 0, valign: 'top', paraSpaceAfter: 10 });
    slide.addText(L.speaker, { x: M, y: 6.3, w: 8, h: 0.4, fontFace: F, fontSize: 14, bold: true, color: C.white, margin: 0 });
    [['generated/qr_repo.png', s.qr1, 'github.com/GIS-GEORGIA/geoclass'], ['generated/qr_doi.png', s.qr2, '10.5281/zenodo.24144115']].forEach(([img, cap, sub], i) => {
      const x = 8.9 + i * 2.1;
      slide.addShape('rect', { x: x - 0.08, y: 2.92, w: 1.86, h: 1.86, fill: { color: C.white }, line: { type: 'none' } });
      slide.addImage({ path: A(img), x, y: 3.0, w: 1.7, h: 1.7 });
      slide.addText(cap, { x: x - 0.2, y: 4.9, w: 2.1, h: 0.3, fontFace: F, fontSize: 12, bold: true, color: C.white, align: 'center', margin: 0 });
      slide.addText(sub, { x: x - 0.2, y: 5.2, w: 2.1, h: 0.45, fontFace: 'Noto Sans', fontSize: 8.5, color: 'A9C3DA', align: 'center', margin: 0, valign: 'top' });
    });
    slide.addText(`${n}/${total}`, { x: W - M - 0.55, y: 7.0, w: 0.55, h: 0.3, fontFace: 'Noto Sans', fontSize: 9, color: 'A9C3DA', align: 'right', margin: 0 });
    slide.addNotes(s.notes);
  }
  return pptx;
}

// Markdown companions
function md(lang) {
  const L = T[lang];
  const out = [`# ${L.title}`, '', `${L.subtitle}`, '', `${L.confLine}`, '', `${L.speaker}`, ''];
  const notes = [`# ${lang === 'ka' ? 'მომხსენებლის შენიშვნები' : 'Speaker notes'}: ${L.title}`, ''];
  let words = 0;
  L.s.forEach((s, i) => {
    const title = s.title ?? L.title;
    notes.push(`## ${i + 1}. ${title}`, '', s.notes.trim(), '');
    words += s.notes.split(/\s+/).length;
    if (s.key === 'title') return;
    out.push(`## ${i + 1}. ${title}`, '');
    if (s.lead) out.push(`*${s.lead}*`, '');
    const push = (arr, f) => arr && arr.forEach((x) => out.push('- ' + f(x)));
    push(s.tiles, ([h, b]) => `**${h}:** ${b}`);
    push(s.steps, ([h, a, g]) => `**${h}** (${a}): ${g}`);
    push(s.flow, (x) => x);
    if (s.key === 'games') GAMES.forEach((g, j) => { const G = L.games[g]; out.push(`- **${j + 1}. ${G.n}** — ${G.a} · ${G.s} · ${G.r} · ${G.u}`); });
    if (s.key === 'matrix') {
      out.push(`| | ${GAMES.map((g) => s.short[g]).join(' | ')} |`, `|---|${GAMES.map(() => '---').join('|')}|`);
      Object.keys(MATRIX).forEach((k) => out.push(`| ${s.skills[k]} | ${MATRIX[k].map((v) => (v === 2 ? '●' : v === 1 ? '○' : '')).join(' | ')} |`));
      out.push('', s.cycle.join(' → '), '', s.example, '', `_${s.caveat}_`);
    }
    push(s.roles, (x) => x);
    if (s.lesson) { out.push('', `**${s.lessonTitle}**`); push(s.lesson, ([t, d]) => `${t}: ${d}`); }
    push(s.measures, (x) => x);
    if (s.principles) out.push('', s.principles.join(' · '), '', s.pseudo, '', s.legal);
    if (s.formats) { out.push(`**${s.place}**`); push(s.formats, ([k, v]) => `${k}: ${v}`); push(s.rows, ([k, v]) => `**${k}:** ${v}`); }
    push(s.plats, ([k, v]) => `**${k}:** ${v}`);
    push(s.why, (x) => x);
    if (s.conn) { out.push('', `**${s.connTitle}**`); push(s.conn, (x) => x); }
    push(s.cards, ([k, v]) => `**${k}:** ${v}`);
    if (s.ped) out.push('', s.ped.join(' · '));
    if (s.lims) { out.push(`**${s.limTitle}**`); push(s.lims, (x) => x); out.push('', `**${s.resTitle}**`); push(s.res, (x) => x); }
    push(s.words, (x) => x);
    if (s.closing) out.push('', `> ${s.closing}`);
    push(s.refs, (x) => x);
    push(s.q, (x) => x);
    for (const k of ['tech', 'note', 'foot', 'more', 'caveat']) if (s[k] && !(s.key === 'matrix' && k === 'caveat')) out.push('', s[k]);
    if (s.cite) out.push('', `<sub>${s.cite}</sub>`);
    out.push('');
  });
  notes.push('---', '', lang === 'ka' ? `სულ ${words} სიტყვა, დაახლოებით ${Math.round(words / 100)} წუთი (100 სიტყვა წუთში).` : `${words} words in total, about ${Math.round(words / 135)} minutes at 135 words per minute.`, '');
  return { content: out.join('\n'), notes: notes.join('\n'), words };
}

for (const lang of ['ka', 'en']) {
  const up = lang.toUpperCase();
  // pptxgenjs writes an <a:pPr> before every run of a paragraph; OOXML allows one, as the first child.
  // Keep the first and drop the rest, so PowerPoint opens the file without a repair prompt.
  const JSZip = require('jszip');
  const zip = await JSZip.loadAsync(await build(lang).write({ outputType: 'nodebuffer' }));
  for (const name of Object.keys(zip.files).filter((f) => /^ppt\/slides\/slide\d+\.xml$/.test(f))) {
    const xml = await zip.file(name).async('string');
    const fixed = xml.replace(/<a:p>([\s\S]*?)<\/a:p>/g, (whole, inner) => {
      let first = true;
      return '<a:p>' + inner.replace(/<a:pPr\b[^>]*?(?:\/>|>[\s\S]*?<\/a:pPr>)/g, (m) => (first ? ((first = false), m) : '')) + '</a:p>';
    });
    zip.file(name, fixed);
  }
  fs.writeFileSync(path.join(OUT, `GeoClass_Conference_${up}.pptx`), await zip.generateAsync({ type: 'nodebuffer', compression: 'DEFLATE' }));
  const m = md(lang);
  fs.writeFileSync(path.join(OUT, `slide_content_${up}.md`), m.content);
  fs.writeFileSync(path.join(OUT, `speaker_notes_${up}.md`), m.notes);
  console.log(lang, 'notes words:', m.words);
}
