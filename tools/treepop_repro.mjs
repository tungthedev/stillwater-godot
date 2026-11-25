// Deterministic close-tree flicker/pop repro in GPU Chrome at phone size (390x844 @ dpr 3).
// Drives scripted camera trajectories via ?treepop&noui (walk past close oaks/pines crossing a
// 32 m hero-cell boundary, strafe past static hero oaks with zero LOD swap, and yaw pan across
// close screen-edge crowns), captures consecutive rendered frames, and measures:
//   - raw_pct:    % of upper-75% pixels with max-channel delta > 28 between frames t-1 and t
//   - pop_px/pct: motion-unexplained pop pixels (no matching pixel within +/-R px in frame t-1,
//                 threshold > 28) -- isolates sudden card/branch disappearances from smooth parallax
//   - sev_px:     high-contrast pop pixels (same, threshold > 50, e.g. leaf card <-> sky/core)
//   - lod_swaps:  exact frames where hero_changed or mid_changed fired
// Optionally writes 8-frame horizontal strips for visual inspection.
//
// Usage:
//   BASE=http://127.0.0.1:<port>/ gpu-run node tools/treepop_repro.mjs \
//     --out captures/tree-pop/diag \
//     --variants "old=,cardfade0=cardfade=0,heror200=heror=200,aabbpad50=aabbpad=50" \
//     [--paths walk,strafe,edge_turn] [--strip 1] [--build w5-1]
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { encodePng } from './png.mjs';

const args = process.argv.slice(2);
const argVal = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const SW = path.resolve(argVal('--stillwater', '/home/hoalong/Projects/stillwater'));
const OUT = path.resolve(argVal('--out', 'captures/tree-pop/diag'));
const BUILD = argVal('--build', '');
const PATH_NAMES = argVal('--paths', 'walk,strafe,edge_turn').split(',').filter(Boolean);
const SAVE_STRIP = argVal('--strip', '1') !== '0';
const EXTRA = argVal('--extra', '');
const VAR_SPEC = argVal('--variants', 'old=');
const VARIANTS = VAR_SPEC.split(',').map((s) => {
  const eq = s.indexOf('=');
  return eq >= 0 ? { name: s.slice(0, eq), query: s.slice(eq + 1) } : { name: s, query: '' };
});
const BASE = (process.env.BASE || '').replace(/\/?$/, '/');
if (!process.env.BASE) throw new Error('set BASE to the server for build/web');

const PHONE = { width: 390, height: 844, deviceScaleFactor: 3, isMobile: true, hasTouch: true };

// Deterministic camera trajectories (16 frames each).
function makePaths() {
  const walk = [];
  // Walks 4.8 m from (-496.5,-370.0) to (-501.1,-369.1) in 0.30 m steps looking up at close
  // oaks & pines (8-20 m). Crosses LOD_STEP=4.0 m and hero_r=12 m enter boundary for cell
  // (-17,-12) [x=-544..-512] around step 13 (x=-500.4), triggering hero <-> mid1 swap on camera.
  for (let i = 0; i < 16; i++) {
    const u = i / 15;
    walk.push({
      x: -496.5 + (-501.1 - -496.5) * u,
      z: -370.0 + (-369.1 - -370.0) * u,
      yaw: 1.76,
      pitch: 0.22,
    });
  }

  const strafe = [];
  // Strafes 2.8 m (< LOD_STEP 4 m, zero LOD swaps) in 0.19 m steps past static heroOaks (14-18 m)
  // with camera pitched up into the crowns so parallax is <= 4 px/step.
  const tgtX = -549.4, tgtZ = -374.2;
  for (let i = 0; i < 16; i++) {
    const u = i / 15;
    const x = -534.0 + (-536.0 - -534.0) * u;
    const z = -371.5 + (-373.5 - -371.5) * u;
    const dx = tgtX - x, dz = tgtZ - z;
    strafe.push({
      x, z,
      yaw: Math.atan2(-dx, -dz),
      pitch: 0.26,
    });
  }

  const edge_turn = [];
  // Pans smoothly (0.80 deg/step = ~10 px/step) across close oaks/pines and heroOaks so crowns
  // enter/exit the left and right edges of the phone screen.
  for (let i = 0; i < 16; i++) {
    const u = i / 15;
    edge_turn.push({
      x: -526.0,
      z: -369.0,
      yaw: 0.90 + (1.11 - 0.90) * u,
      pitch: 0.14,
    });
  }

  return { walk, strafe, edge_turn };
}

