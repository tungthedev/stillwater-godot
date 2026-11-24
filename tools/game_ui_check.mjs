// Game UI check for the Web build in GPU Chrome, all driven by real touch input on the phone view
// (390x844@3, iPhone user agent) except where noted. Control positions and state come from
// window.__ui, which systems/walk_log.gd publishes under ?walklog. Cases:
//   pause_freeze  Trail on, pause for 5 s: the walker must not move while the sheet is up.
//   hud_buttons   single-touch taps on Sit/Stand, Trail and Pause fire once each, and second-finger
//                 taps on Sit, Stand, Trail and Pause work while the stick thumb stays held.
//   stick_recovery lost touchEnd reclaim, touchCancel clear + fresh drag, quick release + re-touch
//                 while the stick fade-out tween is running keeps the ring visible.
//   two_thumbs    stick and look at once, then lift only the look thumb: distance and yaw both
//                 change, and the stick keeps walking after the other thumb lifts.
//   perf_bench    pause, Perf, flip the Grass lever, then Bench: the bench runs from the game page,
//                 shows its results, and the walk is back after.
//   debug_flag    ?debug shows the perf readout and levers at load.
//   safe_areas    iPhone insets on #safe (portrait 47/34, landscape 47 on the sides): the pause
//                 button, compass and touch buttons move inside them.
//   BASE=http://127.0.0.1:<port>/ gpu-run node tools/game_ui_check.mjs [--out captures/w1/ui]
//     [--cases pause_freeze,...] [--build w1-1]
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const argVal = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const SW = path.resolve(argVal('--stillwater', '/home/hoalong/Projects/stillwater'));
const OUT = path.resolve(argVal('--out', 'captures/w1/ui'));
const BUILD = argVal('--build', '');
const BASE = (process.env.BASE || '').replace(/\/?$/, '/');
if (!process.env.BASE) throw new Error('set BASE to the server for build/web');
const PHONE = { width: 390, height: 844, deviceScaleFactor: 3, isMobile: true, hasTouch: true };
const LAND = { width: 844, height: 390, deviceScaleFactor: 3, isMobile: true, hasTouch: true, isLandscape: true };
const PHONE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.7 Mobile/15E148 Safari/604.1';
const ALL = ['pause_freeze', 'hud_buttons', 'stick_recovery', 'two_thumbs', 'perf_bench', 'debug_flag', 'safe_areas'];
const CASES = argVal('--cases', ALL.join(',')).split(',');

const { launchBrowser } = await import(pathToFileURL(path.join(SW, 'tools/chrome.mjs')).href);
const { browser, renderer } = await launchBrowser([]);
console.log('renderer', renderer);
fs.mkdirSync(OUT, { recursive: true });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let failed = false;
const results = { renderer, cases: {} };

async function open(view, query = '', css = '') {
  const page = await browser.newPage();
  const logs = [];
  page.on('console', (m) => logs.push(m.text()));
  page.on('pageerror', (e) => logs.push('PAGEERROR ' + e.message));
  await page.setUserAgent(PHONE_UA);
  await page.setViewport(view);
  if (css) await page.evaluateOnNewDocument((c) => document.addEventListener('DOMContentLoaded', () => { const st = document.createElement('style'); st.textContent = c; document.head.append(st); }), css);
  await page.goto(`${BASE}index.html?walklog${query}`, { waitUntil: 'load', timeout: 180000 });
  const t0 = Date.now();
  while (!logs.some((l) => l.startsWith('BUILD'))) {
    if (Date.now() - t0 > 150000) throw new Error('no BUILD line: ' + logs.slice(-5).join(' | '));
    await sleep(200);
  }
  const build = logs.find((l) => l.startsWith('BUILD'));
  if (BUILD && !build.startsWith(`BUILD ${BUILD} `)) throw new Error(`stale build: ${build}`);
  const cdp = await page.target().createCDPSession();
  const touch = (type, pts) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: pts.map(([id, x, y]) => ({ id, x, y, radiusX: 2, radiusY: 2, force: 1 })) });
  const tap = async (x, y) => { await touch('touchStart', [[9, x, y]]); await sleep(80); await touch('touchEnd', []); await sleep(120); };
  const ui = () => page.evaluate(() => window.__ui || null);
  // A fresh reading: __ui is published every 0.25 s.
  const fresh = async () => { await sleep(400); return ui(); };
  const until = async (what, pred, ms) => {
    const t = Date.now();
    for (;;) {
      const u = await ui();
      if (u && pred(u)) return u;
      if (Date.now() - t > ms) throw new Error(`timed out waiting for ${what}: ${JSON.stringify(u)}`);
      await sleep(150);
    }
  };
  const tapRect = async (r, what) => {
    if (!r || !r.length) throw new Error(`${what} not on screen`);
    await tap(r[0] + r[2] / 2, r[1] + r[3] / 2);
  };
  const shot = async (tag) => { const f = path.join(OUT, `${tag}.png`); await page.screenshot({ path: f }); return path.relative(process.cwd(), f); };
  const start = async () => {
    await until('title', (u) => u.mode === 'title', 30000);
    await sleep(1500);
    await tap(view.width / 2, view.height / 2);
    return until('play', (u) => u.mode === 'play' && u.fade > 0.95, 30000);
  };
  return { page, logs, touch, tap, ui, fresh, until, tapRect, shot, start };
}

