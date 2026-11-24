// Phone-view screenshots of a probe page or a game URL in GPU Chrome (390 x 844, dpr 3).
//   BASE=http://127.0.0.1:<port>/ [GL_PROFILE=iphone] gpu-run node tools/probe_shot.mjs --out captures/s1-3 \
//     --shot "probe_terrain=?probe=terrain" --shot "repro=?pose=walk&dbg_terrain=1024"
// A `?probe=` page is shot when window.__probe appears (its verdict is printed and saved as JSON);
// any other URL is shot 8 s after the BUILD line. Exits 1 when a probe did not pass.
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const argVal = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const SW = path.resolve(argVal('--stillwater', '/home/hoalong/Projects/stillwater'));
const OUT = path.resolve(argVal('--out', 'captures/probe'));
const SHOTS = args.flatMap((a, i) => (a === '--shot' ? [args[i + 1]] : []));
const BASE = (process.env.BASE || '').replace(/\/?$/, '/');
if (!process.env.BASE) throw new Error('set BASE to the server for build/web');
const SUFFIX = process.env.GL_PROFILE ? `_${process.env.GL_PROFILE}` : '';

const { launchBrowser } = await import(pathToFileURL(path.join(SW, 'tools/chrome.mjs')).href);
const { browser, renderer } = await launchBrowser([]);
console.log('renderer', renderer);
fs.mkdirSync(OUT, { recursive: true });
let failed = 0;
try {
  for (const spec of SHOTS) {
    const eq = spec.indexOf('=');
    const name = spec.slice(0, eq) + SUFFIX;
    const query = spec.slice(eq + 1);
    const page = await browser.newPage();
    const logs = [];
    page.on('console', (m) => logs.push(m.text()));
    page.on('pageerror', (e) => logs.push('PAGEERROR ' + e.message));
    await page.setViewport({ width: 390, height: 844, deviceScaleFactor: 3, isMobile: true, hasTouch: true });
    await page.goto(`${BASE}index.html${query}`, { waitUntil: 'load', timeout: 180000 });
    const t0 = Date.now();
    while (!logs.some((l) => l.startsWith('BUILD'))) {
      if (Date.now() - t0 > 120000) throw new Error('no BUILD line: ' + logs.join(' | '));
      await new Promise((r) => setTimeout(r, 200));
    }
    if (/[?&]probe=/.test(query)) {
      await page.waitForFunction('window.__probe', { timeout: 120000 });
      await new Promise((r) => setTimeout(r, 500));
      const probe = await page.evaluate('window.__probe');
      fs.writeFileSync(path.join(OUT, `${name}.json`), JSON.stringify(probe, null, 1) + '\n');
      console.log(`${name}: ${probe.pass ? 'PASS' : 'FAIL'} gpu=${probe.gpu}`);
      for (const r of probe.rows || []) console.log(`  ${r.verdict.padEnd(5)} ${r.name}  rgb=${r.ground}  black=${r.black_ground}/${r.black_frame}`);
      if (!probe.pass) failed++;
    } else {
      await new Promise((r) => setTimeout(r, 8000));
    }
    await page.screenshot({ path: path.join(OUT, `${name}.png`) });
    const bad = logs.filter((l) => /PAGEERROR|SCRIPT ERROR|SHADER ERROR/.test(l));
    for (const l of bad) console.log('  ', l);
    if (bad.length) failed++;
    console.log(logs.find((l) => l.startsWith('BUILD')));
    await page.close();
  }
} finally {
  await browser.close();
}
process.exit(failed ? 1 : 0);
