// Runs the in-game bench (?bench) of the Web build in GPU Chrome, one page load per variant, and
// saves each result panel as a screenshot plus all BENCHRESULT records as JSON. Uses Stillwater's
// Chrome launcher (refuses software rendering; takes the machine-wide GPU lock when gpu-run is
// installed). Frame cap off. Serve build/web yourself (plain files, not the .gz set):
//   BASE=http://127.0.0.1:<port>/ gpu-run node tools/bench_web.mjs [--stillwater <path>] [--out captures/slice5]
//     [--build slice5-1]   fail unless the page reports this build id
//     [--only phone,desk]  run only these variants (names below)
//     [--vsync]            keep Chrome's vsync and frame limit (frames pace at the display rate, as
//                          on a phone); default is uncapped
//     [--extra '&nogputimer']  appended to every variant's URL
//     [--tag after]        output file bench_web_<tag>.json and shots bench_<tag>_<variant>.png
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const argVal = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const SW = path.resolve(argVal('--stillwater', '/home/hoalong/Projects/stillwater'));
const OUT = path.resolve(argVal('--out', 'captures/slice5'));
const BUILD = argVal('--build', '');
const ONLY = argVal('--only', '').split(',').filter(Boolean);
const VSYNC = args.includes('--vsync');
const EXTRA = argVal('--extra', '');
const TAG = argVal('--tag', '');
const BASE = (process.env.BASE || '').replace(/\/?$/, '/');
if (!process.env.BASE) throw new Error('set BASE to the server for build/web');

// iPhone-shaped (390 x 844 CSS at dpr 3 = 1170 x 2532 device pixels) and the slice 2-4 view.
const PHONE = { width: 390, height: 844, deviceScaleFactor: 3, isMobile: true, hasTouch: true };
const DESK = { width: 675, height: 1130, deviceScaleFactor: 1 };
const VARIANTS = [
  { name: 'phone', view: PHONE, query: '' },
  { name: 'phone_res50', view: PHONE, query: '&res=50' },
  { name: 'phone_nopost', view: PHONE, query: '&nopost' },
  { name: 'desk', view: DESK, query: '' },
  { name: 'desk_nopost', view: DESK, query: '&nopost' },
  { name: 'desk_res100', view: DESK, query: '&res=100' },
  { name: 'desk_res100_nopost', view: DESK, query: '&res=100&nopost' },
].filter((v) => !ONLY.length || ONLY.includes(v.name)).map((v) => ({ ...v, query: v.query + EXTRA }));

const { launchBrowser } = await import(pathToFileURL(path.join(SW, 'tools/chrome.mjs')).href);
const { browser, renderer } = await launchBrowser(VSYNC ? [] : ['--disable-gpu-vsync', '--disable-frame-rate-limit']);
console.log('renderer', renderer);
fs.mkdirSync(OUT, { recursive: true });
const { execSync } = await import('node:child_process');
const commit = execSync('git rev-parse --short HEAD').toString().trim() + (execSync('git status --porcelain -- systems main.gd').toString().trim() ? '+dirty' : '');
const results = { renderer, base: BASE, commit, vsync: VSYNC, extra: EXTRA, runs: {} };
try {
  for (const v of VARIANTS) {
    const page = await browser.newPage();
    const logs = [];
    page.on('console', (m) => logs.push(m.text()));
    page.on('pageerror', (e) => logs.push('PAGEERROR ' + e.message));
    await page.setViewport(v.view);
    await page.goto(`${BASE}index.html?bench${v.query}`, { waitUntil: 'load', timeout: 180000 });
    const t0 = Date.now();
    while (!logs.some((l) => l.startsWith('BUILD'))) {
      if (Date.now() - t0 > 120000) throw new Error('no BUILD line: ' + logs.join(' | '));
      await new Promise((r) => setTimeout(r, 200));
    }
    const build = logs.find((l) => l.startsWith('BUILD'));
    if (BUILD && !build.startsWith(`BUILD ${BUILD} `)) throw new Error(`stale build: ${build}`);
    await page.waitForFunction('window.__benchResult', { timeout: 300000, polling: 500 });
    const res = JSON.parse(await page.evaluate('window.__benchResult'));
    await new Promise((r) => setTimeout(r, 1000));
    const shot = path.join(OUT, `bench_${TAG ? TAG + '_' : ''}${v.name}.png`);
    await page.screenshot({ path: shot });
    const errors = logs.filter((l) => /ERROR|SCRIPT|SHADER|PAGEERROR/.test(l));
    results.runs[v.name] = { view: v.view, query: v.query, build, result: res, shot, errors };
    console.log(`${v.name}: ${res.internal.join('x')} of ${res.screen.join('x')} post=${res.post} target=${res.target}`);
    for (const s of res.stages) {
      console.log(`  ${s.stage.padEnd(9)} ${String(s.fps).padStart(6)} fps  p50 ${s.p50_ms} ms  p95 ${s.p95_ms} ms  ${(s.tris / 1e6).toFixed(2)} M tris  ${s.draws} draws`);
      console.log(`            frame ${s.frame_avg}/${s.frame_p95}  cpu ${s.cpu_avg}/${s.cpu_p95}  script ${s.script_avg}/${s.script_p95}  render ${s.render_avg}/${s.render_p95}  other ${s.other_avg}  gpu ${s.gpu_avg}/${s.gpu_p95}`);
      console.log(`            ${s.bound_note}`);
      console.log(`            ${Object.entries(s.sys_ms || {}).map(([k, x]) => `${k} ${x}`).join('  ')}`);
    }
    console.log(`  ${res.verdict}`);
    for (const e of errors) console.log('  !', e);
    await page.close();
  }
} finally {
  await browser.close();
}
fs.writeFileSync(path.join(OUT, `bench_web${TAG ? '_' + TAG : ''}.json`), JSON.stringify(results, null, 1) + '\n');
