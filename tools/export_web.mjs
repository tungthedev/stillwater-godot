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
//   colliders.bin  every canonical non-bush tree (all tiers collide alike), bucketed by 32 m cell
//   meta.json      decode rules, poses, a thinned trail for the walk camera, and the game's
//                  trail, places, benches and walking rules
//
// Usage: node tools/export_web.mjs   (export_world.mjs runs it at the end)
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { encodePng } from './png.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const SRC = path.join(ROOT, 'data/valley');
const OUT = path.join(SRC, 'web');
const SW = '/home/hoalong/Projects/stillwater';

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
// Ranks of the kept trees, so a density lever can draw any rank prefix as Stillwater's tiers do.
const rankOut = Buffer.alloc(m * 2);
keep.forEach((i, j) => rankOut.writeUInt16LE(rank[i], j * 2));
const extras = JSON.parse(fs.readFileSync(path.join(SRC, 'extras.json'), 'utf8'));
const heroOaks = extras.heroOaks.map((t) => ({ ...t, y: renderHeight(t.x, t.z) - 0.35 }));
// Add the storybook cottage framing oak (village.js line 190) so trees.gd draws it with zero extra draw calls.
if (extras.anchors?.house) {
  const H = extras.anchors.house;
  const fx = H.front[0], fz = H.front[1], rx2 = -fz, rz2 = fx;
  const ox = H.x - fx * 9.5 - rx2 * 10.5;
  const oz = H.z - fz * 9.5 - rz2 * 10.5;
  heroOaks.push({ x: ox, z: oz, y: renderHeight(ox, oz) - 0.30, s: 16.5, rot: 1.4, tint: [1.04, 1.02, 0.94] });
}
console.log(`trees: ${m} (${TIER} tier), ${bandTrees} in the near/far blend band, where y moves by up to ${maxGroundShift.toFixed(2)} m from the game's near-only y`);

// ---------- tree colliders: the full canonical list, as WorldData.collideTrees uses on every tier ----------
// Bucketed by 32 m cell over the near map so the game reads a cell's trees straight from the bytes.
// Per tree: x, z as u16 in 1/16 m from the map's -x/-z edge (3 cm worst error), s as u8 in 1/8 m.
// Blocking radius = s * 0.03 + the walker's radius (Player.update passes 0.35).
const COL_CELL = 32, COL_G = meta.near.size / COL_CELL, COL_HALF = meta.near.size / 2;
const cellOf = (x, z) => Math.min(COL_G - 1, Math.max(0, Math.floor((z + COL_HALF) / COL_CELL))) * COL_G
  + Math.min(COL_G - 1, Math.max(0, Math.floor((x + COL_HALF) / COL_CELL)));
const colIdx = [];
for (let i = 0; i < tn; i++) if (kinds[i] !== 3) colIdx.push(i);
colIdx.sort((a, b) => cellOf(field(0, a), field(2, a)) - cellOf(field(0, b), field(2, b)) || a - b);
const colStarts = new Uint32Array(COL_G * COL_G + 1);
for (const i of colIdx) colStarts[cellOf(field(0, i), field(2, i)) + 1]++;
for (let c = 0; c < COL_G * COL_G; c++) colStarts[c + 1] += colStarts[c];
const colBuf = Buffer.alloc(colStarts.length * 4 + colIdx.length * 5);
colStarts.forEach((v, c) => colBuf.writeUInt32LE(v, c * 4));
let co = colStarts.length * 4, colErr = 0;
for (const i of colIdx) {
  const qx = Math.min(65535, Math.round((field(0, i) + COL_HALF) * 16));
  const qz = Math.min(65535, Math.round((field(2, i) + COL_HALF) * 16));
  const qs = Math.min(255, Math.round(field(3, i) * 8));
  colErr = Math.max(colErr, Math.abs(qx / 16 - COL_HALF - field(0, i)), Math.abs(qz / 16 - COL_HALF - field(2, i)));
  colBuf.writeUInt16LE(qx, co); colBuf.writeUInt16LE(qz, co + 2); colBuf[co + 4] = qs; co += 5;
}
console.log(`colliders: ${colIdx.length} non-bush trees, max position error ${(colErr * 100).toFixed(1)} cm`);

// ---------- game: Stillwater's walking rules and places (src/content/valley.js, extras.json) ----------
const trail = paths.trail.points.map(([x, z]) => [+x.toFixed(2), +z.toFixed(2)]);
const game = {
  note: 'src/content/valley.js and the baked anchors; trail is the full trail (Player autoWalk and placeAtStart index it)',
  boundary: 1850,
  lake: meta.lake,
  summit: extras.anchors.summit,
  pois: extras.anchors.pois,
  benches: extras.anchors.benches,
  trail,
};

// ---------- water: lake, stream path, and waterfall geometry (from src/world/water.js, stream.js, waterfall.js) ----------
const streamPts = paths.stream ? paths.stream.points : [];
const streamBrink = paths.stream?.brink ?? null;
let waterfall = null;
if (streamPts.length > 8) {
  const sn = streamPts.length;
  const sh = (x, z) => sampleGrid(near, nRes, meta.near.size, x, z);
  let mi = 0, maxG = 0;
  for (let i = 4; i < sn - 4; i++) {
    const g = (sh(streamPts[i - 3][0], streamPts[i - 3][1]) - sh(streamPts[i + 3][0], streamPts[i + 3][1])) / 12;
    if (g > maxG) { maxG = g; mi = i; }
  }
  if (maxG >= 0.35) {
    let foot = mi;
    while (foot < sn - 4) {
      const a = sh(streamPts[foot][0], streamPts[foot][1]), b = sh(streamPts[foot + 3][0], streamPts[foot + 3][1]);
      if ((a - b) / 6 < 0.16) break;
      foot++;
    }
    let top = mi;
    while (top > 3) {
      const a = sh(streamPts[top - 3][0], streamPts[top - 3][1]), b = sh(streamPts[top][0], streamPts[top][1]);
      if ((a - b) / 6 < 0.25) break;
      top--;
    }
    const k = streamBrink ?? top;
    const [bx, bz] = streamPts[k];
    const j = Math.min(sn - 1, k + 3);
    const ux0 = streamPts[j][0] - bx, uz0 = streamPts[j][1] - bz, ul = Math.hypot(ux0, uz0) || 1;
    const ux = ux0 / ul, uz = uz0 / ul, lx = -uz, lz = ux;
    const profH = (d, lat = 0) => sh(bx + ux * d + lx * lat, bz + uz * d + lz * lat);
    let yCrest = -1e9;
    for (let d = -16; d <= -2; d++) yCrest = Math.max(yCrest, profH(d, 0));
    let dLip = -10;
    for (let d = -14; d <= 6; d += 0.5) if (profH(d, 0) >= yCrest - 2.6) dLip = d;
    const yBaseEst = profH(18, 0);
    let dToe = dLip + 6;
    for (let d = dLip + 2; d <= 20; d += 0.5) {
      if (profH(d, 0) <= yBaseEst + 2.8) { dToe = d; break; }
    }
    const yTop = yCrest - 0.85;
    const fi = Math.min(sn - 1, foot + 3);
    const poolDist = Math.max(20.0, dToe + 15.5);
    const poolX = bx + ux * poolDist, poolZ = bz + uz * poolDist;
    const poolY = Math.max(sh(poolX, poolZ) + 2.35, sh(bx + ux * (poolDist + 16), bz + uz * (poolDist + 16)) + 0.52);
    const landDist = Math.max(dToe + 5.2, poolDist - 6.0);
    waterfall = {
      brink: k,
      footIdx: fi,
      bx: +bx.toFixed(3), bz: +bz.toFixed(3),
      ux: +ux.toFixed(6), uz: +uz.toFixed(6),
      yTop: +yTop.toFixed(3),
      dLip: +dLip.toFixed(2),
      dToe: +dToe.toFixed(2),
      poolDist: +poolDist.toFixed(2),
      poolCenter: [+poolX.toFixed(3), +poolY.toFixed(3), +poolZ.toFixed(3)],
      poolR: 25.0,
      landDist: +landDist.toFixed(2),
      impactPt: [+(bx + ux * landDist).toFixed(3), +poolY.toFixed(3), +(bz + uz * landDist).toFixed(3)],
    };
  }
}
const water = {
  lake: meta.lake,
  stream: streamPts.length ? {
    brink: streamBrink,
    points: streamPts.map(([x, z]) => [+x.toFixed(2), +z.toFixed(2)]),
  } : null,
  waterfall,
};

