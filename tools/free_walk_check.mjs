// Free-walk check for the Web build in GPU Chrome: the game page (?walklog), started from the title
// with a real tap or click, then walked with real input along legs through meadow, forest, up a
// slope and into the valley edge (the near/far blend band). Fails when
//   - a leg covers less ground than it should (input did not reach the walker),
//   - the bottom third of any shot is sky-coloured (ground lost, as tools/walk_check.mjs tests),
//   - terrain, trees or grass spend more than 5 ms of script in 2 or more frames of a leg, or
//     more than 10 ms in one (a streaming hitch; one isolated frame just over 5 ms only warns;
//     a grass frame whose own named work is under 2 ms is a page pause, listed, not counted),
//   - the walker leaves the 1850 m boundary, or the page logs an error.
// The title orbit and the fade are not measured: systems/walk_log.gd records only in play.
//   BASE=http://127.0.0.1:<port>/ gpu-run node tools/free_walk_check.mjs [--out captures/w1/free_walk]
//     [--legs meadow_keys,forest_trail,slope_stick,edge_stick] [--build w1-1] [--secs-scale 1]
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const argVal = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const SW = path.resolve(argVal('--stillwater', '/home/hoalong/Projects/stillwater'));
const OUT = path.resolve(argVal('--out', 'captures/w1/free_walk'));
const BUILD = argVal('--build', '');
const SCALE = Number(argVal('--secs-scale', '1'));
const BASE = (process.env.BASE || '').replace(/\/?$/, '/');
if (!process.env.BASE) throw new Error('set BASE to the server for build/web');
const PHONE = { width: 390, height: 844, deviceScaleFactor: 3, isMobile: true, hasTouch: true };
// Keyboard at the phone's size: the hitch limit is for the phone-size view.
const PHONE_KEYS = { width: 390, height: 844, deviceScaleFactor: 3 };
const PHONE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.7 Mobile/15E148 Safari/604.1';
const HITCH_SYSTEMS = ['terrain', 'trees', 'grass'];
const MAX_SKY = 0.02;
// spawn = x,z,yaw (forward is (-sin yaw, -cos yaw)); minM = least ground covered.
const LEGS = {
  // Default spawn by the trailhead, Shift stride through the meadow.
  meadow_keys: { view: PHONE_KEYS, spawn: '', drive: 'keys', secs: 40, minM: 120 },
  // Trail point 1380, in the forest before the hero oaks, following the trail (Trail button).
  forest_trail: { view: PHONE, spawn: '-415.0,-385.4,1.59', drive: 'trail', secs: 50, minM: 80 },
  // A meadow slope west of the lake facing uphill (grade 0.3 to 0.6 over 110 m), stick forward.
  slope_stick: { view: PHONE, spawn: '240,280,3.9', drive: 'stick', secs: 50, minM: 35 },
  // 45 m inside the east edge, stick toward +x: into the blend band and against the boundary.
  edge_stick: { view: PHONE, spawn: '1805,0,-1.5708', drive: 'stick', secs: 40, minM: 50, edge: true },
};
const NAMES = argVal('--legs', Object.keys(LEGS).join(',')).split(',');

