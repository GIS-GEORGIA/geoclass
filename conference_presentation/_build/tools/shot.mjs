// Headless capture of the LOCAL dev server. Args: lang mode(phone|desk) target out w h dpr wait [steps]
import { chromium } from 'playwright-core';
import fs from 'fs';
const [,, lang, mode, target, out, w, h, dpr, wait, steps] = process.argv;
const exe = process.env.HOME + '/.cache/ms-playwright/chromium-1254/chrome-linux64/chrome';
const browser = await chromium.launch({ executablePath: exe, args: ['--use-gl=swiftshader','--enable-unsafe-swiftshader'] });
const ctx = await browser.newContext({ viewport: { width: +w, height: +h }, deviceScaleFactor: +dpr, colorScheme: 'light', isMobile: mode==='phone', hasTouch: mode==='phone' });
const tokens = JSON.parse(fs.readFileSync(process.env.TOK, 'utf8'));
await ctx.addInitScript(([lang, teacher, qr]) => {
  localStorage.setItem('flutter.lang', JSON.stringify(lang));
  localStorage.setItem('flutter.theme', JSON.stringify('light'));
  if (teacher) localStorage.setItem('flutter.teacher_key', JSON.stringify('local-check-key'));
  if (qr) localStorage.setItem('flutter.qr_tokens', JSON.stringify(JSON.stringify(qr)));
}, [lang, mode !== 'phone', JSON.parse(process.env.QR || '{}')]);
const page = await ctx.newPage();
const url = target.startsWith('join:') ? `http://localhost:8788/#/join/${tokens[target.slice(5)]}` : `http://localhost:8788/${target}`;
await page.goto(url);
await page.waitForTimeout(+wait);
for (const c of (steps || '').split(';').filter(Boolean)) {
  const [kind, a, b] = c.split(',');
  if (kind === 'xy') await page.mouse.click(+a, +b);
  else if (kind === 'wait') await page.waitForTimeout(+a);
  await page.waitForTimeout(400);
}
await page.screenshot({ path: out });
await browser.close();
