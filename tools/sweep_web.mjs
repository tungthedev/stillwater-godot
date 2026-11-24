// Runs the on-device interleaved GPU + CPU cost sweep (?bench=sweep) of the Web build in GPU Chrome
// at the phone view (390x844 @ dpr 3, touch) and saves the result panel screenshot + JSON.
// Uses Stillwater's Chrome launcher (refuses software rendering; uses gpu-run when installed).
//   BASE=http://127.0.0.1:<port>/ gpu-run node tools/sweep_web.mjs [--out captures/sweep]
//     [--build s1-sweep2] [--vsync] [--extra '&sweep_poses=trailhead'] [--tag phone]
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const argVal = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const SW = path.resolve(argVal('--stillwater', '/home/hoalong/Projects/stillwater'));
const OUT = path.resolve(argVal('--out', 'captures/sweep'));
const BUILD = argVal('--build', '');
const VSYNC = args.includes('--vsync');
const EXTRA = argVal('--extra', '');
const TAG = argVal('--tag', 'phone');
const BASE = (process.env.BASE || '').replace(/\/?$/, '/');
if (!process.env.BASE) throw new Error('set BASE to the server for build/web');

const PHONE = { width: 390, height: 844, deviceScaleFactor: 3, isMobile: true, hasTouch: true };

const { launchBrowser } = await import(pathToFileURL(path.join(SW, 'tools/chrome.mjs')).href);
const { browser, renderer } = await launchBrowser(VSYNC ? [] : ['--disable-gpu-vsync', '--disable-frame-rate-limit']);
console.log('renderer', renderer);
fs.mkdirSync(OUT, { recursive: true });
const { execSync } = await import('node:child_process');
const commit = execSync('git rev-parse --short HEAD').toString().trim()
  + (execSync('git status --porcelain -- systems shaders web main.gd').toString().trim() ? '+dirty' : '');

const fmtOpt = (v, w = 6) => (typeof v === 'number' && v >= 0 ? v.toFixed(1).padStart(w) : 'n/a'.padStart(w));

try {
  const page = await browser.newPage();
  const logs = [];
  page.on('console', (m) => logs.push(m.text()));
  page.on('pageerror', (e) => logs.push('PAGEERROR ' + e.message));
  await page.setViewport(PHONE);
  await page.goto(`${BASE}index.html?bench=sweep${EXTRA}`, { waitUntil: 'load', timeout: 180000 });
  const t0 = Date.now();
  while (!logs.some((l) => l.startsWith('BUILD'))) {
    if (Date.now() - t0 > 120000) throw new Error('no BUILD line: ' + logs.slice(-8).join(' | '));
    await new Promise((r) => setTimeout(r, 200));
  }
  const build = logs.find((l) => l.startsWith('BUILD'));
  console.log(build);
  if (BUILD && !build.startsWith(`BUILD ${BUILD} `)) throw new Error(`stale build: ${build}`);

  await page.waitForFunction('Boolean(window.__sweep)', { timeout: 600000, polling: 1000 });
  const sweep = await page.evaluate(() => window.__sweep);
  await new Promise((r) => setTimeout(r, 1000));
  const shot = path.join(OUT, `sweep_${TAG}.png`);
  await page.screenshot({ path: shot });

  const errors = logs.filter((l) => /ERROR|SCRIPT|SHADER|PAGEERROR/.test(l));
  const sweepLine = logs.find((l) => l.startsWith('SWEEP '));
  const notes = logs.filter((l) => l.startsWith('SWEEP_NOTE '));
  const out = { renderer, base: BASE, commit, vsync: VSYNC, extra: EXTRA, view: PHONE, build, has_sweep_line: Boolean(sweepLine), notes, sweep, shot, errors };
  fs.writeFileSync(path.join(OUT, `sweep_${TAG}.json`), JSON.stringify(out, null, 2) + '\n');

  const noteStr = (sweep.notes || []).length ? `  notes=[${sweep.notes.join(', ')}]` : '';
  console.log(`\nSWEEP ${sweep.build}  total=${sweep.total_s}s  internal=${sweep.internal.join('x')} of ${sweep.screen.join('x')}  post=${sweep.post}  target=${sweep.target}${noteStr}`);
  for (const p of sweep.poses) {
    console.log(`\n== ${p.pose}  base ${p.base_start_ms} -> ${p.base_end_ms} ms (drift ${p.drift_ms >= 0 ? '+' : ''}${p.drift_ms}, med ${p.base_median_ms}, cpu ${fmtOpt(p.base_raf_cpu_ms, 1)}, raf ${fmtOpt(p.base_raf_iv_ms, 1)}, scr ${p.base_script_ms}, perf_proc ${p.base_perf_proc_ms}, phys ${p.base_phys_ms}, draws=${p.base_draws}, tris=${p.base_tris})`);
    console.log('  variant          med_ms  base_ms  delta_ms  delta_%  raf_cpu  raf_iv    scr   phys   draws    tris  gpu_avg');
    for (const v of p.variants) {
      const dMs = `${v.delta_ms >= 0 ? '+' : ''}${v.delta_ms.toFixed(1)}`.padStart(7);
      const dPct = `${v.delta_pct >= 0 ? '+' : ''}${v.delta_pct.toFixed(1)}%`.padStart(7);
      console.log(`  ${v.label.padEnd(15)} ${v.median_ms.toFixed(1).padStart(7)}  ${v.base_ms.toFixed(1).padStart(7)}  ${dMs}  ${dPct}  ${fmtOpt(v.raf_cpu_ms, 7)}  ${fmtOpt(v.raf_iv_ms, 6)}  ${v.script_ms.toFixed(2).padStart(5)}  ${v.phys_ms.toFixed(2).padStart(5)}  ${String(v.draws).padStart(6)}  ${String(v.tris).padStart(7)}  ${fmtOpt(v.gpu_avg, 7)}`);
    }
  }
  if (errors.length) {
    console.log('\nERRORS:');
    for (const e of errors) console.log('  !', e);
    process.exitCode = 1;
  }
  await page.close();
} finally {
  await browser.close();
}
