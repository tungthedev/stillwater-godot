// Walk check for the Web build in GPU Chrome: loads ?pose=walk&noui, shoots frames while the camera
// walks the trail, and counts sky-coloured pixels in the bottom third of each frame. That band is
// the ground a few metres ahead of the walker, so sky there means the terrain draw lost its nodes
// (the stale instance data systems/swap_multimesh.gd works around). Exits 1 when any frame is over
// the limit.
//   BASE=http://127.0.0.1:<port>/ gpu-run node tools/walk_check.mjs [--stillwater <path>] [--out captures/walk_check]
//     [--at 2,3,...,45]  seconds after start-up to shoot (every second by default: the dropout
//                        flickers second to second)   [--max 0.02]  allowed sky share
//     [--build slice5-3]  fail unless the page reports this build id
//     [--variants ,nograss] comma list of extra URL flags, one page load each ('' = as shipped)
//     [--view desk|phone]
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const argVal = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const SW = path.resolve(argVal('--stillwater', '/home/hoalong/Projects/stillwater'));
const OUT = path.resolve(argVal('--out', 'captures/walk_check'));
const AT = argVal('--at', Array.from({ length: 44 }, (_, i) => i + 2).join(',')).split(',').map(Number);
const BUILD = argVal('--build', '');
const MAX = Number(argVal('--max', '0.02'));
const VARIANTS = argVal('--variants', '').split(',');
const VIEWS = {
  desk: { width: 675, height: 1130, deviceScaleFactor: 1 },
  phone: { width: 390, height: 844, deviceScaleFactor: 3, isMobile: true, hasTouch: true },
};
const VIEW = VIEWS[argVal('--view', 'desk')];
const BASE = (process.env.BASE || '').replace(/\/?$/, '/');
if (!process.env.BASE) throw new Error('set BASE to the server for build/web');

const { launchBrowser } = await import(pathToFileURL(path.join(SW, 'tools/chrome.mjs')).href);
const { browser, renderer } = await launchBrowser(['--disable-gpu-vsync', '--disable-frame-rate-limit']);
console.log('renderer', renderer);
fs.mkdirSync(OUT, { recursive: true });

// Sky and the far haze are bright, low-saturation, blue-leaning; grass, dirt, rock and forest floor
// are not. The scene's lake can be blue, but never this close to the walker on the trail.
async function skyShare(page, b64) {
  return page.evaluate(async (src) => {
    const img = new Image();
    img.src = 'data:image/png;base64,' + src;
    await img.decode();
    const c = document.createElement('canvas');
    c.width = img.width; c.height = img.height;
    const g = c.getContext('2d');
    g.drawImage(img, 0, 0);
    const y0 = Math.floor(img.height * 2 / 3);
    const d = g.getImageData(0, y0, img.width, img.height - y0).data;
    let sky = 0;
    for (let i = 0; i < d.length; i += 4) {
      const r = d[i], gg = d[i + 1], b = d[i + 2];
      if (b >= 150 && b > r + 8 && b >= gg && Math.min(r, gg) >= 110) sky++;
    }
    return sky / (d.length / 4);
  }, b64);
}

let failed = false;
const results = { renderer, view: VIEW, max: MAX, runs: {} };
try {
  for (const variant of VARIANTS) {
    const tag = variant || 'shipped';
    const page = await browser.newPage();
    const logs = [];
    page.on('console', (m) => logs.push(m.text()));
    page.on('pageerror', (e) => logs.push('PAGEERROR ' + e.message));
    await page.setViewport(VIEW);
    await page.goto(`${BASE}index.html?pose=walk&noui${variant ? '&' + variant : ''}`, { waitUntil: 'load', timeout: 180000 });
    const t0 = Date.now();
    while (!logs.some((l) => l.startsWith('BUILD'))) {
      if (Date.now() - t0 > 120000) throw new Error('no BUILD line: ' + logs.join(' | '));
      await new Promise((r) => setTimeout(r, 200));
    }
    const build = logs.find((l) => l.startsWith('BUILD'));
    if (BUILD && !build.startsWith(`BUILD ${BUILD} `)) throw new Error(`stale build: ${build}`);
    const tUp = Date.now();
    const frames = [];
    for (const at of AT) {
      const wait = tUp + at * 1000 - Date.now();
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
      const b64 = await page.screenshot({ encoding: 'base64' });
      const share = await skyShare(page, b64);
      const shot = path.join(OUT, `walk_${tag}_${at}s.png`);
      fs.writeFileSync(shot, Buffer.from(b64, 'base64'));
      frames.push({ at, sky: +share.toFixed(4), shot });
      const bad = share > MAX;
      failed ||= bad;
      console.log(`${tag} ${String(at).padStart(3)} s  sky below horizon ${(share * 100).toFixed(1).padStart(5)} %${bad ? '  FAIL' : ''}`);
    }
    const errors = logs.filter((l) => /ERROR|SCRIPT|SHADER|PAGEERROR/.test(l));
    for (const e of errors) console.log('  !', e);
    results.runs[tag] = { build, frames, errors };
    await page.close();
  }
} finally {
  await browser.close();
}
fs.writeFileSync(path.join(OUT, 'walk_check.json'), JSON.stringify(results, null, 1) + '\n');
console.log(failed ? `FAIL: sky share above ${MAX} in some frame` : 'PASS');
process.exit(failed ? 1 : 0);