// ---------- water shot & bench poses (derived from world anchors and stream/waterfall geometry) ----------
const eyeH = poses.eyeHeight;
const makePose = (name, x, z, yaw, pitch) => {
  const ground = sampleGrid(near, nRes, meta.near.size, x, z);
  const eyeY = ground + eyeH;
  const lookDist = 10;
  return {
    name,
    position: [+x.toFixed(4), +eyeY.toFixed(4), +z.toFixed(4)],
    ground: +ground.toFixed(4),
    yaw: +yaw.toFixed(6),
    pitch: +pitch.toFixed(6),
    roll: 0,
    eulerOrder: 'YXZ',
    lookAt: [
      +(x - Math.sin(yaw) * Math.cos(pitch) * lookDist).toFixed(4),
      +(eyeY + Math.sin(pitch) * lookDist).toFixed(4),
      +(z - Math.cos(yaw) * Math.cos(pitch) * lookDist).toFixed(4),
    ],
  };
};
const yawToward = (x, z, tx, tz) => Math.atan2(-(tx - x), -(tz - z));
const webPoses = { ...poses, stops: { ...poses.stops } };
// Lake wide: bench 0 overlooking Stillwater Lake toward the basin and far waterfall.
{
  const b0 = extras.anchors.benches[0];
  const L = meta.lake;
  webPoses.stops.lake = makePose('lake', b0.x, b0.z, yawToward(b0.x, b0.z, L.x, L.z), -0.06);
}
// Lake shore close: standing on the bare sandy eastern beach (below tall grass) looking diagonally
// along the curving foam rim, turquoise shallows, deep sapphire basin, and mountains.
{
  const L = meta.lake;
  const ang = -0.05;
  const dx = Math.cos(ang), dz = Math.sin(ang);
  let r = 460;
  while (r > 50 && sampleGrid(near, nRes, meta.near.size, L.x + dx * r, L.z + dz * r) > meta.waterLevel + 0.18) r -= 0.5;
  const sx = L.x + dx * r, sz = L.z + dz * r;
  webPoses.stops.lake_shore = makePose('lake_shore', sx, sz, yawToward(sx, sz, 25, 95), -0.14);
}
// Stream close: south bank of the carved lower river channel looking upstream along the flowing water.
if (streamPts.length > 500) {
  const si = 491;
  const [px, pz] = streamPts[si], [qx, qz] = streamPts[Math.min(streamPts.length - 1, si + 4)];
  const tx = qx - px, tz = qz - pz, tl = Math.hypot(tx, tz) || 1;
  const sx = px - tz / tl * 5.2, sz = pz + tx / tl * 5.2;
  const [lx, lz] = streamPts[si - 16];
  const eyeY = sampleGrid(near, nRes, meta.near.size, sx, sz) + eyeH;
  const tgtY = sampleGrid(near, nRes, meta.near.size, lx, lz) + 0.4;
  const pitch = Math.atan2(tgtY - eyeY, Math.hypot(lx - sx, lz - sz)) - 0.14;
  webPoses.stops.stream = makePose('stream', sx, sz, yawToward(sx, sz, lx, lz), pitch);
}
// Waterfall: south-west bank beside the outflow stream (matching shots.json fallsStream) framing
// the outflow stream, turquoise plunge pool with foam rings, splash crown, and full braided cascade.
if (waterfall) {
  const fk = Math.min(streamPts.length - 2, waterfall.footIdx + 16);
  const [fpx, fpz] = streamPts[fk], [fqx, fqz] = streamPts[fk + 1];
  const ftx = fqx - fpx, ftz = fqz - fpz, ftl = Math.hypot(ftx, ftz) || 1;
  const wx = fpx - ftz / ftl * 5.5, wz = fpz + ftx / ftl * 5.5;
  const eyeY = sampleGrid(near, nRes, meta.near.size, wx, wz) + eyeH;
  const [pcx, pcy, pcz] = waterfall.poolCenter;
  const topX = waterfall.bx + waterfall.ux * waterfall.dLip;
  const topZ = waterfall.bz + waterfall.uz * waterfall.dLip;
  const tgx = pcx * 0.65 + topX * 0.35;
  const tgz = pcz * 0.65 + topZ * 0.35;
  const tgy = (pcy - 1.4) * 0.68 + (waterfall.yTop - 3.0) * 0.32;
  const pitch = Math.atan2(tgy - eyeY, Math.hypot(tgx - wx, tgz - wz));
  webPoses.stops.waterfall = makePose('waterfall', wx, wz, yawToward(wx, wz, tgx, tgz), pitch);
}

