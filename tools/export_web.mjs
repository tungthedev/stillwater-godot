// Packs the exported valley (data/valley/*.f32 etc.) into the small set of files the Godot
// scene ships on every platform: data/valley/web/. The float32 originals stay as the reference
// that tests/check_world.gd compares against; they are never loaded by the scene.
//
// Files are PNGs because Godot decodes PNG natively (Image.load_png_from_buffer), so the phone
// never runs a per-texel GDScript loop, and PNG row filters turn smooth integer heights into
// small deltas that deflate well. They use the .pngdata extension so Godot's importer leaves
// them alone (an imported PNG would be re-encoded, possibly lossily).
//
//   near.pngdata   2048^2 RGB8: r,g = u16 height code (lo, hi), b = trail mask, 128 + round(mask * 127)
//   far.pngdata    2048^2 RGB8: r,g,b = u24 height code (lo, mid, hi)
//   biome.pngdata  512^2  RGB8: forest, flowers, meadow (as biome_rgb.u8)
//   noise.pngdata  512^2  RGBA8: Stillwater's tileable fbm/worley detail noise (noiseTex.js), baked
//   meta.json      decode rules, poses and a thinned trail for the walk camera
//
// Usage: node tools/export_web.mjs   (export_world.mjs runs it at the end)
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const SRC = path.join(ROOT, 'data/valley');
const OUT = path.join(SRC, 'web');

// Far heights span ~4.2 km, so 16 bits would be 6.5 cm steps; 3 cm steps (1.5 cm worst error)
// need 18 bits, hence 3 bytes per texel.
const FAR_STEP = 0.03;

const meta = JSON.parse(fs.readFileSync(path.join(SRC, 'meta.json'), 'utf8'));
const poses = JSON.parse(fs.readFileSync(path.join(SRC, 'poses.json'), 'utf8'));
const paths = JSON.parse(fs.readFileSync(path.join(SRC, 'paths.json'), 'utf8'));
const readF32 = (f) => { const b = fs.readFileSync(path.join(SRC, f)); return new Float32Array(b.buffer, b.byteOffset, b.length / 4); };
const readI16 = (f) => { const b = fs.readFileSync(path.join(SRC, f)); return new Int16Array(b.buffer, b.byteOffset, b.length / 2); };

