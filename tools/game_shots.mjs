// Screenshots of the game at the same moments in Stillwater and in this Godot port, driven by
// real input (CDP touch events on phone views, mouse and keys on desktop):
//   title    4.5 s after the page is ready
//   card     6 s after the start tap / click (the Trailhead place card; the spawn is inside it)
//   walk     after 6 s walking forward (stick up on touch, W on desktop) and a look to the right
//   paused   after the pause button (touch) or Esc (desktop)
// Run under gpu-run against your own servers:
//   GODOT=http://127.0.0.1:<port>/ STILLWATER=http://127.0.0.1:<port>/ gpu-run node tools/game_shots.mjs
//     [--out captures/w1/shots] [--views phone,land,desk] [--only godot|stillwater]
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const argVal = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const SW = path.resolve(argVal('--stillwater', '/home/hoalong/Projects/stillwater'));
const OUT = path.resolve(argVal('--out', 'captures/w1/shots'));
const VIEWS_ALL = {
  phone: { width: 390, height: 844, deviceScaleFactor: 3, isMobile: true, hasTouch: true },
  land: { width: 844, height: 390, deviceScaleFactor: 3, isMobile: true, hasTouch: true, isLandscape: true },
  desk: { width: 1440, height: 900, deviceScaleFactor: 1 },
};
const VIEWS = argVal('--views', 'phone,land,desk').split(',');
const ONLY = argVal('--only', '');
const TARGETS = [
  { name: 'godot', base: process.env.GODOT, url: 'index.html', ready: (logs) => logs.some((l) => l.startsWith('BUILD')) },
  { name: 'stillwater', base: process.env.STILLWATER, url: '?q=low', ready: null },
].filter((t) => t.base && (!ONLY || ONLY === t.name));
const PHONE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.7 Mobile/15E148 Safari/604.1';

const { launchBrowser } = await import(pathToFileURL(path.join(SW, 'tools/chrome.mjs')).href);
const { browser, renderer } = await launchBrowser([]);
console.log('renderer', renderer);
fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

try {
  for (const target of TARGETS) {
    for (const v of VIEWS) {
      const view = VIEWS_ALL[v];
      const page = await browser.newPage();
      const logs = [];
      page.on('console', (m) => logs.push(m.text()));
      page.on('pageerror', (e) => logs.push('PAGEERROR ' + e.message));
      if (view.hasTouch) await page.setUserAgent(PHONE_UA);
      await page.setViewport(view);
      await page.goto(target.base + target.url, { waitUntil: 'load', timeout: 180000 });
      const t0 = Date.now();
      for (;;) {
        const ok = target.ready ? target.ready(logs) : await page.evaluate(() => !!window.__game);
        if (ok) break;
        if (Date.now() - t0 > 150000) throw new Error(`${target.name} ${v}: not ready: ${logs.slice(-5).join(' | ')}`);
        await sleep(200);
      }
      const shot = async (tag) => {
        const f = path.join(OUT, `${target.name}_${v}_${tag}.png`);
        await page.screenshot({ path: f });
        console.log(f);
      };
      const cdp = await page.target().createCDPSession();
      const touch = (type, pts) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: pts.map(([id, x, y]) => ({ id, x, y, radiusX: 2, radiusY: 2, force: 1 })) });
      const tap = async (x, y) => { await touch('touchStart', [[1, x, y]]); await sleep(60); await touch('touchEnd', []); };
      const W = view.width, H = view.height;
      await sleep(4500);
      await shot('title');
      if (view.hasTouch) await tap(W / 2, H / 2);
      else await page.mouse.click(W / 2, H / 2);
      await sleep(6000);
      await shot('card');
      if (view.hasTouch) {
        // Left thumb down and up the screen (walk forward), right thumb drags the view right.
        const sx = W * 0.25, sy = H * 0.7;
        await touch('touchStart', [[1, sx, sy]]);
        for (let i = 1; i <= 8; i++) { await touch('touchMove', [[1, sx, sy - i * 6]]); await sleep(16); }
        await touch('touchStart', [[1, sx, sy - 48], [2, W * 0.75, H * 0.5]]);
        for (let i = 1; i <= 10; i++) { await touch('touchMove', [[1, sx, sy - 48], [2, W * 0.75 + i * 4, H * 0.5]]); await sleep(16); }
        await touch('touchEnd', [[1, sx, sy - 48]]);
        await sleep(6000);
        await shot('walk');
        await touch('touchEnd', []);
        await sleep(500);
        // Pause button: top right, 44 x 44, 14 px from the edges (no safe area in Chrome).
        await tap(W - 14 - 22, 14 + 22);
      } else {
        await page.mouse.move(W / 2 + 60, H / 2);
        await page.keyboard.down('KeyW');
        await sleep(6000);
        await shot('walk');
        await page.keyboard.up('KeyW');
        await page.keyboard.press('Escape');
        await page.evaluate(() => document.exitPointerLock && document.exitPointerLock());
      }
      await sleep(1500);
      await shot('paused');
      const errors = logs.filter((l) => /ERROR|SCRIPT ERROR|SHADER|PAGEERROR/.test(l));
      for (const e of errors) console.log('  !', e);
      await page.close();
    }
  }
} finally {
  await browser.close();
}