// ---------- W3 rocks, cottage, village & props (from worldData.js, village.js, props.js) ----------
const mulberry32 = (seed) => {
  let a = seed | 0;
  return () => {
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
};
const tPts = paths.trail.points;
const tDist = paths.trail.dist;
const tAt = (i) => tPts[Math.max(0, Math.min(tPts.length - 1, i))];
const tDirAt = (i) => {
  const a = tAt(i - 2), b = tAt(i + 2);
  const l = Math.hypot(b[0] - a[0], b[1] - a[1]) || 1;
  return [(b[0] - a[0]) / l, (b[1] - a[1]) / l];
};
const tNearestIdx = (x, z) => {
  let bi = 0, bd = 1e18;
  for (let i = 0; i < tPts.length; i++) {
    const d = (tPts[i][0] - x) ** 2 + (tPts[i][1] - z) ** 2;
    if (d < bd) { bd = d; bi = i; }
  }
  return bi;
};

// Canonical rocks from data/valley/rocks.f32 (low tier rocks = 1.0 -> all 1122 rocks).
const rCount = meta.rocks.count;
const rf = readF32(meta.rocks.file);
const rKind = fs.readFileSync(path.join(SRC, meta.rocks.kind.file));
const rField = (f, i) => rf[f * rCount + i];
// Rock pack record: 10 x float32 (40 bytes):
// [x, y, z, sx, sy, sz, rot, tilt_x, tilt_z, kind_flags]
// kind_flags = kind (0..3) + 16 * is_prop_stone (0 = canonical, 1 = prop/cairn/landmark stone).
const rockRecords = [];
for (let i = 0; i < rCount; i++) {
  const rx0 = rField(0, i), ry0 = rField(1, i), rz0 = rField(2, i);
  const rs = rField(3, i), rrot = rField(4, i), tx = rField(5, i), tz = rField(6, i);
  const hNear = sampleGrid(near, nRes, meta.near.size, rx0, rz0);
  const hRen = renderHeight(rx0, rz0);
  const ry = ry0 + (hRen - hNear);
  rockRecords.push([rx0, ry, rz0, rs, rs, rs, rrot, tx, tz, rKind[i]]);
}

const propColliders = [];
const pushPropStone = (x, y, z, sx, sy, sz, rot, tiltX = 0, tiltZ = 0, kind = 0) => {
  rockRecords.push([x, y, z, sx, sy, sz, rot, tiltX, tiltZ, (kind & 3) | 16]);
};
const addCairn = (x, y0, z, scale, count) => {
  const rnd = mulberry32(Math.floor(x * 13 + z * 7));
  let y = y0;
  let s = 0.54 * scale;
  const shapes = [
    [1.18, 0.78, 0.96], [0.92, 0.84, 1.10], [1.08, 0.70, 0.86],
    [0.86, 0.86, 0.94], [1.02, 0.68, 0.84], [0.82, 0.88, 0.82], [0.90, 0.76, 0.80],
  ];
  for (let i = 0; i < count; i++) {
    const sh = shapes[i % shapes.length];
    const ss = s * (0.88 + rnd() * 0.20);
    const sx = ss * sh[0], sy = ss * sh[1] * 0.68, sz = ss * sh[2];
    const tx = (rnd() - 0.5) * 0.14, tz = (rnd() - 0.5) * 0.14;
    const rot = rnd() * Math.PI * 2;
    const ox = (rnd() - 0.5) * 0.05 * scale, oz = (rnd() - 0.5) * 0.05 * scale;
    const hStone = sy * 1.45;
    const cy = y + sy * (i === 0 ? 0.36 : 0.44);
    pushPropStone(x + ox, cy, z + oz, sx, sy, sz, rot, tx, tz, i % 3);
    y = cy + hStone * 0.40;
    s *= 0.82;
  }
  propColliders.push({ x: +x.toFixed(2), z: +z.toFixed(2), r: +(0.6 * scale).toFixed(2) });
};

// Cottage & village (from village.js)
const vRnd = mulberry32(31);
const H = extras.anchors.house;
const hcx = H.x, hcz = H.z, hry = H.ry, hfx = H.front[0], hfz = H.front[1];
let hgMin = Infinity, hgMax = -Infinity;
for (const [ox, oz] of [[-6, -5], [6, -5], [-6, 5], [6, 5], [0, 0]]) {
  const g = renderHeight(hcx + ox, hcz + oz);
  hgMin = Math.min(hgMin, g); hgMax = Math.max(hgMax, g);
}
const houseY = (hgMin + hgMax) * 0.5 - 0.2;
const house = {
  x: +hcx.toFixed(3), y: +houseY.toFixed(3), z: +hcz.toFixed(3),
  ry: +hry.toFixed(6), scale: 1.2, front: [+hfx.toFixed(6), +hfz.toFixed(6)],
};
propColliders.push({ x: +hcx.toFixed(2), z: +hcz.toFixed(2), r: 7.4 });

// Cottage yard flagstones (12 stones from door to trail)
const flagstones = [];
{
  const doorX = hcx + hfx * 4.0, doorZ = hcz + hfz * 4.0;
  for (let k = 0; k < 12; k++) {
    const x = doorX + hfx * k * 1.0 + Math.sin(k * 1.3) * 0.3 * hfz;
    const z = doorZ + hfz * k * 1.0 - Math.sin(k * 1.3) * 0.3 * hfx;
    const r = 0.44 + vRnd() * 0.12;
    const rot = vRnd() * 3.0;
    const tone = 0.6 + vRnd() * 0.12;
    flagstones.push([+x.toFixed(2), +(renderHeight(x, z) + 0.03).toFixed(3), +z.toFixed(2), +r.toFixed(3), +rot.toFixed(3), +tone.toFixed(3)]);
  }
}

// Cottage foundation bushes (10 lush bushes hugging the plinth, village.js line 157)
const cottageBushes = [];
{
  const rx2 = -hfz, rz2 = hfx;
  for (const [a, b] of [[5.8, -4.6], [5.8, 4.8], [3.0, -6.6], [-1.0, -6.6], [-4.4, -6.4], [3.2, 6.6], [-0.6, 6.7], [-4.8, 6.2], [-5.8, -2.5], [-5.9, 2.0]]) {
    const bx = hcx + hfx * a * 1.2 + rx2 * b * 1.2;
    const bz = hcz + hfz * a * 1.2 + rz2 * b * 1.2;
    const s = 1.15 + vRnd() * 0.55;
    cottageBushes.push([+bx.toFixed(2), +(renderHeight(bx, bz) - 0.12).toFixed(3), +bz.toFixed(2), +s.toFixed(2), +(vRnd() * 6.28).toFixed(2)]);
  }
}

// Split-rail trail fences (village.js lines 202-231)
const fences = [];
{
  const runs = [[12, 180, 1], [40, 150, -1], [560, 720, -1], [900, 1010, 1]];
  for (const [d0, d1, s] of runs) {
    let seg = [];
    let prevD = -1e9;
    for (let i = 0; i < tPts.length; i++) {
      const d = tDist[i];
      if (d < d0 || d > d1) continue;
      if (seg.length && d - prevD < 2.6) continue;
      const j = Math.min(tPts.length - 1, i + 2), k = Math.max(0, i - 2);
      const ddx = tPts[j][0] - tPts[k][0], ddz = tPts[j][1] - tPts[k][1], l = Math.hypot(ddx, ddz) || 1;
      const px = tPts[i][0] - ddz / l * 2.7 * s, pz = tPts[i][1] + ddx / l * 2.7 * s;
      const py = renderHeight(px, pz);
      if (py < meta.waterLevel + 0.5 || Math.hypot(px - hcx, pz - hcz) < 12) {
        if (seg.length >= 2) fences.push(seg);
        seg = [];
        prevD = -1e9;
        continue;
      }
      if (seg.length && d - prevD >= 5.5) {
        if (seg.length >= 2) fences.push(seg);
        seg = [];
      }
      seg.push([+px.toFixed(2), +py.toFixed(3), +pz.toFixed(2)]);
      prevD = d;
    }
    if (seg.length >= 2) fences.push(seg);
  }
}

// Lantern posts (gate lantern + trail lanterns, village.js lines 239-269)
const lanterns = [];
{
  const addLantern = (x, z, armX, armZ) => {
    const y = renderHeight(x, z);
    lanterns.push([+x.toFixed(2), +y.toFixed(3), +z.toFixed(2), +armX.toFixed(4), +armZ.toFixed(4)]);
    propColliders.push({ x: +x.toFixed(2), z: +z.toFixed(2), r: 0.25 });
  };
  const gx0 = hcx + hfx * 14.5 - hfz * 2.2, gz0 = hcz + hfz * 14.5 + hfx * 2.2;
  addLantern(gx0, gz0, -hfx, -hfz);
  let next = 60;
  const dawnD = 0.2 * tDist[tDist.length - 1];
  for (let i = 0; i < tPts.length && tDist[i] < 1400; i++) {
    if (tDist[i] < next) continue;
    next += 110;
    if (Math.abs(tDist[i] - dawnD) < 28) continue;
    const j = Math.min(tPts.length - 1, i + 2);
    const ddx = tPts[j][0] - tPts[i][0], ddz = tPts[j][1] - tPts[i][1], l = Math.hypot(ddx, ddz) || 1;
    const s = (Math.floor(next / 110) % 2) ? 1 : -1;
    const x = tPts[i][0] - ddz / l * 2.4 * s, z = tPts[i][1] + ddx / l * 2.4 * s;
    if (Math.hypot(x - hcx, z - hcz) < 24) continue;
    addLantern(x, z, s, 0);
  }
}

// Trailhead signpost (props.js lines 90-99)
const shoreIdx = tNearestIdx(paths.trail.shore.x, paths.trail.shore.z);
const ridgeIdx = tNearestIdx(paths.trail.ridge.x, paths.trail.ridge.z);
const trailTotal = tDist[tDist.length - 1];
const fmtKm = (dm) => (dm / 1000).toFixed(1) + ' km';
const signRows = [
  ['Stillwater Lake', fmtKm(tDist[shoreIdx])],
  ['Larch Saddle', fmtKm(tDist[ridgeIdx])],
  ['Stillwater Peak', fmtKm(trailTotal)],
];
let signpost = null;
{
  const [sx, sz] = tAt(4);
  const sd = tDirAt(4);
  const px = sx - sd[1] * 1.85, pz = sz + sd[0] * 1.85;
  const ry = Math.atan2(sd[0], sd[1]) - 0.18;
  const py = renderHeight(px, pz) - 0.2;
  signpost = { x: +px.toFixed(3), y: +py.toFixed(3), z: +pz.toFixed(3), ry: +ry.toFixed(6), rows: signRows };
  propColliders.push({ x: +px.toFixed(2), z: +pz.toFixed(2), r: 0.38 });
}

// Scenic benches (lake, saddle, summit from extras.anchors.benches)
const benches = extras.anchors.benches.map((b) => {
  const y = Math.max(
    renderHeight(b.x - 0.7 * Math.cos(b.ry), b.z + 0.7 * Math.sin(b.ry)),
    renderHeight(b.x + 0.7 * Math.cos(b.ry), b.z - 0.7 * Math.sin(b.ry)),
  ) - 0.05;
  propColliders.push({ x: +b.x.toFixed(2), z: +b.z.toFixed(2), r: 0.8 });
  return { x: +b.x.toFixed(3), y: +(y + 0.46).toFixed(3), baseY: +y.toFixed(3), z: +b.z.toFixed(3), ry: +b.ry.toFixed(6) };
});

// Lakeshore pier, moored rowboat, driftwood & lakeside foreground boulders (props.js lines 103-189)
let pier = null, boat = null, driftwood = null;
{
  const L = meta.lake;
  const [lx, lz] = tAt(shoreIdx);
  const toLake = Math.atan2(L.x - lx, L.z - lz);
  const bx = lx + Math.sin(toLake) * 4, bz = lz + Math.cos(toLake) * 4;
  const fwx = Math.sin(toLake), fwz = Math.cos(toLake), rx = Math.cos(toLake), rz = -Math.sin(toLake);
  let jx = bx - rx * 14, jz = bz - rz * 14;
  for (let k = 0; k < 600 && renderHeight(jx, jz) > meta.waterLevel + 0.2; k++) { jx += fwx; jz += fwz; }
  jx -= fwx * 4; jz -= fwz * 4;
  const deckY = meta.waterLevel + 0.78, len = 36, w = 3.2;
  const pilings = [];
  for (let k = -3; k < len; k++) {
    if (k % 3 === 0 || k === len - 1) {
      const px = jx + fwx * (k + 0.5), pz = jz + fwz * (k + 0.5);
      for (const s of [-1, 1]) {
        const ppx = px + rx * s * w * 0.48, ppz = pz + rz * s * w * 0.48;
        const gy = Math.min(renderHeight(ppx, ppz), meta.waterLevel) - 1.6;
        const topOff = (k === len - 1 || k % 9 === 0) ? 0.85 : 0.45;
        pilings.push([+ppx.toFixed(2), +gy.toFixed(2), +(deckY + topOff).toFixed(2), +ppz.toFixed(2)]);
      }
    }
  }
  const lpx = jx + fwx * (len - 0.5) - rx * w * 0.48, lpz = jz + fwz * (len - 0.5) - rz * w * 0.48;
  pier = {
    x: +jx.toFixed(2), z: +jz.toFixed(2), deckY: +deckY.toFixed(3), toLake: +toLake.toFixed(6), len, w,
    pilings,
    lantern: [+lpx.toFixed(2), +deckY.toFixed(3), +lpz.toFixed(2), +(lpx + rx * 0.55).toFixed(2), +(deckY + 1.98).toFixed(3), +(lpz + rz * 0.55).toFixed(2)],
  };
  const ex = jx + fwx * (len - 3.5) + rx * 3.8, ez = jz + fwz * (len - 3.5) + rz * 3.8;
  boat = { x: +ex.toFixed(2), y: +(meta.waterLevel + 0.16).toFixed(3), z: +ez.toFixed(2), ry: +(toLake + 0.35).toFixed(6) };
  propColliders.push({ x: +ex.toFixed(2), z: +ez.toFixed(2), r: 1.8 });

  const lakeRocks = [
    [24, 16, 1.9], [28, 13, 1.2], [32, 21, 2.4], [20, 23, 1.4],
    [44, 26, 2.2], [48, 22, 1.3], [58, 16, 1.8], [38, 10, 1.3],
  ];
  lakeRocks.forEach(([f, sd, sc], i) => {
    const ox = bx + fwx * f - rx * sd, oz = bz + fwz * f - rz * sd;
    pushPropStone(ox, renderHeight(ox, oz) - sc * 0.22, oz, sc * 1.2, sc * 0.78, sc, i * 1.9, 0, 0, i % 3);
  });
  const dlx = bx + fwx * 22 - rx * 14, dlz = bz + fwz * 22 - rz * 14;
  driftwood = { x: +dlx.toFixed(2), y: +(renderHeight(dlx, dlz) + 0.16).toFixed(3), z: +dlz.toFixed(2), ry: +(toLake + 0.55).toFixed(6) };
}

// Larch Saddle cairn & verge stones (props.js lines 193-212)
{
  const L = meta.lake;
  const [rx, rz] = tAt(ridgeIdx);
  const rd = tDirAt(ridgeIdx);
  const look = Math.atan2(-(L.x - rx), -(L.z - rz)) + Math.PI;
  const cxS = rx + rd[1] * 3, czS = rz - rd[0] * 3;
  addCairn(cxS, renderHeight(cxS, czS) - 0.05, czS, 1.0, 5);
  const fxS = Math.sin(look), fzS = Math.cos(look), lxS = fzS, lzS = -fxS;
  for (const [fS, latS, sxS, syS, szS, sdS] of [
    [3.6, -2.2, 0.62, 0.34, 0.52, 411],
    [5.2, -3.4, 0.44, 0.26, 0.38, 412],
    [2.8,  2.8, 0.56, 0.32, 0.48, 413],
    [6.4,  1.6, 0.48, 0.28, 0.42, 414],
  ]) {
    const sx0 = rx - rd[1] * 3.5 + fxS * fS + lxS * latS;
    const sz0 = rz + rd[0] * 3.5 + fzS * fS + lzS * latS;
    pushPropStone(sx0, renderHeight(sx0, sz0) - syS * 0.22, sz0, sxS, syS, szS, sdS * 1.4, 0, 0, sdS % 3);
  }
}

// Summit cairns, prayer flags, boulder nest, outcrops & crown boulders (props.js lines 216-288)
const prayerFlags = [];
{
  const L = meta.lake;
  const [ex, ez] = tAt(tPts.length - 1);
  addCairn(ex, renderHeight(ex, ez) - 0.11, ez, 2.2, 11);
  const tl = Math.atan2(L.x - ex, L.z - ez);
  const fwx = Math.sin(tl), fwz = Math.cos(tl), rvx = Math.cos(tl), rvz = -Math.sin(tl);
  const bx0 = ex + fwx * 9, bz0 = ez + fwz * 9;
  const eye = renderHeight(bx0, bz0) + 1.25;
  const pLeft  = { x: bx0 + fwx * 8.4  + rvx * 5.6,  z: bz0 + fwz * 8.4  + rvz * 5.6 };
  const pRight = { x: bx0 + fwx * 15.0 - rvx * 10.6, z: bz0 + fwz * 15.0 - rvz * 10.6 };
  const pMidR  = { x: bx0 + fwx * 11.2 - rvx * 11.4, z: bz0 + fwz * 11.2 - rvz * 11.4 };
  const pBack  = { x: bx0 - fwx * 3.5  + rvx * 7.8,  z: bz0 - fwz * 3.5  + rvz * 7.8 };
  const addFlags = (pa, pb, topYA, topYB, nFlags, sag, fh0) => {
    const ya = renderHeight(pa.x, pa.z), yb = renderHeight(pb.x, pb.z);
    const poleA = Math.max(3.2, topYA - ya), poleB = Math.max(3.2, topYB - yb);
    prayerFlags.push({
      ax: +pa.x.toFixed(2), ay: +ya.toFixed(3), az: +pa.z.toFixed(2), poleA: +poleA.toFixed(3),
      bx: +pb.x.toFixed(2), by: +yb.toFixed(3), bz: +pb.z.toFixed(2), poleB: +poleB.toFixed(3),
      nFlags, sag, fh0,
    });
  };
  addFlags(pLeft, pRight, eye + 3.55, eye + 2.05, 22, 1.65, 0.44);
  addFlags(pLeft, pMidR,  eye + 2.85, eye + 1.45, 16, 1.25, 0.36);
  addFlags(pBack, pLeft,  eye + 3.20, eye + 3.45, 12, 0.95, 0.38);
  addCairn(pLeft.x, renderHeight(pLeft.x, pLeft.z) - 0.07, pLeft.z, 1.45, 7);
  addCairn(pRight.x, renderHeight(pRight.x, pRight.z) - 0.07, pRight.z, 1.4, 7);

  const ox = bx0 + fwx * 3.8 + rvx * 2.55, oz = bz0 + fwz * 3.8 + rvz * 2.55;
  const gy = renderHeight(ox, oz);
  for (const [dxR, dzR, sxR, syR, szR, sdR] of [
    [ 0.0,  0.0,  0.76, 0.52, 0.72, 304],
    [ 0.56, 0.22, 0.48, 0.38, 0.44, 306],
    [-0.48, 0.28, 0.44, 0.34, 0.42, 307],
  ]) {
    const rx0 = ox + rvx * dxR + fwx * dzR, rz0 = oz + rvz * dxR + fwz * dzR;
    pushPropStone(rx0, renderHeight(rx0, rz0) - syR * 0.18, rz0, sxR, syR, szR, sdR * 1.3, 0, 0, sdR % 3);
  }
  addCairn(ox, gy + 0.24, oz, 0.86, 6);
  for (const [latR, fwdR, sxR, syR, szR, sdR] of [
    [-2.35, 3.6, 0.92, 0.46, 0.74, 311],
    [-3.25, 4.4, 0.68, 0.42, 0.62, 312],
    [-1.55, 4.9, 0.56, 0.32, 0.50, 313],
    [-3.90, 5.4, 0.84, 0.50, 0.68, 314],
  ]) {
    const rx0 = bx0 + rvx * latR + fwx * fwdR, rz0 = bz0 + rvz * latR + fwz * fwdR;
    pushPropStone(rx0, renderHeight(rx0, rz0) - syR * 0.26, rz0, sxR, syR, szR, sdR * 1.7, 0, 0, sdR % 3);
  }
  for (let k = 0; k < 9; k++) {
    const a = tl + (k - 4) * 0.28 + Math.sin(k * 7.1) * 0.1;
    const r = 16 + (k % 3) * 4 + Math.cos(k * 3.3) * 2;
    const bx2 = ex + Math.sin(a) * r, bz2 = ez + Math.cos(a) * r;
    const s = 0.8 + ((k * 37) % 10) / 10 * 1.5;
    pushPropStone(bx2, renderHeight(bx2, bz2) - s * 0.25, bz2, s, s * 0.7, s, k * 1.7, 0, 0, k % 3);
    propColliders.push({ x: +bx2.toFixed(2), z: +bz2.toFixed(2), r: +(s * 0.8).toFixed(2) });
  }
}

// Trailside cairns (props.js lines 294-301)
{
  let next = 140;
  for (let i = 0; i < tPts.length; i++) {
    if (tDist[i] < next) continue;
    next += 150 + (i % 7) * 12;
    if (tDist[i] > trailTotal - 60) break;
    const d = tDirAt(i);
    const side = (i % 2 ? 1 : -1) * 2.3;
    const cxC = tPts[i][0] - d[1] * side, czC = tPts[i][1] + d[0] * side;
    const sc = 0.6 + (i % 3) * 0.12;
    addCairn(cxC, renderHeight(cxC, czC) - 0.05 * sc, czC, sc, 4 + (i % 3));
  }
}

// Pack rocks.bin: 40 bytes per rock (10 float32 little-endian).
// (Written after W4 woodland outcrops append their prop stones below.)

// ---------- W4 undergrowth & air (from src/world/undergrowth.js: buildLogs & LightShafts) ----------
const biomeForest = readF32(meta.biome.forest.file);
const bRes = meta.biome.res, bSize = meta.biome.size;
const sampleForest = (x, z) => {
  const ix = Math.max(0, Math.min(bRes - 1, Math.floor((x / bSize + 0.5) * bRes)));
  const iz = Math.max(0, Math.min(bRes - 1, Math.floor((z / bSize + 0.5) * bRes)));
  return biomeForest[iz * bRes + ix];
};
const sampleTrailAt = (x, z) => Math.abs(sampleGrid(mask, nRes, meta.near.size, x, z) / 32767);

const ugLogs = [];      // [x, y, z, ry, slope, len, rad, seed]
const ugStumps = [];    // [x, y, z, rad, h, ry, seed]
const ugMushrooms = []; // [x, y, z, sc, sh, capR, tilt, rot, isGolden]
{
  const rnd = mulberry32(404);
  const nearBench = (x, z) => benches.some((b) => Math.hypot(x - b.x, z - b.z) < 42);
  const addMushroomCluster = (cx, cz, count, golden = false) => {
    for (let m = 0; m < count; m++) {
      const a = rnd() * 6.28, r = 0.08 + rnd() * 0.85;
      const mx = cx + Math.cos(a) * r, mz = cz + Math.sin(a) * r;
      const my = renderHeight(mx, mz);
      const sc = 0.8 + rnd() * 0.9;
      const sh = (0.14 + rnd() * 0.14) * sc;
      const tilt = (rnd() - 0.5) * 0.22;
      const capR = (0.10 + rnd() * 0.06) * sc;
      const rot = rnd() * 6.283185;
      // Consume matching RNG steps for non-golden spots so downstream mulberry32(404) stays aligned.
      if (!golden) {
        for (let d = 0; d < 5; d++) { rnd(); rnd(); }
      }
      ugMushrooms.push([mx, my, mz, sc, sh, capR, tilt, rot, golden ? 1.0 : 0.0]);
    }
  };
  const addMossyLog = (x, z, ry, len, rad) => {
    const ex0 = Math.cos(ry) * len * 0.48, ez0 = -Math.sin(ry) * len * 0.48;
    const yC = renderHeight(x, z), yA = renderHeight(x + ex0, z + ez0), yB = renderHeight(x - ex0, z - ez0);
    const slope = Math.max(-0.26, Math.min(0.26, Math.atan2(yA - yB, len * 0.96)));
    // Seat solidly into sloping forest floor: center sits near ground so the curved trunk rises
    // proudly (+1.35*r) while the underside sinks below ground (-0.85*r) -> zero floating ends.
    const yEndLow = Math.min(yA, yB) + Math.abs(Math.sin(slope)) * len * 0.48;
    const radChunky = rad * 1.18;
    const y = Math.min(yC, 0.5 * (yA + yB), yEndLow) + radChunky * 0.18;
    const seed = rnd();
    // Match Three.js addMossyLog RNG cadence (4 shelf fungi x 2 + cluster offset x 2) without drift.
    for (let s = 0; s < 4; s++) { rnd(); rnd(); }
    const rxM = rnd() - 0.5;
    const rzM = rnd() - 0.5;
    // Offset mushroom cluster cleanly outside the trunk radius so mushrooms sit beside the mossy log.
    const sideSign = rxM >= 0 ? 1 : -1;
    const sideOff = sideSign * (radChunky + 0.48 + Math.abs(rzM) * 0.6);
    const alongOff = rxM * len * 0.55;
    const mcx = x + Math.cos(ry) * alongOff + Math.sin(ry) * sideOff;
    const mcz = z - Math.sin(ry) * alongOff + Math.cos(ry) * sideOff;
    ugLogs.push([+x.toFixed(2), +y.toFixed(3), +z.toFixed(2), +ry.toFixed(4), +slope.toFixed(4), +len.toFixed(2), +radChunky.toFixed(3), +seed.toFixed(4), +mcx.toFixed(2), +mcz.toFixed(2)]);
    addMushroomCluster(mcx, mcz, 4 + Math.floor(rnd() * 3), rnd() < 0.35);
  };
  const addMossyStump = (x, z, rad = 0.48) => {
    // Sample perimeter heights so stump root skirt sits grounded even on sloping forest banks.
    const yC = renderHeight(x, z);
    const yMin = Math.min(
      yC,
      renderHeight(x + rad, z), renderHeight(x - rad, z),
      renderHeight(x, z + rad), renderHeight(x, z - rad),
    );
    const h = 0.55 + rnd() * 0.45;
    const ry = rnd() * 6.283185;
    const seed = rnd();
    for (let r = 0; r < 4; r++) rnd();
    ugStumps.push([+x.toFixed(2), +(yMin - 0.04).toFixed(3), +z.toFixed(2), +rad.toFixed(3), +h.toFixed(3), +ry.toFixed(4), +seed.toFixed(4)]);
    addMushroomCluster(x + rad * 1.3, z + rad * 0.6, 3 + Math.floor(rnd() * 3), rnd() < 0.4);
  };

  // 1. Hero trailside woodland features strictly inside deep forest stretches (undergrowth.js lines 470-507).
  let heroPlaced = 0;
  for (let i = 10; i < tPts.length - 10; i += 6) {
    const [px, pz] = tPts[i];
    if (i < 55) continue;
    const f = sampleForest(px + 12, pz) + sampleForest(px - 12, pz) + sampleForest(px, pz);
    if (f < 2.05 || nearBench(px, pz)) continue;
    const [qx, qz] = tPts[Math.min(tPts.length - 1, i + 4)];
    const tx = qx - px, tz = qz - pz, tl = Math.hypot(tx, tz) || 1;
    const sx = -tz / tl, sz = tx / tl;
    const side = (i % 12 === 0) ? 1 : -1;
    const off = 2.0 + rnd() * 3.0;
    const x = px + sx * off * side, z = pz + sz * off * side;
    if (renderHeight(x, z) < meta.waterLevel + 1.5) continue;
    const kind = heroPlaced % 4;
    if (kind === 0) {
      addMossyLog(x, z, Math.atan2(tz, tx) + (rnd() - 0.5) * 0.9, 2.8 + rnd() * 3.0, 0.24 + rnd() * 0.14);
    } else if (kind === 1) {
      addMossyStump(x, z, 0.38 + rnd() * 0.24);
      addMushroomCluster(x - sx * side * 0.9, z - sz * side * 0.9, 4, true);
    } else if (kind === 2) {
      addMossyStump(x, z, 0.44 + rnd() * 0.22);
      addMushroomCluster(x - sx * side * 0.7, z - sz * side * 0.7, 4, false);
    } else {
      for (let b = 0; b < 3; b++) {
        const sc = (b === 0 ? 1.15 : 0.62) + rnd() * 0.75;
        const rot = rnd() * 6.28;
        const bx = x + (b === 0 ? 0 : (rnd() - 0.5) * 2.6), bz = z + (b === 0 ? 0 : (rnd() - 0.5) * 2.6);
        pushPropStone(bx, renderHeight(bx, bz) - sc * 0.24, bz, sc * 1.15, sc * 0.78, sc, rot, 0, 0, (heroPlaced + b) % 3);
      }
      addMushroomCluster(x - sx * side * 1.1, z - sz * side * 1.1, 4, false);
    }
    heroPlaced++;
    if (heroPlaced >= 110) break;
  }

  // 2. Scattered deeper-forest nurse logs (undergrowth.js lines 510-521).
  // Keep cottage yard and trailhead meadow clear (mirrors cottageClear scenery edit + i < 55 guard).
  let placed = 0;
  for (let k = 0; k < 2400 && placed < 50; k++) {
    const i = Math.floor(rnd() * tPts.length);
    const [px, pz] = tPts[i];
    const a = rnd() * 6.28, r = 7 + rnd() * 26;
    const x = px + Math.cos(a) * r, z = pz + Math.sin(a) * r;
    if (i < 55 || Math.hypot(x - hcx, z - hcz) < 48) continue;
    if (sampleForest(x, z) < 0.55 || nearBench(x, z)) continue;
    if (sampleTrailAt(x, z) > 0.01) continue;
    if (renderHeight(x, z) < meta.waterLevel + 1) continue;
    addMossyLog(x, z, rnd() * Math.PI, 2.6 + rnd() * 3.8, 0.22 + rnd() * 0.18);
    placed++;
  }
}

// Forest canopy light shafts (undergrowth.js LightShafts._buildGeo, low tier = 28 shafts).
const ugShafts = []; // [x, y, z, width, seed]
{
  const rnd = mulberry32(808);
  const count = 28;
  const heroIdx = extras.forestIdx ?? -1;
  if (heroIdx >= 0 && heroIdx < tPts.length - 18) {
    for (const [stepOff, latOff, wB] of [
      [6, -1.2, 4.2], [11, 0.8, 4.8], [16, -0.6, 5.2], [21, 1.4, 5.4], [26, 0.0, 6.0], [32, -1.0, 5.8],
    ]) {
      const idx = Math.min(tPts.length - 2, heroIdx + stepOff);
      const [px, pz] = tPts[idx], [qx, qz] = tPts[idx + 1];
      const dx = qx - px, dz = qz - pz, dl = Math.hypot(dx, dz) || 1;
      const x = px - dz / dl * latOff, z = pz + dx / dl * latOff;
      ugShafts.push([+x.toFixed(2), +renderHeight(x, z).toFixed(3), +z.toFixed(2), +wB.toFixed(2), +rnd().toFixed(4)]);
    }
  }
  for (let i = 0; i < tPts.length && ugShafts.length < count * 0.72; i += 7) {
    const [px, pz] = tPts[i];
    if (sampleForest(px + 10, pz) + sampleForest(px - 10, pz) + sampleForest(px, pz) < 1.75) continue;
    for (let b = 0; b < 2 && ugShafts.length < count * 0.72; b++) {
      const x = px + (rnd() - 0.5) * 16, z = pz + (rnd() - 0.5) * 16;
      if (sampleForest(x, z) < 0.58) continue;
      ugShafts.push([+x.toFixed(2), +renderHeight(x, z).toFixed(3), +z.toFixed(2), +(3.0 + rnd() * 3.4).toFixed(2), +rnd().toFixed(4)]);
    }
  }
  for (let k = 0; k < 2500 && ugShafts.length < count; k++) {
    const i = Math.floor(rnd() * tPts.length);
    const [px, pz] = tPts[i];
    if (sampleForest(px + 10, pz) + sampleForest(px - 10, pz) < 1.35) continue;
    const x = px + (rnd() - 0.5) * 26, z = pz + (rnd() - 0.5) * 26;
    if (sampleForest(x, z) < 0.58) continue;
    ugShafts.push([+x.toFixed(2), +renderHeight(x, z).toFixed(3), +z.toFixed(2), +(2.8 + rnd() * 3.6).toFixed(2), +rnd().toFixed(4)]);
  }
}

// Pack mushrooms.bin: 36 bytes per mushroom (9 float32 little-endian).
const mushBuf = Buffer.alloc(ugMushrooms.length * 36);
for (let i = 0; i < ugMushrooms.length; i++) {
  const rec = ugMushrooms[i];
  for (let k = 0; k < 9; k++) mushBuf.writeFloatLE(rec[k], i * 36 + k * 4);
}
console.log(`undergrowth: ${ugLogs.length} mossy logs, ${ugStumps.length} stumps, ${ugMushrooms.length} mushrooms (${(mushBuf.length / 1024).toFixed(1)} KB), ${ugShafts.length} light shafts`);

// Pack rocks.bin: 40 bytes per rock (10 float32 little-endian).
const rockBuf = Buffer.alloc(rockRecords.length * 40);
for (let i = 0; i < rockRecords.length; i++) {
  const rec = rockRecords[i];
  for (let k = 0; k < 10; k++) rockBuf.writeFloatLE(rec[k], i * 40 + k * 4);
}
console.log(`rocks: ${rCount} canonical + ${rockRecords.length - rCount} prop/cairn/woodland stones = ${rockRecords.length} total (${(rockBuf.length / 1024).toFixed(1)} KB)`);

// W3 camera poses (exact matches to capture.js / shots.json + close-up inspection views)
{
  // Cottage: exact match to shots.json cottage (poi=cottage&pitch=0.12&ang=0.5&dist=28)
  const a = Math.atan2(hfx, hfz) + 0.5;
  const cxP = hcx + Math.sin(a) * 28.0, czP = hcz + Math.cos(a) * 28.0;
  webPoses.stops.cottage = makePose('cottage', cxP, czP, yawToward(cxP, czP, hcx, hcz), 0.12);

  // Village: trailhead entrance framing signpost, fences, gate lantern & cottage together
  const vPt = tAt(10);
  const vx = vPt[0] + 5.5, vz = vPt[1] + 9.0;
  webPoses.stops.village = makePose('village', vx, vz, yawToward(vx, vz, hcx + 8, hcz + 6), 0.04);

  // Signpost close-up: 4.8 m in front of the trailhead signpost looking straight at its 3 boards
  const spFwdX = Math.sin(signpost.ry), spFwdZ = Math.cos(signpost.ry);
  const spCamX = signpost.x - spFwdX * 4.8 - spFwdZ * 0.5;
  const spCamZ = signpost.z - spFwdZ * 4.8 + spFwdX * 0.5;
  webPoses.stops.signpost = makePose('signpost', spCamX, spCamZ, yawToward(spCamX, spCamZ, signpost.x, signpost.z), 0.08);

  // Bench close-up: behind-right of the lakeside bench framing bench + pier + rowboat + shore rocks
  const b0 = benches[0];
  const bFwdX = Math.sin(b0.ry), bFwdZ = Math.cos(b0.ry);
  const bRightX = Math.cos(b0.ry), bRightZ = -Math.sin(b0.ry);
  const bcX = b0.x - bFwdX * 4.2 + bRightX * 2.4, bcZ = b0.z - bFwdZ * 4.2 + bRightZ * 2.4;
  webPoses.stops.bench_lake = makePose('bench_lake', bcX, bcZ, yawToward(bcX, bcZ, b0.x + bFwdX * 8, b0.z + bFwdZ * 8), -0.14);

  // Rock field: pick the densest multi-boulder cluster near the lakeshore / valley floor so the
  // shot frames chunky faceted moss-capped boulders up close without tree occlusion.
  {
    const L = meta.lake;
    const [lx, lz] = tAt(shoreIdx);
    const toLake = Math.atan2(L.x - lx, L.z - lz);
    const bx = lx + Math.sin(toLake) * 4, bz = lz + Math.cos(toLake) * 4;
    const fwx = Math.sin(toLake), fwz = Math.cos(toLake), rx = Math.cos(toLake), rz = -Math.sin(toLake);
    // Stand on the sunny eastern headland framing the multi-boulder cluster & shoreline pier.
    const rkX = bx + fwx * 26.0 - rx * 11.0;
    const rkZ = bz + fwz * 26.0 - rz * 11.0;
    const tx = bx + fwx * 38.0 - rx * 20.5;
    const tz = bz + fwz * 38.0 - rz * 20.5;
    const rkEye = renderHeight(rkX, rkZ) + eyeH;
    const rkTgtY = renderHeight(tx, tz) + 0.8;
    const rkPitch = Math.atan2(rkTgtY - rkEye, Math.hypot(tx - rkX, tz - rkZ)) - 0.02;
    webPoses.stops.rocks = makePose('rocks', rkX, rkZ, yawToward(rkX, rkZ, tx, tz), rkPitch);
  }

  // Saddle & Summit (bench 1 & bench 2)
  const b1 = benches[1];
  webPoses.stops.saddle = makePose('saddle', b1.x, b1.z, Math.atan2(-Math.sin(b1.ry), -Math.cos(b1.ry)), -0.02);
  const b2 = benches[2];
  webPoses.stops.summit = makePose('summit', b2.x, b2.z, Math.atan2(-Math.sin(b2.ry), -Math.cos(b2.ry)), -0.07);

  // W4 forest_floor close-up: pick a hero mossy log near forestIdx with a clean, tree-free
  // sightline from the trail, framing mossy log, toadstools/chanterelles, and painted ferns up close.
  {
    const fIdx = extras.forestIdx ?? 1451;
    const [fx0, fz0] = tAt(fIdx);
    const segClear = (ax, az, bx, bz) => {
      const dx = bx - ax, dz = bz - az, l2 = dx * dx + dz * dz || 1;
      for (const ti of keep) {
        if (kinds[ti] === 3) continue;
        const tx = field(0, ti), tz = field(2, ti);
        const t = Math.max(0, Math.min(1, ((tx - ax) * dx + (tz - az) * dz) / l2));
        const d = Math.hypot(tx - (ax + dx * t), tz - (az + dz * t));
        if (d < 2.2) return false;
      }
      return true;
    };
    const sortedLogs = [...ugLogs].sort((a, b) => Math.hypot(a[0] - fx0, a[2] - fz0) - Math.hypot(b[0] - fx0, b[2] - fz0));
    let chosen = null;
    for (const lg of sortedLogs.slice(0, 12)) {
      const mcx = lg[8] ?? lg[0], mcz = lg[9] ?? lg[2];
      // Stand ~3.8 m out on the mushroom-cluster side of the log so mushrooms sit in front of the mossy trunk.
      const sx = mcx - lg[0], sz = mcz - lg[2], sl = Math.hypot(sx, sz) || 1;
      const candX = lg[0] + (sx / sl) * 4.0, candZ = lg[2] + (sz / sl) * 4.0;
      if (segClear(candX, candZ, lg[0], lg[2])) {
        chosen = { lg, camX: candX, camZ: candZ, tx: 0.6 * lg[0] + 0.4 * mcx, tz: 0.6 * lg[2] + 0.4 * mcz };
        break;
      }
      const ti = tNearestIdx(lg[0], lg[2]);
      for (const stepOff of [-3, 3, -5, 5, 0]) {
        const [tpx, tpz] = tAt(ti + stepOff);
        const d = Math.hypot(lg[0] - tpx, lg[2] - tpz);
        if (d < 2.8 || d > 6.8) continue;
        if (segClear(tpx, tpz, lg[0], lg[2])) {
          chosen = { lg, camX: tpx, camZ: tpz, tx: lg[0], tz: lg[2] };
          break;
        }
      }
      if (chosen) break;
    }
    if (!chosen) {
      const lg = sortedLogs[0];
      const ti = tNearestIdx(lg[0], lg[2]);
      const [tpx, tpz] = tAt(Math.max(0, ti - 3));
      chosen = { lg, camX: tpx, camZ: tpz, tx: lg[0], tz: lg[2] };
    }
    const { lg, camX, camZ, tx, tz } = chosen;
    const camEye = renderHeight(camX, camZ) + eyeH;
    const tgtY = lg[1] + 0.16;
    const pitch = Math.atan2(tgtY - camEye, Math.hypot(tx - camX, tz - camZ));
    webPoses.stops.forest_floor = makePose('forest_floor', camX, camZ, yawToward(camX, camZ, tx, tz), pitch);

    // W4 shafts view: forest cathedral corridor looking slightly up along the sunbeams.
    const sPos = webPoses.stops.forest.position;
    webPoses.stops.shafts = makePose('shafts', sPos[0], sPos[2], webPoses.stops.forest.yaw, 0.11);
  }
}

const undergrowth = {
  forestIdx: extras.forestIdx ?? 1451,
  ferns: { tileSize: 16, maxCount: 768, seed: 55, lowNear: 160, lowRadius: 32 },
  logs: ugLogs,
  stumps: ugStumps,
  shafts: ugShafts,
  mushrooms: {
    file: 'mushrooms.bin',
    count: ugMushrooms.length,
    strideBytes: 36,
    layout: '9 float32 little-endian per mushroom: x, y, z, scale, stem_h, cap_r, tilt, rot, is_golden',
  },
};

const props = {
  house,
  flagstones,
  cottageBushes,
  fences,
  lanterns,
  signpost,
  benches,
  pier,
  boat,
  driftwood,
  prayerFlags,
  colliders: propColliders,
};

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
put('trees_rank.bin', rankOut);
put('colliders.bin', colBuf);
put('rocks.bin', rockBuf);
put('mushrooms.bin', mushBuf);
{
  const signpostOut = path.join(OUT, 'signpost.pngdata');
  const rs = spawnSync('gpu-run', [process.execPath, path.join(HERE, 'render_signpost.mjs'), SW, signpostOut, JSON.stringify(signRows)], { stdio: 'inherit' });
  if (rs.status !== 0) throw new Error(`render_signpost failed (exit ${rs.status})`);
  sizes['signpost.pngdata'] = fs.statSync(signpostOut).size;
}
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
    rankFile: 'trees_rank.bin', rankRule: 'u16 per tree in trees.bin order; Stillwater draws rank < density * 65536',
    subset: 'canonical trees with rank < tier density, in canonical order (WorldData.selectByRank)',
    layout: 'planar little-endian: x, y, z u24; s, rot, sx u16; tint rgb u8 interleaved; kind u8',
    decode: { world: WORLD, q24: Q24, sMax: S_MAX, sxMin: SX_MIN, tintMax: TINT_MAX },
    rule: 'v = (code / q24 - 0.5) * world for x, y, z; s = code / 65535 * sMax; rot = code / 65536 * 2 pi; sx = sxMin + code / 65535; tint = code / 255 * tintMax',
    y: 'rendered ground (near/far blend) - 0.25, bush - 0.15',
    heroOaks,
  },
  colliders: {
    file: 'colliders.bin', count: colIdx.length, cell: COL_CELL, grid: COL_G, origin: -COL_HALF,
    layout: 'u32 start[grid * grid + 1] (cell = iz * grid + ix, trees of cell c are records start[c] .. start[c + 1]); then 5-byte records: x, z u16le, s u8',
    rule: 'x = code / 16 + origin, z likewise; s = code / 8; blocks within s * 0.03 + walker radius (non-bush canonical trees, every tier)',
  },
  game,
  water,
  rocks: {
    file: 'rocks.bin',
    count: rockRecords.length,
    canonicalCount: rCount,
    strideBytes: 40,
    layout: '10 float32 little-endian per rock: x, y, z, sx, sy, sz, rot, tilt_x, tilt_z, kind_flags (kind = int & 3, prop = (int >> 4) & 1)',
  },
  signpostTex: { file: 'signpost.pngdata', width: 512, height: 384, rows: 3 },
  props,
  undergrowth,
  poses: webPoses,
  walk,
  sizes,
};
fs.writeFileSync(path.join(OUT, 'meta.json'), JSON.stringify(webMeta) + '\n');
sizes['meta.json'] = fs.statSync(path.join(OUT, 'meta.json')).size;

const total = Object.values(sizes).reduce((a, b) => a + b, 0);
console.log(`web pack: ${(total / 1e6).toFixed(2)} MB in data/valley/web (near step ${(nearStep * 1000).toFixed(2)} mm, max err ${(nearErr * 1000).toFixed(2)} mm; far step ${FAR_STEP * 100} cm, max err ${(farErr * 1000).toFixed(2)} mm)`);
for (const [k, v] of Object.entries(sizes)) console.log(`  ${k}: ${(v / 1e6).toFixed(2)} MB`);