// ---------- minimal PNG writer (8-bit, adaptive row filter) ----------
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, 'ascii'), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(zlib.crc32(td) >>> 0);
  return Buffer.concat([len, td, crc]);
}
function encodePng(w, h, channels, pixels) {
  const colorType = { 1: 0, 2: 4, 3: 2, 4: 6 }[channels];
  const stride = w * channels;
  const raw = Buffer.alloc((stride + 1) * h);
  const cand = [0, 1, 2, 3, 4].map(() => Buffer.alloc(stride));
  const zero = Buffer.alloc(stride);
  for (let y = 0; y < h; y++) {
    const cur = pixels.subarray(y * stride, (y + 1) * stride);
    const up = y > 0 ? pixels.subarray((y - 1) * stride, y * stride) : zero;
    let best = 0, bestCost = Infinity;
    for (let f = 0; f < 5; f++) {
      const o = cand[f];
      let cost = 0;
      for (let i = 0; i < stride; i++) {
        const a = i >= channels ? cur[i - channels] : 0;
        const b = up[i];
        const c = i >= channels ? up[i - channels] : 0;
        let p;
        if (f === 0) p = 0;
        else if (f === 1) p = a;
        else if (f === 2) p = b;
        else if (f === 3) p = (a + b) >> 1;
        else {
          const pa = Math.abs(b - c), pb = Math.abs(a - c), pc = Math.abs(a + b - 2 * c);
          p = pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
        }
        const v = (cur[i] - p) & 255;
        o[i] = v;
        cost += v < 128 ? v : 256 - v;
      }
      if (cost < bestCost) { bestCost = cost; best = f; }
    }
    raw[y * (stride + 1)] = best;
    cand[best].copy(raw, y * (stride + 1) + 1);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8; ihdr[9] = colorType; ihdr[10] = 0; ihdr[11] = 0; ihdr[12] = 0;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', zlib.deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// ---------- heights ----------
const range = (a) => { let mn = Infinity, mx = -Infinity; for (const v of a) { if (v < mn) mn = v; if (v > mx) mx = v; } return [mn, mx]; };

const near = readF32(meta.near.file);
const mask = readI16(meta.trailMask.file);
const [nMin, nMax] = range(near);
const nearStep = (nMax - nMin) / 65535;
const nRes = meta.near.res;
const nearPx = Buffer.alloc(nRes * nRes * 3);
let nearErr = 0;
for (let i = 0; i < near.length; i++) {
  const q = Math.round((near[i] - nMin) / nearStep);
  nearErr = Math.max(nearErr, Math.abs(nMin + q * nearStep - near[i]));
  nearPx[i * 3] = q & 255;
  nearPx[i * 3 + 1] = q >> 8;
  nearPx[i * 3 + 2] = 128 + Math.round((mask[i] / 32767) * 127);
}

const far = readF32(meta.far.file);
const [fMin, fMax] = range(far);
const fRes = meta.far.res;
const farPx = Buffer.alloc(fRes * fRes * 3);
let farErr = 0;
for (let i = 0; i < far.length; i++) {
  const q = Math.round((far[i] - fMin) / FAR_STEP);
  farErr = Math.max(farErr, Math.abs(fMin + q * FAR_STEP - far[i]));
  farPx[i * 3] = q & 255;
  farPx[i * 3 + 1] = (q >> 8) & 255;
  farPx[i * 3 + 2] = q >> 16;
}

// ---------- biome ----------
const biomeRgb = fs.readFileSync(path.join(SRC, meta.biome.rgb.file));

// ---------- noise (port of Stillwater src/world/noiseTex.js, float32 maths via fround) ----------
const fr = Math.fround;
const fract = (x) => fr(x - Math.floor(x));
function h12(px, py) {
  let x = fract(fr(px * fr(0.1031))), y = fract(fr(py * fr(0.1031))), z = x;
  const d = fr(fr(x * fr(y + 33.33)) + fr(y * fr(z + 33.33)) + fr(z * fr(x + 33.33)));
  x = fr(x + d); y = fr(y + d); z = fr(z + d);
  return fract(fr(fr(x + y) * z));
}
const mod = (a, p) => a - p * Math.floor(a / p);
function pnoise(x, y, P) {
  const ix = Math.floor(x), iy = Math.floor(y);
  const fx = x - ix, fy = y - iy;
  const ux = fx * fx * (3 - 2 * fx), uy = fy * fy * (3 - 2 * fy);
  const x0 = mod(ix, P), y0 = mod(iy, P), x1 = mod(ix + 1, P), y1 = mod(iy + 1, P);
  const a = h12(x0, y0), b = h12(x1, y0), c = h12(x0, y1), d = h12(x1, y1);
  return (a + (b - a) * ux) * (1 - uy) + (c + (d - c) * ux) * uy;
}
function pfbm(u, v, P, oct) {
  let a = 0, b = 0.5, n = 0;
  for (let i = 0; i < oct; i++) { a += b * pnoise(u * P, v * P, P); n += b; b *= 0.5; P *= 2; }
  return a / n;
}
function pworley(u, v, P) {
  const x = u * P, y = v * P, ix = Math.floor(x), iy = Math.floor(y), fx = x - ix, fy = y - iy;
  let d = 1;
  for (let gy = -1; gy <= 1; gy++) for (let gx = -1; gx <= 1; gx++) {
    const cx = mod(ix + gx, P), cy = mod(iy + gy, P);
    const ox = h12(cx, cy), oy = h12(cx + 17.31, cy + 17.31);
    d = Math.min(d, Math.hypot(gx + ox - fx, gy + oy - fy));
  }
  return d;
}
const NOISE_RES = 512;
const noisePx = Buffer.alloc(NOISE_RES * NOISE_RES * 4);
const to8 = (v) => Math.max(0, Math.min(255, Math.round(v * 255)));
for (let j = 0; j < NOISE_RES; j++) for (let i = 0; i < NOISE_RES; i++) {
  // Row j holds gl_FragCoord.y = j + 0.5, so texture v = (j + 0.5) / res samples it, as in three.
  const u = (i + 0.5) / NOISE_RES, v = (j + 0.5) / NOISE_RES;
  const k = (j * NOISE_RES + i) * 4;
  noisePx[k] = to8(pfbm(u, v, 4, 7));
  noisePx[k + 1] = to8(pfbm(u + 0.37, v + 0.37, 8, 6));
  noisePx[k + 2] = to8(pfbm(u + 0.71, v + 0.71, 16, 5));
  noisePx[k + 3] = to8(1 - (pworley(u, v, 8) * 0.6 + pworley(u, v, 16) * 0.3 + pworley(u, v, 32) * 0.1));
}

// ---------- walk route: the trail thinned to ~4 m steps ----------
const walk = [];
let last = null;
for (const [x, z] of paths.trail.points) {
  if (!last || Math.hypot(x - last[0], z - last[1]) >= 4) { walk.push([+x.toFixed(2), +z.toFixed(2)]); last = [x, z]; }
}

// ---------- write ----------
fs.rmSync(OUT, { recursive: true, force: true });
fs.mkdirSync(OUT, { recursive: true });
const sizes = {};
const put = (name, buf) => { fs.writeFileSync(path.join(OUT, name), buf); sizes[name] = buf.length; };
put('near.pngdata', encodePng(nRes, nRes, 3, nearPx));
put('far.pngdata', encodePng(fRes, fRes, 3, farPx));
put('biome.pngdata', encodePng(meta.biome.res, meta.biome.res, 3, biomeRgb));
put('noise.pngdata', encodePng(NOISE_RES, NOISE_RES, 4, noisePx));
const webMeta = {
  format: 1,
  worldHash: meta.worldHash,
  stillwaterCommit: meta.stillwaterCommit,
  decode: 'texel (ix, iz) of each map is world x = (ix + 0.5) / res * size - size / 2 (same for z); height = min + step * code; sample bilinear as meta.near.sample in ../meta.json',
  near: { file: 'near.pngdata', size: meta.near.size, res: nRes, min: nMin, step: nearStep, code: 'r + 256 g', maxQuantError: nearErr,
    trail: 'b: mask = (b - 128) / 127; trailAt = |bilinear(mask)|' },
  far: { file: 'far.pngdata', size: meta.far.size, res: fRes, min: fMin, step: FAR_STEP, code: 'r + 256 g + 65536 b', maxQuantError: farErr },
  biome: { file: 'biome.pngdata', size: meta.biome.size, res: meta.biome.res, channels: 'r forest, g flowers, b meadow; value / 255' },
  noise: { file: 'noise.pngdata', res: NOISE_RES, channels: 'rgba = fbm 4 (7 oct), fbm 8 (6), fbm 16 (5), 1 - worley 8/16/32; wraps' },
  blendStart: meta.heightRules.blendStart,
  blendEnd: meta.heightRules.blendEnd,
  waterLevel: meta.waterLevel,
  poses,
  walk,
  sizes,
};
fs.writeFileSync(path.join(OUT, 'meta.json'), JSON.stringify(webMeta) + '\n');
sizes['meta.json'] = fs.statSync(path.join(OUT, 'meta.json')).size;

const total = Object.values(sizes).reduce((a, b) => a + b, 0);
console.log(`web pack: ${(total / 1e6).toFixed(2)} MB in data/valley/web (near step ${(nearStep * 1000).toFixed(2)} mm, max err ${(nearErr * 1000).toFixed(2)} mm; far step ${FAR_STEP * 100} cm, max err ${(farErr * 1000).toFixed(2)} mm)`);
for (const [k, v] of Object.entries(sizes)) console.log(`  ${k}: ${(v / 1e6).toFixed(2)} MB`);
