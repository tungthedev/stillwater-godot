// Reference shots of Stillwater's terrain at the bench poses, other systems switched off, plus
// the light values the Godot port is calibrated against (sun colour, hemisphere colours,
// exposure, fog, cloud offset). Uses Stillwater's own Chrome launcher (GPU check included).
// Run under gpu-run against your own Stillwater dev server:
//   BASE=http://127.0.0.1:<port>/ gpu-run node tools/shoot_stillwater.mjs [--stillwater <path>] [--out captures/slice2]
//     [--keep trees,...]   leave these systems on (the ones Godot has drawn so far)
//     [--shots-only]       only the reference frames: no light values, no sky LUT rewrite
//     [--hide ferns,logs,shafts]  registry systems to hide at runtime (they have no ?no= switch)
//     [--stops trailhead] [--add '&pitch=-0.45'] [--tag close]  a variant of some stops
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const argVal = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const SW = path.resolve(argVal('--stillwater', '/home/hoalong/Projects/stillwater'));
const OUT = path.resolve(argVal('--out', 'captures/slice2'));
const BASE = (process.env.BASE || '').replace(/\/?$/, '/');
if (!process.env.BASE) throw new Error('set BASE to your Stillwater dev server');
const W = 675, H = 1130;
// Everything that is not terrain or sky. Ferns, logs, light shafts and the stream have no switch.
const KEEP = argVal('--keep', '').split(',').filter(Boolean);
const SHOTS_ONLY = args.includes('--shots-only');
const HIDE = argVal('--hide', '').split(',').filter(Boolean);
const STOPS = argVal('--stops', '').split(',').filter(Boolean);
const ADD = argVal('--add', '');
const TAG = argVal('--tag', '');
const NO = ['grass', 'trees', 'clouds', 'rocks', 'props', 'birds', 'motes', 'fly', 'spray', 'mist'].filter((s) => !KEEP.includes(s)).join(',');
const poses = JSON.parse(fs.readFileSync(path.resolve('data/valley/poses.json'), 'utf8'));