const ALL_PATHS = makePaths();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const { launchBrowser } = await import(pathToFileURL(path.join(SW, 'tools/chrome.mjs')).href);
const { browser, renderer } = await launchBrowser(['--disable-gpu-vsync', '--disable-frame-rate-limit']);
console.log('renderer', renderer);
fs.mkdirSync(OUT, { recursive: true });

// Compare two 390x844 RGBA frames in-browser (fast, zero disk round-trip).
async function analyzeFrames(page, framesB64, searchR) {
  return page.evaluate(async ({ framesB64, searchR }) => {
    const W = 390, H = 844;
    const c = document.createElement('canvas');
    c.width = W; c.height = H;
    const g = c.getContext('2d', { willReadFrequently: true });
    const imgs = [];
    for (const b64 of framesB64) {
      const img = new Image();
      img.src = 'data:image/png;base64,' + b64;
      await img.decode();
      g.drawImage(img, 0, 0, W, H);
      imgs.push(new Uint8Array(g.getImageData(0, 0, W, H).data));
    }
    const yEnd = Math.floor(H * 0.68); // upper 68% is pure tree crowns + sky (no foreground ferns/grass)
    const area = W * yEnd;
    // Precompute spiral offsets ordered by distance^2 so matching nearby parallax breaks out fast.
    const offs = [];
    for (let dy = -searchR; dy <= searchR; dy++) {
      for (let dx = -searchR; dx <= searchR; dx++) {
        if (dx === 0 && dy === 0) continue;
        offs.push([dx, dy, dx * dx + dy * dy]);
      }
    }
    offs.sort((a, b) => a[2] - b[2]);
    const odx = new Int16Array(offs.length);
    const ody = new Int16Array(offs.length);
    for (let k = 0; k < offs.length; k++) { odx[k] = offs[k][0]; ody[k] = offs[k][1]; }
    const nOff = offs.length;

    const steps = [];
    for (let t = 1; t < imgs.length; t++) {
      const cur = imgs[t];
      const prv = imgs[t - 1];
      let rawChanged = 0;
      let popPx = 0;
      let sevPx = 0;
      let sumAbs = 0;
      for (let y = 0; y < yEnd; y++) {
        for (let x = 0; x < W; x++) {
          const i = (y * W + x) * 4;
          const r = cur[i], gg = cur[i + 1], b = cur[i + 2];
          const dr0 = Math.abs(r - prv[i]);
          const dg0 = Math.abs(gg - prv[i + 1]);
          const db0 = Math.abs(b - prv[i + 2]);
          const d0 = dr0 > dg0 ? (dr0 > db0 ? dr0 : db0) : (dg0 > db0 ? dg0 : db0);
          sumAbs += (dr0 + dg0 + db0) / 3;
          if (d0 <= 28) continue;
          rawChanged++;
          let best = d0;
          for (let k = 0; k < nOff; k++) {
            const nx = x + odx[k];
            if (nx < 0 || nx >= W) continue;
            const ny = y + ody[k];
            if (ny < 0 || ny >= H) continue;
            const ni = (ny * W + nx) * 4;
            const dr = Math.abs(r - prv[ni]);
            if (dr >= best) continue;
            const dg = Math.abs(gg - prv[ni + 1]);
            if (dg >= best) continue;
            const db = Math.abs(b - prv[ni + 2]);
            const d = dr > dg ? (dr > db ? dr : db) : (dg > db ? dg : db);
            if (d < best) {
              best = d;
              if (best <= 28) break;
            }
          }
          if (best > 28) {
            popPx++;
            if (best > 50) sevPx++;
          }
        }
      }
      steps.push({
        step: t,
        raw_px: rawChanged,
        raw_pct: +(100 * rawChanged / area).toFixed(3),
        pop_px: popPx,
        pop_pct: +(100 * popPx / area).toFixed(3),
        sev_px: sevPx,
        sev_pct: +(100 * sevPx / area).toFixed(3),
        mean_abs: +(sumAbs / area).toFixed(2),
      });
    }
    return { W, H, yEnd, area, steps };
  }, { framesB64, searchR });
}

