// Measures the Web build in GPU Chrome: per pose, one page load at 675 x 1130 (device scale 1,
// the iPhone's low-tier internal size), frame cap off, a screenshot after warmup and the BENCH
// line the game writes to window.__bench after its 20 s window. Uses Stillwater's Chrome
// launcher, which refuses software rendering. Run under gpu-run:
//   BASE=http://127.0.0.1:<port>/ gpu-run node tools/measure_web.mjs [--stillwater <path>] [--out captures/slice2] [--ui]
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const argVal = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const SW = path.resolve(argVal('--stillwater', '/home/hoalong/Projects/stillwater'));
const OUT = path.resolve(argVal('--out', 'captures/slice2'));
const UI = args.includes('--ui');
const BASE = (process.env.BASE || '').replace(/\/?$/, '/');
if (!process.env.BASE) throw new Error('set BASE to the server for build/web');
const W = 675, H = 1130;

const { launchBrowser } = await import(pathToFileURL(path.join(SW, 'tools/chrome.mjs')).href);
const { browser, renderer } = await launchBrowser(['--disable-gpu-vsync', '--disable-frame-rate-limit']);
console.log('renderer', renderer);
fs.mkdirSync(OUT, { recursive: true });
const results = { renderer, ui: UI, size: [W, H], poses: {} };
try {
  for (const pose of ['trailhead', 'forest']) {
    const page = await browser.newPage();
    const logs = [];
    page.on('console', (m) => logs.push(m.text()));
    page.on('pageerror', (e) => logs.push('PAGEERROR ' + e.message));
    await page.setViewport({ width: W, height: H, deviceScaleFactor: 1 });
    await page.goto(`${BASE}index.html?pose=${pose}${UI ? '' : '&noui'}`, { waitUntil: 'load', timeout: 180000 });
    // The scene prints BUILD when it is up; the BENCH window runs 3-23 s after that. Shoot inside it.
    const t0 = Date.now();
    while (!logs.some((l) => l.startsWith('BUILD'))) {
      if (Date.now() - t0 > 120000) throw new Error('no BUILD line: ' + logs.join(' | '));
      await new Promise((r) => setTimeout(r, 200));
    }
    await new Promise((r) => setTimeout(r, 6000));
    const shot = path.join(OUT, `godot_web_${pose}${UI ? '_ui' : ''}.png`);
    await page.screenshot({ path: shot });
    await page.waitForFunction('window.__bench', { timeout: 120000 });
    const line = await page.evaluate('window.__bench');
    results.poses[pose] = { bench: line, shot, log: logs.filter((l) => /BUILD|ERROR|rror|SCRIPT|SHADER/.test(l)) };
    console.log(pose, line);
    for (const l of results.poses[pose].log) console.log('  ', l);
    await page.close();
  }
} finally {
  await browser.close();
}
fs.writeFileSync(path.join(OUT, `measure_web${UI ? '_ui' : ''}.json`), JSON.stringify(results, null, 1) + '\n');