const { launchBrowser } = await import(pathToFileURL(path.join(SW, 'tools/chrome.mjs')).href);
const { browser, renderer } = await launchBrowser(['--disable-gpu-vsync', '--disable-frame-rate-limit']);
console.log('renderer', renderer);
fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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
const results = { renderer, base: BASE, legs: {} };
const fail = (leg, msg) => { failed = true; results.legs[leg].fails.push(msg); console.log(`  FAIL ${msg}`); };
try {
  for (const name of NAMES) {
    const leg = LEGS[name];
    results.legs[name] = { ...leg, view: leg.view === PHONE ? 'phone 390x844@3 touch' : 'phone-size 390x844@3 keyboard', fails: [], shots: [] };
    console.log(`== ${name}`);
    const page = await browser.newPage();
    const logs = [];
    page.on('console', (m) => logs.push(m.text()));
    page.on('pageerror', (e) => logs.push('PAGEERROR ' + e.message));
    if (leg.view.hasTouch) await page.setUserAgent(PHONE_UA);
    await page.setViewport(leg.view);
    await page.goto(`${BASE}index.html?walklog${leg.spawn ? '&spawn=' + leg.spawn : ''}`, { waitUntil: 'load', timeout: 180000 });
    const t0 = Date.now();
    while (!logs.some((l) => l.startsWith('BUILD'))) {
      if (Date.now() - t0 > 150000) throw new Error('no BUILD line: ' + logs.slice(-5).join(' | '));
      await sleep(200);
    }
    const build = logs.find((l) => l.startsWith('BUILD'));
    if (BUILD && !build.startsWith(`BUILD ${BUILD} `)) throw new Error(`stale build: ${build}`);
    const cdp = await page.target().createCDPSession();
    const touch = (type, pts) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: pts.map(([id, x, y]) => ({ id, x, y, radiusX: 2, radiusY: 2, force: 1 })) });
    const W = leg.view.width, H = leg.view.height;
    await sleep(1500);
    // Start from the title like a player.
    if (leg.view.hasTouch) { await touch('touchStart', [[1, W / 2, H / 2]]); await sleep(60); await touch('touchEnd', []); }
    else await page.mouse.click(W / 2, H / 2);
    const walk = () => page.evaluate(() => window.__walk || null);
    const tw = Date.now();
    while (!(await walk())) {
      if (Date.now() - tw > 30000) throw new Error('play never started');
      await sleep(100);
    }
    let w0 = await walk();
    if (leg.drive === 'keys') {
      await page.keyboard.down('ShiftLeft');
      await page.keyboard.down('KeyW');
    } else if (leg.drive === 'stick') {
      const sx = W * 0.25, sy = H * 0.72;
      await touch('touchStart', [[1, sx, sy]]);
      for (let i = 1; i <= 10; i++) { await touch('touchMove', [[1, sx, sy - i * 6]]); await sleep(16); }
    } else if (leg.drive === 'trail') {
      const r = w0.trail_btn;
      if (!r || !r.length) throw new Error('no Trail button on screen');
      await touch('touchStart', [[1, r[0] + r[2] / 2, r[1] + r[3] / 2]]); await sleep(80); await touch('touchEnd', []);
    }
    const tStart = Date.now();
    for (let k = 1; tStart + leg.secs * SCALE * 1000 > Date.now(); k++) {
      const wait = tStart + k * 4000 - Date.now();
      if (wait > 0) await sleep(wait);
      // The capture stalls the page; systems/walk_log.gd leaves frames in this window out.
      await page.evaluate(() => { window.__shooting = true; });
      const b64 = await page.screenshot({ encoding: 'base64' });
      await page.evaluate(() => { window.__shooting = false; window.__shotEnd = performance.now(); });
      const share = await skyShare(page, b64);
      const f = path.join(OUT, `${name}_${String(k * 4).padStart(2, '0')}s.png`);
      fs.writeFileSync(f, Buffer.from(b64, 'base64'));
      const w = await walk();
      results.legs[name].shots.push({ at: k * 4, sky: +share.toFixed(4), pos: w.pos, distance: w.distance, shot: path.relative(process.cwd(), f) });
      console.log(`  ${String(k * 4).padStart(3)} s  ${w.distance.toFixed(1).padStart(6)} m  pos ${w.pos.join(', ')}  sky ${(share * 100).toFixed(1)} %`);
      if (share > MAX_SKY) fail(name, `sky below the horizon ${(share * 100).toFixed(1)} % at ${k * 4} s`);
    }
    if (leg.drive === 'keys') { await page.keyboard.up('KeyW'); await page.keyboard.up('ShiftLeft'); }
    if (leg.drive === 'stick') await touch('touchEnd', []);
    const w = await walk();
    results.legs[name].walk = w;
    results.legs[name].build = build;
    const moved = w.distance - w0.distance;
    console.log(`  ${moved.toFixed(1)} m in ${w.seconds} s of play, ${w.fps} fps, worst frame ${w.max_frame_ms} ms\n  worst script ms ${JSON.stringify(w.worst_ms)}\n  avg script ms ${JSON.stringify(w.avg_ms)}\n  hitches ${JSON.stringify(w.hitches)}, ${w.shot_frames} frames in screenshot stalls and ${w.stall_frames} page-stalled frames left out, slowest tree cell build ${w.tree_build_max_ms} ms\n  spikes ${JSON.stringify(w.spikes)}`);
    if (moved < leg.minM) fail(name, `walked ${moved.toFixed(1)} m, expected at least ${leg.minM} m`);
    // A streaming hitch repeats at every new tile or cell; one isolated frame a little over the
    // limit also shows up in systems that do the same work every frame (timing noise), so it warns.
    // Grass reports what its slow frame did: when tile entry, ring selection and the upload add up
    // to under 2 ms, the rest is the page pausing inside grass (its longest system), not streaming,
    // so that frame is listed as a pause and not counted.
    const isPause = (sp) => sp.detail && sp.detail.ring_us !== undefined && (sp.detail.ring_us + sp.detail.enter_us) / 1000 + sp.upload_ms < 2;
    const pauses = w.spikes.filter(isPause);
    if (pauses.length) {
      console.log(`  pause ${pauses.map((p) => `${p.sys} ${p.ms} ms at ${p.t} s (named work ${((p.detail.ring_us + p.detail.enter_us) / 1000 + p.upload_ms).toFixed(1)} ms)`).join(', ')}`);
      results.legs[name].pauses = pauses;
    }
    for (const s of HITCH_SYSTEMS) {
      const real = w.spikes.filter((sp) => sp.sys === s && !isPause(sp));
      const n = (w.over_5ms[s] || 0) - pauses.filter((p) => p.sys === s).length;
      const worst = Math.max(0, ...real.map((sp) => sp.ms));
      if (n >= 2 || worst > 10) fail(name, `${s} over 5 ms of script in ${n} frames (worst ${worst} ms)`);
      else if (n === 1) { console.log(`  warn ${s} over 5 ms in 1 frame (${worst} ms)`); results.legs[name].warnings = [...(results.legs[name].warnings || []), `${s} ${worst} ms once`]; }
    }
    if (w.edge > 1850.01) fail(name, `walker at ${w.edge} m, past the 1850 m boundary`);
    if (leg.edge && w.edge < 1849) fail(name, `edge leg stopped at ${w.edge} m, never reached the boundary`);
    const errors = logs.filter((l) => /ERROR|SCRIPT|SHADER|PAGEERROR/.test(l));
    for (const e of errors) fail(name, `page: ${e}`);
    await page.close();
  }
} finally {
  await browser.close();
}
fs.writeFileSync(path.join(OUT, 'free_walk.json'), JSON.stringify(results, null, 1) + '\n');
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