// Assemble an 8-frame horizontal strip PNG (downscaled 220x476 per frame, with a 2px dark divider).
async function buildStrip(page, framesB64, startIdx, count, outPath) {
  const slice = framesB64.slice(startIdx, startIdx + count);
  const { w, h, rgb } = await page.evaluate(async (slice) => {
    const fw = 220, fh = 476, gap = 2;
    const W = slice.length * fw + (slice.length - 1) * gap;
    const H = fh;
    const c = document.createElement('canvas');
    c.width = W; c.height = H;
    const g = c.getContext('2d');
    g.fillStyle = '#181818';
    g.fillRect(0, 0, W, H);
    for (let i = 0; i < slice.length; i++) {
      const img = new Image();
      img.src = 'data:image/png;base64,' + slice[i];
      await img.decode();
      g.drawImage(img, i * (fw + gap), 0, fw, fh);
    }
    const d = g.getImageData(0, 0, W, H).data;
    const out = new Uint8Array(W * H * 3);
    for (let i = 0, j = 0; i < d.length; i += 4, j += 3) {
      out[j] = d[i]; out[j + 1] = d[i + 1]; out[j + 2] = d[i + 2];
    }
    return { w: W, h: H, rgb: Array.from(out) };
  }, slice);
  fs.writeFileSync(outPath, encodePng(w, h, 3, Buffer.from(rgb)));
}

const report = { renderer, base: BASE, paths: PATH_NAMES, variants: {} };
let seqCounter = 1;

