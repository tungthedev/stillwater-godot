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
import { fileURLToPath } from 'node:url';
import { encodePng } from './png.mjs';

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

// ---------- trees: the low tier's rank subset, quantised ----------
// x, y, z are u24 codes over the 32 km far map (2 mm steps, 1 mm worst error). y is the rendered
// ground (near map blended into far over 1828-2028 m, as the terrain draws it) minus the game's
// sink, so trees stand on the terrain Godot draws; inside 1828 m that equals the game's y exactly.
const TIER = 'low';
const tier = meta.tiers[TIER];
const WORLD = meta.far.size;
const Q24 = 16777215;
const tn = meta.trees.count;
const tf = readF32(meta.trees.file);
const rankBuf = fs.readFileSync(path.join(SRC, meta.trees.rank.file));
const rank = new Uint16Array(rankBuf.buffer, rankBuf.byteOffset, rankBuf.length / 2);
const kinds = fs.readFileSync(path.join(SRC, meta.trees.kind.file));
const sampleGrid = (arr, res, size, x, z) => {
  const fx = Math.min(Math.max((x / size + 0.5) * res - 0.5, 0), res - 1.001);
  const fz = Math.min(Math.max((z / size + 0.5) * res - 0.5, 0), res - 1.001);
  const ix = Math.floor(fx), iz = Math.floor(fz), tx = fx - ix, tz = fz - iz, i = iz * res + ix;
  return (arr[i] * (1 - tx) + arr[i + 1] * tx) * (1 - tz) + (arr[i + res] * (1 - tx) + arr[i + res + 1] * tx) * tz;
};
const ss = (a, b, x) => { const t = Math.min(Math.max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t); };
const renderHeight = (x, z) => {
  const t = ss(meta.heightRules.blendStart, meta.heightRules.blendEnd, Math.max(Math.abs(x), Math.abs(z)));
  const hn = sampleGrid(near, nRes, meta.near.size, x, z);
  return t <= 0 ? hn : hn + (sampleGrid(far, fRes, meta.far.size, x, z) - hn) * t;
};
const keep = [];
const limit = tier.trees * 65536;
for (let i = 0; i < tn; i++) if (rank[i] < limit) keep.push(i);
if (keep.length !== tier.expectedTrees) throw new Error(`low subset ${keep.length} != ${tier.expectedTrees}`);
const m = keep.length;
const S_MAX = 64, SX_MIN = 0.5, TINT_MAX = 2;
const treeBuf = Buffer.alloc(m * 19);
let o = 0;
const put24 = (v) => { const q = Math.round((v / WORLD + 0.5) * Q24); treeBuf[o++] = q & 255; treeBuf[o++] = (q >> 8) & 255; treeBuf[o++] = q >> 16; };
const put16 = (q) => { treeBuf.writeUInt16LE(q, o); o += 2; };
const field = (f, i) => tf[f * tn + i];
let maxGroundShift = 0, bandTrees = 0;
const ys = keep.map((i) => {
  const x = field(0, i), z = field(2, i);
  const y = renderHeight(x, z) - (kinds[i] === 3 ? 0.15 : 0.25);
  if (Math.max(Math.abs(x), Math.abs(z)) > meta.heightRules.blendStart) {
    bandTrees++;
    maxGroundShift = Math.max(maxGroundShift, Math.abs(y - field(1, i)));
  }
  return y;
});
for (const i of keep) put24(field(0, i));
for (const y of ys) put24(y);
for (const i of keep) put24(field(2, i));
for (const i of keep) put16(Math.round(field(3, i) / S_MAX * 65535));
for (const i of keep) put16(Math.round(field(4, i) / (Math.PI * 2) * 65536) & 65535);
for (const i of keep) put16(Math.round((field(5, i) - SX_MIN) * 65535));
for (const i of keep) for (let c = 0; c < 3; c++) treeBuf[o++] = Math.round(Math.min(field(6 + c, i), TINT_MAX) / TINT_MAX * 255);
for (const i of keep) treeBuf[o++] = kinds[i];
if (o !== treeBuf.length) throw new Error('tree pack size');
const extras = JSON.parse(fs.readFileSync(path.join(SRC, 'extras.json'), 'utf8'));
const heroOaks = extras.heroOaks.map((t) => ({ ...t, y: renderHeight(t.x, t.z) - 0.35 }));
console.log(`trees: ${m} (${TIER} tier), ${bandTrees} in the near/far blend band, where y moves by up to ${maxGroundShift.toFixed(2)} m from the game's near-only y`);

// ---------- write ----------
fs.rmSync(OUT, { recursive: true, force: true });
fs.mkdirSync(OUT, { recursive: true });
const sizes = {};
const put = (name, buf) => { fs.writeFileSync(path.join(OUT, name), buf); sizes[name] = buf.length; };
put('near.pngdata', encodePng(nRes, nRes, 3, nearPx));
put('far.pngdata', encodePng(fRes, fRes, 3, farPx));
put('biome.pngdata', encodePng(meta.biome.res, meta.biome.res, 3, biomeRgb));
put('noise.pngdata', encodePng(NOISE_RES, NOISE_RES, 4, noisePx));
put('trees.bin', treeBuf);
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
  trees: {
    file: 'trees.bin', count: m, tier: TIER, tierValues: tier, worldHash: meta.worldHash,
    subset: 'canonical trees with rank < tier density, in canonical order (WorldData.selectByRank)',
    layout: 'planar little-endian: x, y, z u24; s, rot, sx u16; tint rgb u8 interleaved; kind u8',
    decode: { world: WORLD, q24: Q24, sMax: S_MAX, sxMin: SX_MIN, tintMax: TINT_MAX },
    rule: 'v = (code / q24 - 0.5) * world for x, y, z; s = code / 65535 * sMax; rot = code / 65536 * 2 pi; sx = sxMin + code / 65535; tint = code / 255 * tintMax',
    y: 'rendered ground (near/far blend) - 0.25, bush - 0.15',
    heroOaks,
  },
  poses,
  walk,
  sizes,
};
fs.writeFileSync(path.join(OUT, 'meta.json'), JSON.stringify(webMeta) + '\n');
sizes['meta.json'] = fs.statSync(path.join(OUT, 'meta.json')).size;

const total = Object.values(sizes).reduce((a, b) => a + b, 0);
console.log(`web pack: ${(total / 1e6).toFixed(2)} MB in data/valley/web (near step ${(nearStep * 1000).toFixed(2)} mm, max err ${(nearErr * 1000).toFixed(2)} mm; far step ${FAR_STEP * 100} cm, max err ${(farErr * 1000).toFixed(2)} mm)`);
for (const [k, v] of Object.entries(sizes)) console.log(`  ${k}: ${(v / 1e6).toFixed(2)} MB`);