const { launchBrowser } = await import(pathToFileURL(path.join(SW, 'tools/chrome.mjs')).href);
const { browser, renderer } = await launchBrowser();
console.log('renderer', renderer);
fs.mkdirSync(OUT, { recursive: true });
const values = {};
try {
  for (const stop of Object.values(poses.stops).filter((s) => !STOPS.length || STOPS.includes(s.name))) {
    const page = await browser.newPage();
    await page.setViewport({ width: W, height: H, deviceScaleFactor: 1 });
    const url = `${BASE}?capture&q=low&no=${NO}&${stop.query}${ADD}`;
    await page.goto(url, { waitUntil: 'load', timeout: 120000 });
    if (HIDE.length) {
      // Capture mode stops drawing once the shot is ready, so hide them before its frames finish.
      await page.waitForFunction('window.__game?.registry || window.__error', { timeout: 300000, polling: 50 });
      const hidden = await page.evaluate((names) => names.map((n) => {
        const inst = window.__game.registry.instance?.(n);
        const objs = !inst ? [] : inst.isObject3D ? [inst] : ['mesh', 'group', 'points'].map((k) => inst[k]).filter((o) => o && 'visible' in o);
        objs.forEach((o) => { o.visible = false; });
        return `${n}:${objs.length}`;
      }), HIDE);
      const ready = await page.evaluate('window.__shotReady');
      console.log('hidden', hidden.join(' '), ready ? '(TOO LATE: shot already taken)' : '');
    }
    await page.waitForFunction('window.__shotReady || window.__error', { timeout: 300000, polling: 200 });
    const err = await page.evaluate('window.__error');
    if (err) throw new Error(err);
    const file = path.join(OUT, `stillwater_${stop.name}${TAG ? '_' + TAG : ''}.png`);
    await page.screenshot({ path: file });
    console.log(stop.name, file);
    if (SHOTS_ONLY) {
      await page.close();
      continue;
    }
    values[stop.name] = await page.evaluate(() => {
      const g = window.__game, U = g.U;
      const v3 = (v) => [v.x ?? v.r, v.y ?? v.g, v.z ?? v.b];
      const hemi = g.registry.instance?.('lighting')?.hemi;
      return {
        url: location.href,
        camera: { pos: v3(g.camera.position), fov: g.camera.fov, near: g.camera.near, far: g.camera.far },
        hours: g.env.hours,
        exposure: g.env.exposure,
        grade: { wb: v3(g.env.grade.wb), sat: g.env.grade.sat, contrast: g.env.grade.contrast, lift: v3(g.env.grade.lift), shadowTint: v3(g.env.grade.shadowTint) },
        sunDir: v3(U.uSunDir.value), lightCol: v3(U.uLightColor.value), sunCol: v3(U.uSunColor.value),
        hemiSky: hemi ? v3(hemi.color) : null, hemiGround: hemi ? v3(hemi.groundColor) : null, hemiIntensity: hemi?.intensity,
        fogBeta: v3(U.uFogBeta.value), fogFalloff: U.uFogFalloff.value, mist: U.uMist.value,
        cloudCover: U.uCloudCover.value, cloudOffset: [U.uCloudOffset.value.x, U.uCloudOffset.value.y],
        skyScale: U.uSkyScale.value, horizon: v3(U.uHorizonCol.value), aoSpot: [U.uAOSpot.value.x, U.uAOSpot.value.y, U.uAOSpot.value.z, U.uAOSpot.value.w],
        waterfall: [U.uWaterfall.value.x, U.uWaterfall.value.y, U.uWaterfall.value.z, U.uWaterfall.value.w],
        nodes: window.__info?.nodes,
      };
    });
    if (!values.skyLut) {
      // The sky-view LUT at this hour, read back as floats (colour * skyScale); the Godot port
      // samples it for the sky dome and the haze colours instead of approximating them.
      values.skyLut = await page.evaluate(() => {
        const g = window.__game, sky = g.sky, rt = sky.lutRT, w = rt.width, h = rt.height;
        const half = rt.texture.type === 1016;
        const raw = half ? new Uint16Array(w * h * 4) : new Float32Array(w * h * 4);
        g.renderer.readRenderTargetPixels(rt, 0, 0, w, h, raw);
        const dec = (x) => { const s = x & 0x8000 ? -1 : 1, e = (x >> 10) & 31, m = x & 1023;
          return e === 0 ? s * 2 ** -14 * (m / 1024) : e === 31 ? (m ? NaN : s * Infinity) : s * 2 ** (e - 15) * (1 + m / 1024); };
        const k = g.U.uSkyScale.value, rgb = [];
        for (let i = 0; i < w * h; i++) for (let c = 0; c < 3; c++) rgb.push((half ? dec(raw[i * 4 + c]) : raw[i * 4 + c]) * k);
        return { w, h, half, rgb };
      });
    }
    await page.close();
  }
} finally {
  await browser.close();
}
if (SHOTS_ONLY) process.exit(0);
// Rows as read back: row 0 is the bottom of the LUT (three's v = 0), which is also Godot's
// v = 0 row, so both engines sample it with the same uv.
const lut = values.skyLut;
const toHalf = (v) => {
  const u = new Uint32Array(new Float32Array([v]).buffer)[0];
  const s = (u >>> 16) & 0x8000;
  let e = ((u >>> 23) & 255) - 112;
  let m = Math.round((u & 0x7fffff) / 8192);
  if (m === 1024) { m = 0; e++; }
  if (e <= 0) return s;
  if (e >= 31) return s | 0x7bff;
  return s | (e << 10) | m;
};
fs.mkdirSync(path.resolve('data/sky'), { recursive: true });
const halfBuf = Buffer.alloc(lut.w * lut.h * 3 * 2);
lut.rgb.forEach((v, i) => halfBuf.writeUInt16LE(toHalf(Math.max(0, Math.min(v, 60000))), i * 2));
fs.writeFileSync(path.resolve('data/sky/sky_lut_16h.rgbh'), halfBuf);
console.log(`sky LUT ${lut.w}x${lut.h} (${lut.half ? 'half' : 'float'} target) -> data/sky/sky_lut_16h.rgbh`);
delete values.skyLut;
fs.writeFileSync(path.join(OUT, 'stillwater_values.json'), JSON.stringify(values, null, 1) + '\n');