try {
  for (const v of VARIANTS) {
    const page = await browser.newPage();
    const logs = [];
    page.on('console', (m) => logs.push(m.text()));
    page.on('pageerror', (e) => logs.push('PAGEERROR ' + e.message));
    await page.setViewport(PHONE);
    const qParts = ['treepop', 'noui'];
    if (v.query) qParts.push(v.query);
    if (EXTRA) qParts.push(EXTRA.replace(/^[?&]/, ''));
    const url = `${BASE}index.html?${qParts.join('&')}`;
    await page.goto(url, { waitUntil: 'load', timeout: 180000 });
    const t0 = Date.now();
    while (!logs.some((l) => l.startsWith('BUILD'))) {
      if (Date.now() - t0 > 120000) throw new Error(`${v.name}: no BUILD line: ${logs.slice(-5).join(' | ')}`);
      await sleep(200);
    }
    const build = logs.find((l) => l.startsWith('BUILD'));
    if (BUILD && !build.startsWith(`BUILD ${BUILD} `)) throw new Error(`stale build: ${build}`);
    // Wait until __tpState appears (scene running).
    await page.waitForFunction('Boolean(window.__tpState)', { timeout: 60000 });
    await sleep(300);

    const vRes = { query: v.query, build, paths: {}, errors: [] };
    for (const pname of PATH_NAMES) {
      const traj = ALL_PATHS[pname];
      // Search radius sized to exceed per-step camera parallax/pan so smooth motion never scores as a pop.
      const searchR = pname === 'edge_turn' ? 14 : (pname === 'walk' ? 10 : 7);
      // Prime pose 0 and let 4 frames render so initial LOD/bake settles.
      const s0 = seqCounter++;
      await page.evaluate(({ seq, p }) => { window.__tpCmd = { seq, ...p }; }, { seq: s0, p: traj[0] });
      try {
        await page.waitForFunction(`window.__tpState && window.__tpState.seq === ${s0} && window.__tpState.frame >= 4`, { timeout: 15000 });
      } catch (e) {
        const st = await page.evaluate(() => ({ state: window.__tpState, cmd: window.__tpCmd }));
        throw new Error(`${v.name}/${pname} s0 timeout: ${JSON.stringify(st)} logs=${logs.slice(-10).join(' | ')}`);
      }

      const framesB64 = [];
      const states = [];
      for (let i = 0; i < traj.length; i++) {
        const seq = seqCounter++;
        await page.evaluate(({ seq, p }) => { window.__tpCmd = { seq, ...p }; }, { seq, p: traj[i] });
        // Capture right after frame >= 2 (1 full render after pose update) to catch any LOD-swap / SwapMultiMesh 1-frame vanish!
        await page.waitForFunction(`window.__tpState && window.__tpState.seq === ${seq} && window.__tpState.frame >= 2`, { timeout: 30000 });
        const st = await page.evaluate(() => window.__tpState);
        const b64 = await page.screenshot({ encoding: 'base64' });
        framesB64.push(b64);
        states.push(st);
      }

      const metrics = await analyzeFrames(page, framesB64, searchR);
      for (let i = 0; i < metrics.steps.length; i++) {
        const st = states[i + 1];
        metrics.steps[i].hero_changed = st.hero_changed;
        metrics.steps[i].mid_changed = st.mid_changed;
        metrics.steps[i].hero_cells = st.hero_cells;
        metrics.steps[i].hero_cnt = st.hero_cnt;
        metrics.steps[i].lod_gen = st.lod_gen;
      }
      const totalPop = metrics.steps.reduce((a, s) => a + s.pop_px, 0);
      const totalSev = metrics.steps.reduce((a, s) => a + s.sev_px, 0);
      const avgPop = +(totalPop / metrics.steps.length).toFixed(1);
      const avgSev = +(totalSev / metrics.steps.length).toFixed(1);
      const maxPop = Math.max(...metrics.steps.map((s) => s.pop_px));
      const maxSev = Math.max(...metrics.steps.map((s) => s.sev_px));
      const avgRaw = +(metrics.steps.reduce((a, s) => a + s.raw_pct, 0) / metrics.steps.length).toFixed(2);
      const lodSteps = metrics.steps.filter((s) => s.hero_changed || s.mid_changed).map((s) => ({
        step: s.step, hero_changed: s.hero_changed, mid_changed: s.mid_changed, pop_px: s.pop_px, sev_px: s.sev_px,
      }));
      // Pick best 8-frame strip window (centered around peak sev_px or steps 6..13)
      let stripPath = '';
      if (SAVE_STRIP) {
        stripPath = path.join(OUT, `strip_${v.name}_${pname}.png`);
        const startIdx = pname === 'walk' ? 7 : 4;
        await buildStrip(page, framesB64, startIdx, 8, stripPath);
      }
      vRes.paths[pname] = {
        searchR,
        avg_raw_pct: avgRaw,
        avg_pop_px: avgPop,
        max_pop_px: maxPop,
        total_pop_px: totalPop,
        avg_sev_px: avgSev,
        max_sev_px: maxSev,
        total_sev_px: totalSev,
        lod_swaps: lodSteps,
        strip: stripPath ? path.relative(process.cwd(), stripPath) : '',
        steps: metrics.steps,
      };
      console.log(`[${v.name.padEnd(16)}] ${pname.padEnd(9)} raw=${avgRaw.toFixed(2).padStart(5)}%  pop_avg=${String(avgPop).padStart(6)}px (max ${String(maxPop).padStart(5)})  sev_avg=${String(avgSev).padStart(6)}px (max ${String(maxSev).padStart(5)})  lod_swaps=${lodSteps.length}`);
      for (const ls of lodSteps) {
        console.log(`    LOD swap at step ${ls.step}: hero=${ls.hero_changed} mid=${ls.mid_changed} pop=${ls.pop_px}px sev=${ls.sev_px}px`);
      }
    }
    vRes.errors = logs.filter((l) => /PAGEERROR|SCRIPT ERROR|SHADER ERROR/.test(l));
    for (const e of vRes.errors) console.log('  !', e);
    report.variants[v.name] = vRes;
    await page.close();
  }
} finally {
  await browser.close();
}

fs.writeFileSync(path.join(OUT, 'treepop_repro.json'), JSON.stringify(report, null, 2) + '\n');
console.log('saved', path.join(OUT, 'treepop_repro.json'));