async function run(name, fn) {
  console.log(`== ${name}`);
  const r = { checks: [], shots: [] };
  results.cases[name] = r;
  const check = (ok, msg) => { r.checks.push({ ok, msg }); console.log(`  ${ok ? 'ok  ' : 'FAIL'} ${msg}`); if (!ok) failed = true; };
  try {
    await fn(check, r);
  } catch (e) {
    check(false, e.message);
  }
}

try {
  if (CASES.includes('pause_freeze')) await run('pause_freeze', async (check, r) => {
    const p = await open(PHONE);
    let u = await p.start();
    await p.tapRect(u.trail_btn, 'Trail button');
    await sleep(3000);
    u = await p.fresh();
    check(u.auto_walk, 'Trail button turned trail follow on');
    await p.tapRect(u.pause_btn, 'pause button');
    const d1 = (await p.fresh()).distance;
    await sleep(5000);
    u = await p.fresh();
    r.shots.push(await p.shot('pause_freeze_sheet'));
    check(u.paused, 'pause button paused');
    check(u.distance - d1 < 0.2, `walker held still for 5 s paused (moved ${(u.distance - d1).toFixed(2)} m, trail follow at 2.1 m/s would be ~10 m)`);
    const d2 = u.distance;
    await p.tapRect(u.resume_btn, 'resume');
    await sleep(2000);
    u = await p.fresh();
    check(!u.paused, 'tap resumed');
    check(u.distance - d2 > 2, `walk carried on after resume (${(u.distance - d2).toFixed(2)} m in ~2.4 s)`);
    await p.page.close();
  });

  if (CASES.includes('hud_buttons')) await run('hud_buttons', async (check, r) => {
    const p = await open(PHONE);
    let u = await p.start();
    const center = (rect, what) => {
      if (!rect || !rect.length) throw new Error(`${what} not on screen`);
      return [rect[0] + rect[2] / 2, rect[1] + rect[3] / 2];
    };
    // Single-touch tap on Sit -> Stand -> Trail on/off -> Pause/Resume (each must fire once).
    await p.tapRect(u.sit_btn, 'Sit button');
    u = await p.fresh();
    check(u.sitting && u.sit_text === 'STAND', `single tap Sit engaged sitting (sitting=${u.sitting}, label=${u.sit_text})`);
    await p.tapRect(u.sit_btn, 'Stand button');
    u = await p.fresh();
    check(!u.sitting && u.sit_text === 'SIT', `single tap Stand stood up (sitting=${u.sitting}, label=${u.sit_text})`);
    await p.tapRect(u.trail_btn, 'Trail button');
    u = await p.fresh();
    check(u.auto_walk, 'single tap Trail turned auto-walk on');
    await p.tapRect(u.trail_btn, 'Trail button');
    u = await p.fresh();
    check(!u.auto_walk, 'single tap Trail turned auto-walk off');
    await p.tapRect(u.pause_btn, 'Pause button');
    u = await p.fresh();
    check(u.paused, 'single tap Pause paused');
    await p.tapRect(u.resume_btn, 'Resume button');
    u = await p.fresh();
    check(!u.paused, 'single tap Resume resumed');

    // Stick thumb held (id 1) + second finger (id 2) taps Sit -> must sit and stop moving.
    const W = PHONE.width, H = PHONE.height;
    const sx = W * 0.25, sy = H * 0.72;
    const d0 = u.distance;
    await p.touch('touchStart', [[1, sx, sy]]);
    for (let i = 1; i <= 8; i++) { await p.touch('touchMove', [[1, sx, sy - i * 6]]); await sleep(16); }
    await sleep(1400);
    u = await p.fresh();
    check(u.distance - d0 > 1.0, `stick walked before second-finger Sit (${(u.distance - d0).toFixed(2)} m)`);
    const [sitX, sitY] = center(u.sit_btn, 'Sit button');
    await p.touch('touchStart', [[1, sx, sy - 48], [2, sitX, sitY]]);
    await sleep(80);
    await p.touch('touchEnd', [[2, sitX, sitY]]);
    u = await p.fresh();
    r.shots.push(await p.shot('hud_buttons_stick_sit'));
    check(u.sitting && u.sit_text === 'STAND', `second-finger tap Sit while holding stick sat down (sitting=${u.sitting}, label=${u.sit_text})`);
    const dSit = u.distance;
    await sleep(1800);
    u = await p.fresh();
    check(u.distance - dSit < 0.5, `walker stopped after sitting while stick stayed held (moved ${(u.distance - dSit).toFixed(2)} m)`);
    // Stand back up with second finger while stick is still held.
    const [standX, standY] = center(u.sit_btn, 'Stand button');
    await p.touch('touchStart', [[1, sx, sy - 48], [2, standX, standY]]);
    await sleep(80);
    await p.touch('touchEnd', [[2, standX, standY]]);
    u = await p.fresh();
    check(!u.sitting && u.sit_text === 'SIT', `second-finger tap Stand stood up (sitting=${u.sitting}, label=${u.sit_text})`);
    await p.touch('touchEnd', []);
    await sleep(300);

    // Stick thumb held (id 1) + second finger (id 2) taps Trail -> auto-walk turns on.
    u = await p.fresh();
    await p.touch('touchStart', [[1, sx, sy]]);
    for (let i = 1; i <= 8; i++) { await p.touch('touchMove', [[1, sx, sy - i * 6]]); await sleep(16); }
    await sleep(600);
    u = await p.fresh();
    const [trailX, trailY] = center(u.trail_btn, 'Trail button');
    await p.touch('touchStart', [[1, sx, sy - 48], [2, trailX, trailY]]);
    await sleep(80);
    await p.touch('touchEnd', [[2, trailX, trailY]]);
    u = await p.fresh();
    check(u.auto_walk, 'second-finger tap Trail while holding stick turned auto-walk on');
    await p.touch('touchEnd', []);
    const dRel = (await p.fresh()).distance;
    await sleep(1600);
    u = await p.fresh();
    check(u.distance - dRel > 1.5, `auto-walk carried on after stick lifted (${(u.distance - dRel).toFixed(2)} m)`);
    await p.tapRect(u.trail_btn, 'Trail button off');

    // Stick thumb held (id 1) + second finger (id 2) taps Pause -> pauses cleanly.
    u = await p.fresh();
    await p.touch('touchStart', [[1, sx, sy]]);
    for (let i = 1; i <= 8; i++) { await p.touch('touchMove', [[1, sx, sy - i * 6]]); await sleep(16); }
    await sleep(300);
    u = await p.fresh();
    const [pauseX, pauseY] = center(u.pause_btn, 'Pause button');
    await p.touch('touchStart', [[1, sx, sy - 48], [2, pauseX, pauseY]]);
    await sleep(80);
    await p.touch('touchEnd', [[2, pauseX, pauseY]]);
    u = await p.fresh();
    check(u.paused, 'second-finger tap Pause while holding stick paused');
    await p.touch('touchEnd', []);
    const errs = p.logs.filter((l) => /SCRIPT ERROR|PAGEERROR|ERROR:/.test(l));
    check(errs.length === 0, `no errors (${errs.slice(0, 3).join(' | ')})`);
    await p.page.close();
  });

  if (CASES.includes('stick_recovery')) await run('stick_recovery', async (check, r) => {
    const p = await open(PHONE);
    let u = await p.start();
    const W = PHONE.width, H = PHONE.height;
    const sx1 = W * 0.22, sy1 = H * 0.65;
    const sx2 = W * 0.30, sy2 = H * 0.78;

    // 1. Orphaned stick touch (no touchEnd): a fresh left-half touch reclaims the stick at its new origin.
    await p.touch('touchStart', [[1, sx1, sy1]]);
    for (let i = 1; i <= 8; i++) { await p.touch('touchMove', [[1, sx1, sy1 - i * 6]]); await sleep(16); }
    await sleep(600);
    u = await p.fresh();
    check(u.stick_active && u.stick_alpha > 0.9, `initial stick active (active=${u.stick_active}, alpha=${u.stick_alpha})`);
    const dReclaim0 = u.distance;
    // Start a fresh left-half touch (id 3) WITHOUT sending touchEnd for id 1.
    await p.touch('touchStart', [[1, sx1, sy1 - 48], [3, sx2, sy2]]);
    for (let i = 1; i <= 8; i++) { await p.touch('touchMove', [[1, sx1, sy1 - 48], [3, sx2, sy2 - i * 6]]); await sleep(16); }
    await sleep(1200);
    u = await p.fresh();
    const ringCx = u.stick_pos[0] + 52, ringCy = u.stick_pos[1] + 52;
    check(Math.abs(ringCx - sx2) < 6 && Math.abs(ringCy - sy2) < 6, `fresh touch reclaimed stick origin (${ringCx.toFixed(1)},${ringCy.toFixed(1)} vs ${sx2.toFixed(1)},${sy2.toFixed(1)})`);
    check(u.stick_active && u.stick_alpha > 0.9, `reclaimed stick visible (active=${u.stick_active}, alpha=${u.stick_alpha})`);
    check(u.distance - dReclaim0 > 1.0, `reclaimed stick walked (${(u.distance - dReclaim0).toFixed(2)} m)`);
    await p.touch('touchEnd', []);
    await sleep(300);
    u = await p.fresh();
    check(!u.stick_active && u.stick_alpha < 0.05, `no stale ring after release (active=${u.stick_active}, alpha=${u.stick_alpha})`);

    // 2. touchCancel clears stick and hides ring; fresh left-half drag works cleanly after.
    await p.touch('touchStart', [[4, sx1, sy1]]);
    for (let i = 1; i <= 8; i++) { await p.touch('touchMove', [[4, sx1, sy1 - i * 6]]); await sleep(16); }
    await sleep(500);
    u = await p.fresh();
    check(u.stick_active && u.stick_alpha > 0.9, `stick active before touchCancel (active=${u.stick_active}, alpha=${u.stick_alpha})`);
    await p.touch('touchCancel', []);
    await sleep(300);
    u = await p.fresh();
    check(!u.stick_active && u.stick_alpha < 0.05, `touchCancel cleared stick and hid ring (active=${u.stick_active}, alpha=${u.stick_alpha})`);
    const dCancel = u.distance;
    await sleep(1000);
    u = await p.fresh();
    check(u.distance - dCancel < 0.6, `walker stopped after touchCancel (moved ${(u.distance - dCancel).toFixed(2)} m)`);
    const dAfterCancel = u.distance;
    await p.touch('touchStart', [[5, sx2, sy2]]);
    for (let i = 1; i <= 8; i++) { await p.touch('touchMove', [[5, sx2, sy2 - i * 6]]); await sleep(16); }
    await sleep(1200);
    u = await p.fresh();
    check(u.stick_active && u.stick_alpha > 0.9 && u.distance - dAfterCancel > 1.0, `fresh drag after touchCancel walked (${(u.distance - dAfterCancel).toFixed(2)} m, alpha=${u.stick_alpha})`);
    await p.touch('touchEnd', []);
    await sleep(300);

    // 3. Quick release and re-touch inside the 140 ms fade-out tween must show the stick ring.
    await p.touch('touchStart', [[6, sx1, sy1]]);
    for (let i = 1; i <= 6; i++) { await p.touch('touchMove', [[6, sx1, sy1 - i * 6]]); await sleep(16); }
    await sleep(250);
    await p.touch('touchEnd', []);
    await sleep(50);
    await p.touch('touchStart', [[7, sx2, sy2]]);
    await sleep(350);
    u = await p.fresh();
    r.shots.push(await p.shot('stick_recovery_retouch'));
    check(u.stick_active && u.stick_alpha > 0.9, `quick release + re-touch showed the stick ring (active=${u.stick_active}, alpha=${u.stick_alpha})`);
    const dQuick = u.distance;
    for (let i = 1; i <= 8; i++) { await p.touch('touchMove', [[7, sx2, sy2 - i * 6]]); await sleep(16); }
    await sleep(1000);
    u = await p.fresh();
    check(u.distance - dQuick > 0.8, `quick re-touch stick walked (${(u.distance - dQuick).toFixed(2)} m)`);
    await p.touch('touchEnd', []);
    const errs = p.logs.filter((l) => /SCRIPT ERROR|PAGEERROR|ERROR:/.test(l));
    check(errs.length === 0, `no errors (${errs.slice(0, 3).join(' | ')})`);
    await p.page.close();
  });

  if (CASES.includes('two_thumbs')) await run('two_thumbs', async (check, r) => {
    const p = await open(PHONE);
    let u = await p.start();
    const W = PHONE.width, H = PHONE.height;
    const sx = W * 0.25, sy = H * 0.72, lx = W * 0.75, ly = H * 0.5;
    const d0 = u.distance, y0 = u.yaw;
    await p.touch('touchStart', [[1, sx, sy]]);
    for (let i = 1; i <= 8; i++) { await p.touch('touchMove', [[1, sx, sy - i * 6]]); await sleep(16); }
    await p.touch('touchStart', [[1, sx, sy - 48], [2, lx, ly]]);
    for (let i = 1; i <= 30; i++) { await p.touch('touchMove', [[1, sx, sy - 48], [2, lx + i * 4, ly]]); await sleep(33); }
    u = await p.fresh();
    check(u.distance - d0 > 1, `stick walked while the other thumb looked (${(u.distance - d0).toFixed(2)} m)`);
    check(Math.abs(u.yaw - y0) > 0.1, `look thumb turned the view at the same time (yaw ${y0} -> ${u.yaw})`);
    // Lift only the look thumb (CDP touchEnd releases the points it lists); the stick stays down.
    await p.touch('touchEnd', [[2, lx + 120, ly]]);
    const d1 = (await p.fresh()).distance;
    await sleep(3000);
    u = await p.fresh();
    r.shots.push(await p.shot('two_thumbs_walk'));
    check(u.distance - d1 > 4, `stick kept walking after the look thumb lifted (${(u.distance - d1).toFixed(2)} m in ~3.4 s)`);
    await p.touch('touchEnd', []);
    const d2 = (await p.fresh()).distance;
    await sleep(1500);
    u = await p.fresh();
    check(u.distance - d2 < 1.5, `walker slowed to a stop after both thumbs lifted (${(u.distance - d2).toFixed(2)} m in 1.9 s)`);
    await p.page.close();
  });

  if (CASES.includes('perf_bench')) await run('perf_bench', async (check, r) => {
    const p = await open(PHONE);
    let u = await p.start();
    check(!u.dev_on && !u.dev_grid, 'perf levers hidden on the game page');
    await p.tapRect(u.pause_btn, 'pause button');
    u = await p.fresh();
    r.shots.push(await p.shot('perf_0_paused'));
    await p.tapRect(u.perf_btn, 'Perf button');
    u = await p.fresh();
    check(u.dev_on && u.dev_grid, 'Perf on the pause sheet shows the readout and levers');
    const grass0 = u.grass_on;
    await p.tapRect(u.lever_grass, 'Grass lever');
    u = await p.fresh();
    r.shots.push(await p.shot('perf_1_levers'));
    check(u.grass_on !== grass0, `Grass lever flipped grass ${grass0 ? 'off' : 'on'}`);
    await p.tapRect(u.lever_grass, 'Grass lever');
    await p.tapRect(u.lever_bench, 'Bench lever');
    u = await p.until('bench start', (x) => x.bench_running, 10000);
    check(true, 'Bench started from the game page');
    await sleep(3000);
    r.shots.push(await p.shot('perf_2_bench_running'));
    u = await p.until('bench results', (x) => !x.bench_running, 300000);
    await sleep(1000);
    u = await p.fresh();
    r.shots.push(await p.shot('perf_3_bench_done'));
    check(u.bench_done, 'bench results panel shown');
    check(u.hud_visible, 'game HUD back after the bench');
    const errs = p.logs.filter((l) => /SCRIPT ERROR|PAGEERROR|ERROR:/.test(l));
    check(errs.length === 0, `no errors (${errs.slice(0, 3).join(' | ')})`);
    // Back to the walk: close the results, resume the pause sheet, walk with the stick.
    await p.tapRect(u.panel_close, 'results Close');
    u = await p.fresh();
    check(!u.bench_done, 'Close hid the results');
    if (u.paused) await p.tapRect(u.resume_btn, 'resume');
    u = await p.fresh();
    check(!u.paused, 'resume after the bench');
    const d0 = (await p.fresh()).distance;
    const sx = PHONE.width * 0.25, sy = PHONE.height * 0.72;
    await p.touch('touchStart', [[1, sx, sy]]);
    for (let i = 1; i <= 8; i++) { await p.touch('touchMove', [[1, sx, sy - i * 6]]); await sleep(16); }
    await sleep(3000);
    u = await p.fresh();
    await p.touch('touchEnd', []);
    r.shots.push(await p.shot('perf_4_walk_after'));
    check(u.distance - d0 > 3, `walk works after the bench (${(u.distance - d0).toFixed(2)} m in ~3.4 s)`);
    r.final = u;
    await p.page.close();
  });

  if (CASES.includes('debug_flag')) await run('debug_flag', async (check, r) => {
    const p = await open(PHONE, '&debug');
    const u = await p.until('title', (x) => x.mode === 'title', 30000);
    await sleep(2000);
    r.shots.push(await p.shot('debug_title'));
    check(u.dev_on && u.dev_grid, '?debug shows the readout and levers at load');
    await p.page.close();
  });

  if (CASES.includes('safe_areas')) await run('safe_areas', async (check, r) => {
    // Portrait: insets present from page load (Safari portrait). Landscape: insets appear mid-play,
    // followed by a resize, as when Safari rotates.
    for (const [tag, view, pad] of [['portrait', PHONE, [47, 0, 34, 0]], ['landscape', LAND, [0, 47, 21, 47]]]) {
      const css = `#safe { padding: ${pad.map((v) => v + 'px').join(' ')} !important; }`;
      const p = await open(view, '', tag === 'portrait' ? css : '');
      if (tag === 'landscape') {
        await p.start();
        await p.page.addStyleTag({ content: css });
        await p.page.setViewport({ ...view, width: view.width - 1 });
        await sleep(500);
        await p.page.setViewport(view);
      }
      if (tag === 'portrait') await p.start();
      await sleep(600);
      const u = await p.fresh();
      r.shots.push(await p.shot(`safe_${tag}`));
      check(u.safe.join() === pad.join(), `${tag}: HUD read the insets ${JSON.stringify(u.safe)}`);
      const [px, py, pw] = u.pause_btn;
      check(py >= pad[0] && px + pw <= view.width - pad[1], `${tag}: pause button inside the insets (${u.pause_btn.map(Math.round)})`);
      const t = u.trail_btn;
      check(t[1] + t[3] <= view.height - pad[2] && t[0] >= pad[3], `${tag}: Trail button inside the insets (${t.map(Math.round)})`);
      const c = u.compass;
      if (c.length) check(c[1] >= pad[0], `${tag}: compass below the top inset (${c.map(Math.round)})`);
      await p.page.close();
    }
  });
} finally {
  await browser.close();
}
fs.writeFileSync(path.join(OUT, 'game_ui.json'), JSON.stringify(results, null, 2));
console.log(failed ? 'FAIL' : 'PASS');
process.exit(failed ? 1 : 0);
