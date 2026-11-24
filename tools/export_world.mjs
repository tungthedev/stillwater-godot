// Exports Stillwater's baked valley world into plain files the Godot spike can load.
// Decoding goes through the game's own loader code (maybeGunzip + decodeBakedWorld), so every
// value here is what the game holds in memory after loadWorld(). File layouts are described in
// the generated data/valley/meta.json and meshes.json.
// Usage: node tools/export_world.mjs [--stillwater <path>] [--skip-atlas]
import fs from 'node:fs';
import path from 'node:path';
import { execFileSync, spawnSync } from 'node:child_process';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const OUT = path.join(ROOT, 'data/valley');

const args = process.argv.slice(2);
const argVal = (name, def) => {
  const i = args.indexOf(name);
  return i >= 0 ? args[i + 1] : def;
};
const SW = path.resolve(argVal('--stillwater', '/home/hoalong/Projects/stillwater'));
const SKIP_ATLAS = args.includes('--skip-atlas');

const swImport = (rel) => import(pathToFileURL(path.join(SW, rel)).href);
const { decodeBakedWorld, maybeGunzip, selectByRank } = await swImport('src/world/worldData.js');
const { HeightField } = await swImport('src/world/heightmap.js');
const { VALLEY } = await swImport('src/content/valley.js');
const { QUALITY, TIER_NAMES } = await swImport('src/engine/quality.js');
const fluffy = await swImport('src/world/fluffy.js');

const git = (...a) => execFileSync('git', ['-C', SW, ...a], { encoding: 'utf8' }).trim();
const commit = git('rev-parse', 'HEAD');
const dirtyWorld = git('status', '--porcelain', '--', 'public/worlds', 'src/world', 'src/content', 'src/engine/quality.js', 'src/dev', 'src/player.js');

// ---------- decode exactly as loadWorld() does ----------
const worldDir = path.join(SW, 'public/worlds', VALLEY.id);
const manifest = JSON.parse(fs.readFileSync(path.join(worldDir, 'manifest.json'), 'utf8'));
const buffers = {};
for (const entry of Object.values(manifest.files)) {
  buffers[entry.path] = await maybeGunzip(new Uint8Array(fs.readFileSync(path.join(worldDir, entry.path))));
}
const world = decodeBakedWorld(manifest, buffers, VALLEY);
if (world.hash !== manifest.worldHash) {
  throw new Error(`decoded world hash ${world.hash} != manifest ${manifest.worldHash}`);
}
const R = VALLEY;
const farHf = new HeightField(world.farHeights, null, R.farRes, R.farSize);

// --skip-atlas keeps the previously rendered atlas; everything else is rewritten from scratch.
const atlasPath = path.join(OUT, 'atlas.png');
const keptAtlas = SKIP_ATLAS && fs.existsSync(atlasPath) ? fs.readFileSync(atlasPath) : null;
fs.rmSync(OUT, { recursive: true, force: true });
fs.mkdirSync(path.join(OUT, 'meshes'), { recursive: true });
const sizes = {};
const write = (rel, data) => {
  const buf = typeof data === 'string' ? Buffer.from(data) : Buffer.from(data.buffer, data.byteOffset, data.byteLength);
  fs.writeFileSync(path.join(OUT, rel), buf);
  sizes[rel] = buf.length;
};
const json = (rel, obj) => write(rel, JSON.stringify(obj, null, 1) + '\n');
const f32 = (arr) => Float32Array.from(arr);

// ---------- heights, trail mask, biome ----------
write('height_near.f32', f32(world.heights));
write('height_far.f32', f32(world.farHeights));
// Decoded mask values are exactly q / 32767, so int16 keeps them bit-exact at half the size.
const mask = new Int16Array(world.mask.length);
for (let i = 0; i < mask.length; i++) mask[i] = Math.round(world.mask[i] * 32767);
write('trail_mask.i16', mask);

const B = world.biome;
const N = B.res * B.res;
const biomeRgb = new Uint8Array(N * 3);
for (let i = 0; i < N; i++) {
  biomeRgb[i * 3] = B.data[i * 4];
  biomeRgb[i * 3 + 1] = B.data[i * 4 + 1];
  biomeRgb[i * 3 + 2] = B.data[i * 4 + 2];
}
write('biome_rgb.u8', biomeRgb);
write('biome_forest.f32', f32(B.forest));

// ---------- placements ----------
const trees = world.placements.trees;
const TREE_FIELDS = ['x', 'y', 'z', 's', 'rot', 'sx', 'tint_r', 'tint_g', 'tint_b'];
const tn = trees.length;
const treeF = new Float32Array(tn * TREE_FIELDS.length);
const treeRank = new Uint16Array(tn);
const treeKind = new Uint8Array(tn);
const treeSalt = new Uint8Array(tn);
for (let i = 0; i < tn; i++) {
  const t = trees[i];
  const vals = [t.x, t.y, t.z, t.s, t.rot, t.sx, t.tint[0], t.tint[1], t.tint[2]];
  for (let f = 0; f < vals.length; f++) treeF[f * tn + i] = vals[f];
  const r16 = t.rank * 65536;
  if (!Number.isInteger(r16) || r16 < 0 || r16 > 65535) throw new Error(`tree ${i} rank ${t.rank} is not a u16/65536 value`);
  treeRank[i] = r16;
  treeKind[i] = t.v;
  treeSalt[i] = t.salt;
}
write('trees.f32', treeF);
write('trees_rank.u16', treeRank);
write('trees_kind.u8', treeKind);
write('trees_salt.u8', treeSalt);

const rocks = world.placements.rocks;
const ROCK_FIELDS = ['x', 'y', 'z', 's', 'rot', 'tilt_x', 'tilt_z'];
const rn = rocks.length;
const rockF = new Float32Array(rn * ROCK_FIELDS.length);
const rockRank = new Uint16Array(rn);
const rockKind = new Uint8Array(rn);
for (let i = 0; i < rn; i++) {
  const r = rocks[i];
  const vals = [r.x, r.y, r.z, r.s, r.rot, r.tilt[0], r.tilt[1]];
  for (let f = 0; f < vals.length; f++) rockF[f * rn + i] = vals[f];
  const r16 = r.rank * 65536;
  if (!Number.isInteger(r16)) throw new Error(`rock ${i} rank ${r.rank} is not a u16/65536 value`);
  rockRank[i] = r16;
  rockKind[i] = r.v;
}
write('rocks.f32', rockF);
write('rocks_rank.u16', rockRank);
write('rocks_kind.u8', rockKind);

const heroOaks = world.placements.heroOaks.map(([x, z, s, rot, tint]) => ({ x, z, s, rot, tint }));
json('extras.json', { heroOaks, anchors: world.anchors, forestIdx: world.forestIdx });

// ---------- paths ----------
json('paths.json', {
  trail: {
    points: world.trail.points,
    heights: world.trail.heights,
    dist: world.trail.dist,
    shore: world.trail.shore,
    ridge: world.trail.ridge,
  },
  stream: world.streamPlan
    ? { points: world.streamPlan.points, heights: world.streamPlan.heights, brink: world.streamPlan.brink ?? null }
    : null,
});

// ---------- tiers and expected rank-selection counts ----------
const tiers = {};
for (const name of TIER_NAMES) {
  const q = QUALITY[name];
  const td = q.trees ?? 1;
  const rd = q.rocks ?? 1;
  tiers[name] = {
    trees: td,
    treeDetail: q.treeDetail,
    treeHi: q.treeHi,
    treeLo: q.treeLo,
    rocks: rd,
    expectedTrees: selectByRank(trees, td).length,
    expectedRocks: selectByRank(rocks, rd).length,
  };
}

// ---------- samples: game CPU height, far grid, and the GPU near/far blend ----------
const NEAR_HALF = R.size * 0.5;
const smoothstep = (a, b, x) => {
  const t = Math.min(Math.max((x - a) / (b - a), 0), 1);
  return t * t * (3 - 2 * t);
};
// Mirrors w_height() in src/glsl/common.js: near and far blend over a square band measured by max(|x|, |z|).
const renderHeight = (x, z) => {
  const t = smoothstep(NEAR_HALF - 220, NEAR_HALF - 20, Math.max(Math.abs(x), Math.abs(z)));
  if (t <= 0) return world.height(x, z);
  if (t >= 1) return farHf.height(x, z);
  return world.height(x, z) * (1 - t) + farHf.height(x, z) * t;
};

// ---------- bench poses (replicated from capture.js applyCaptureParams + player.update) ----------
const EYE = 1.68;
const BENCH_TIME = 16.0;
const pts = world.trail.points;
const poseAt = (name, query, idx, ahead, pitch) => {
  const p = pts[idx];
  const q = pts[Math.min(pts.length - 1, idx + ahead)];
  const yaw = Math.atan2(-(q[0] - p[0]), -(q[1] - p[1]));
  const pos = { x: p[0], z: p[1] };
  const g0 = world.height(pos.x, pos.z);
  world.collideTrees(pos, 0.35);
  world.collideRocks(pos, g0, 0.35);
  const pushed = Math.hypot(pos.x - p[0], pos.z - p[1]);
  const ground = world.height(pos.x, pos.z);
  const eyeY = ground + EYE;
  const lookDist = 10;
  const look = {
    x: pos.x - Math.sin(yaw) * Math.cos(pitch) * lookDist,
    y: eyeY + Math.sin(pitch) * lookDist,
    z: pos.z - Math.cos(yaw) * Math.cos(pitch) * lookDist,
  };
  const house = world.anchors.house;
  const nearestBench = Math.min(...world.anchors.benches.map((b) => Math.hypot(b.x - pos.x, b.z - pos.z)));
  return {
    name,
    query: `${query}&time=${BENCH_TIME}`,
    trailIndex: idx,
    position: [pos.x, eyeY, pos.z],
    ground,
    yaw,
    pitch,
    roll: 0,
    eulerOrder: 'YXZ',
    lookAt: [look.x, look.y, look.z],
    collisionPushM: pushed,
    distToHouseM: house ? Math.hypot(house.x - pos.x, house.z - pos.z) : null,
    distToNearestBenchM: nearestBench,
  };
};
const poses = {
  note: 'Replicated in Node from capture.js applyCaptureParams + player.update (not read back from a browser run). Camera y also gets breath = sin(t*1.6)*0.008 m per frame, ignored here.',
  timeOfDayHours: BENCH_TIME,
  eyeHeight: EYE,
  fovVerticalDeg: 60,
  near: 0.25,
  far: 60000,
  convention: 'three.js and Godot are both right-handed, Y up, camera looks down -Z. rotation = (pitch, yaw, roll) applied in YXZ order, which is Godot Camera3D default rotation_order.',
  stops: {
    // trailf=0: trail point 0 looking at point 8; pitch stays at placeAtStart's -0.02.
    trailhead: poseAt('trailhead', 'trailf=0', 0, 8, -0.02),
    // poi=forest&pitch=0.03: trail point forestIdx looking at forestIdx + 10.
    forest: poseAt('forest', 'poi=forest&pitch=0.03', world.forestIdx, 10, 0.03),
  },
};

const sampleList = [];
const addSample = (label, x, z) => sampleList.push({
  label, x, z,
  h: world.height(x, z),
  hFar: farHf.height(x, z),
  hRender: renderHeight(x, z),
  trail: world.trailAt(x, z),
  ...world.biomeAt(x, z),
});
addSample('trailhead', pts[0][0], pts[0][1]);
addSample('trailhead pose', poses.stops.trailhead.position[0], poses.stops.trailhead.position[2]);
addSample('forest pose', poses.stops.forest.position[0], poses.stops.forest.position[2]);
addSample('forest +3m', poses.stops.forest.position[0] + 3.37, poses.stops.forest.position[2] - 2.81);
addSample('start', R.start.x + 0.31, R.start.z + 0.77);
addSample('lake', R.lake.x + 0.5, R.lake.z + 0.25);
addSample('summit', R.summit.x + 0.13, R.summit.z - 0.41);
addSample('house', world.anchors.house.x, world.anchors.house.z);
addSample('bench 1', world.anchors.benches[1].x, world.anchors.benches[1].z);
// Steepest of a coarse scan, so a half-texel offset shows up as metres of error.
let steep = null;
for (let z = -1700; z <= 1700; z += 37.3) {
  for (let x = -1700; x <= 1700; x += 37.3) {
    const n = world.normal(x, z, 2);
    if (!steep || n.y < steep.ny) steep = { x, z, ny: n.y };
  }
}
addSample('steepest scan', steep.x + 0.73, steep.z + 1.19);
let seed = 12345;
const rnd = () => ((seed = (seed * 1103515245 + 12345) >>> 0) / 4294967296);
for (let k = 0; k < 3; k++) addSample(`random ${k}`, rnd() * 3600 - 1800, rnd() * 3600 - 1800);
addSample('blend band 1900', 1900.37, 123.41);
addSample('blend band corner', -1950.7, 1700.2);
addSample('blend band 2010', 2010.3, -2015.9);
addSample('far only', 2500.5, 100.25);
addSample('far mountains', -6000.3, -5200.7);
json('samples.json', { note: 'h = WorldData.height (near map only, clamped); hFar = far map; hRender = GPU w_height blend.', samples: sampleList });
json('poses.json', poses);

// ---------- tree meshes ----------
// Mirrors KINDS in src/world/trees.js (index = placement kind v). hi is drawn near when
// treeDetail >= 2, mid near when treeDetail is 1 (low tier); lo is the far 3D band.
const KINDS = [
  { name: 'oak', bb: 0, hi: ['fluffyBroadleaf', 11, { kind: 'oak', color: [0.13, 0.39, 0.075] }], mid: ['fluffyBroadleaf', 11, { kind: 'oak', color: [0.13, 0.39, 0.075], lod: 1 }], lo: ['fluffyBroadleaf', 11, { kind: 'oak', color: [0.13, 0.39, 0.075], lod: 0 }] },
  { name: 'round', bb: 0, hi: ['fluffyBroadleaf', 23, { kind: 'round', color: [0.16, 0.42, 0.09] }], mid: ['fluffyBroadleaf', 23, { kind: 'round', color: [0.16, 0.42, 0.09], lod: 1 }], lo: ['fluffyBroadleaf', 23, { kind: 'round', color: [0.18, 0.43, 0.09], lod: 0 }] },
  { name: 'pine', bb: 1, hi: ['fluffyPine', 37, { color: [0.065, 0.24, 0.10] }], mid: ['fluffyPine', 37, { color: [0.065, 0.24, 0.10], lod: 1 }], lo: ['fluffyPine', 37, { color: [0.065, 0.24, 0.10], lod: 0 }] },
  { name: 'bush', bb: 0, hi: ['fluffyBush', 61, {}], mid: ['fluffyBush', 61, { lod: 1 }], lo: ['fluffyBush', 61, { lod: 0 }] },
  { name: 'poplar', bb: 2, hi: ['fluffyBroadleaf', 51, { kind: 'poplar', color: [0.18, 0.46, 0.10], bark: [0.76, 0.73, 0.67] }], mid: ['fluffyBroadleaf', 51, { kind: 'poplar', color: [0.18, 0.46, 0.10], bark: [0.76, 0.73, 0.67], lod: 1 }], lo: ['fluffyBroadleaf', 51, { kind: 'poplar', color: [0.18, 0.46, 0.10], lod: 0 }] },
  { name: 'larch', bb: 3, hi: ['fluffyLarch', 73, { color: [0.23, 0.38, 0.11], bark: [0.30, 0.20, 0.13] }], mid: ['fluffyLarch', 73, { color: [0.23, 0.38, 0.11], bark: [0.30, 0.20, 0.13], lod: 1 }], lo: ['fluffyLarch', 73, { color: [0.23, 0.38, 0.11], lod: 0 }] },
];
const HERO = ['fluffyBroadleaf', 121, { kind: 'oak', color: [0.12, 0.37, 0.072] }];
const ATTRS = [['position', 'position', 3], ['normal', 'normal', 3], ['uv', 'uv', 2], ['color', 'color', 3], ['crown', 'aCrown', 3]];
const meshes = [];
const exportMesh = (file, kindIndex, lod, [fn, seed, opts]) => {
  const g = fluffy[fn](seed, opts);
  const vc = g.attributes.position.count;
  const parts = [];
  const layout = {};
  let off = 0;
  for (const [key, attr, comps] of ATTRS) {
    const a = g.attributes[attr];
    if (a.itemSize !== comps || a.count !== vc) throw new Error(`${file}: unexpected ${attr} layout`);
    const data = Float32Array.from(a.array);
    layout[key] = { offset: off, components: comps, type: 'f32' };
    parts.push(Buffer.from(data.buffer));
    off += data.byteLength;
  }
  const idx = Uint32Array.from(g.index.array);
  layout.index = { offset: off, count: idx.length, type: 'u32' };
  parts.push(Buffer.from(idx.buffer));
  write(`meshes/${file}.bin`, Buffer.concat(parts));
  g.computeBoundingBox();
  meshes.push({
    file: `meshes/${file}.bin`,
    kind: kindIndex,
    lod,
    generator: fn,
    seed,
    options: opts,
    vertexCount: vc,
    triangleCount: idx.length / 3,
    layout,
    bounds: { min: g.boundingBox.min.toArray(), max: g.boundingBox.max.toArray() },
  });
};
KINDS.forEach((k, v) => {
  for (const lod of ['hi', 'mid', 'lo']) exportMesh(`${k.name}_${lod}`, v, lod, k[lod]);
});
exportMesh('hero_oak', 0, 'hero', HERO);
json('meshes.json', {
  note: 'Planar float32 attributes then u32 indices; offsets in bytes. Geometry is in three.js convention: counter-clockwise front faces, UV v = 0 at the bottom of atlas.png (CanvasTexture flipY). Vertex colours are linear; the atlas is sRGB.',
  kinds: KINDS.map((k, v) => ({ v, name: k.name, billboardKind: k.bb })),
  atlas: { file: 'atlas.png', colorSpace: 'srgb', layout: 'u [0, 0.74] leaf cluster card, u [0.78, 0.88] solid foliage, u [0.9, 1] bark' },
  material: { alphaTest: 0.44, alphaToCoverage: true, doubleSided: true, barkWhen: 'uv.x > 0.895 or crown.z < 0.5' },
  meshes,
});

// ---------- atlas (Canvas 2D, needs headless Chrome under gpu-run) ----------
if (keptAtlas) {
  write('atlas.png', keptAtlas);
} else if (!SKIP_ATLAS) {
  const script = path.join(HERE, 'render_atlas.mjs');
  const r = spawnSync('gpu-run', [process.execPath, script, SW, atlasPath], { stdio: 'inherit' });
  if (r.status !== 0) throw new Error(`render_atlas failed (exit ${r.status}); rerun with --skip-atlas to keep the rest`);
  sizes['atlas.png'] = fs.statSync(atlasPath).size;
}

// ---------- meta ----------
json('meta.json', {
  format: 1,
  region: R.id,
  worldHash: world.hash,
  stillwaterCommit: commit,
  stillwaterDirty: dirtyWorld ? dirtyWorld.split('\n') : [],
  units: 'metres; world origin at the centre of both height grids; +x east, +z south (three.js), y up',
  near: {
    file: 'height_near.f32', type: 'f32le', size: R.size, res: R.res,
    layout: 'row-major, index = iz * res + ix; texel (ix, iz) centre is at x = (ix + 0.5) / res * size - size / 2 (same for z)',
    sample: 'bilinear: fx = (x / size + 0.5) * res - 0.5, clamped to [0, res - 1.001] (HeightField._sample)',
  },
  far: { file: 'height_far.f32', type: 'f32le', size: R.farSize, res: R.farRes, layout: 'same as near' },
  heightRules: {
    gameplay: 'WorldData.height(x, z) samples the near map only, clamped at its edge; tree y and player eye use it',
    render: 'GPU w_height: t = smoothstep(size/2 - 220, size/2 - 20, max(|x|, |z|)) = smoothstep(1828, 2028, ...); height = mix(near, far, t)',
    blendStart: NEAR_HALF - 220,
    blendEnd: NEAR_HALF - 20,
  },
  trailMask: { file: 'trail_mask.i16', type: 'i16le', res: R.res, scale: 1 / 32767, layout: 'same grid as near', use: 'trailAt = |bilinear(mask)|, isPath = bilinear(mask) > 0.4' },
  biome: {
    res: B.res, size: R.size,
    rgb: { file: 'biome_rgb.u8', layout: 'row-major, 3 bytes per texel: r forest (u8 copy), g flowers, b meadow; value / 255' },
    forest: { file: 'biome_forest.f32', type: 'f32le', range: [manifest.files.biome.forestMin, manifest.files.biome.forestMax] },
    sample: 'nearest: ix = clamp(floor((x / size + 0.5) * res), 0, res - 1), same for z',
  },
  trees: {
    count: tn,
    file: 'trees.f32',
    layout: 'planar f32le: field f of tree i at index f * count + i',
    fields: TREE_FIELDS,
    rank: { file: 'trees_rank.u16', type: 'u16le', rule: 'rank = value / 65536; tier keeps rank < density, i.e. value < density * 65536' },
    kind: { file: 'trees_kind.u8', values: KINDS.map((k) => k.name), bush: 'kind 3' },
    salt: { file: 'trees_salt.u8' },
    instance: 'scale (s * sx, s, s * sx), rotate rot about +Y, translate (x, y, z); y = WorldData.height - 0.25 (bush - 0.15)',
    collision: 'non-bush trees block within s * 0.03 + 0.4 m (WorldData.collideTrees), full canonical list on every tier',
  },
  rocks: {
    count: rn,
    file: 'rocks.f32',
    layout: 'planar f32le, as trees',
    fields: ROCK_FIELDS,
    rank: { file: 'rocks_rank.u16', type: 'u16le', rule: 'as trees, density = tier.rocks' },
    kind: { file: 'rocks_kind.u8' },
  },
  heroOaks: { file: 'extras.json', count: heroOaks.length, instance: 'y = WorldData.height - 0.35, scale (s * 0.94, s, s * 0.94), mesh hero_oak' },
  tiers,
  waterLevel: R.waterLevel,
  lake: R.lake,
  valley: R.valley,
  summit: R.summit,
  start: R.start,
  boundary: { value: R.boundary, rule: 'soft square: if max(|x|, |z|) > boundary, scale (x, z) by boundary / max' },
  files: {
    paths: 'paths.json', extras: 'extras.json', samples: 'samples.json', poses: 'poses.json', meshes: 'meshes.json',
  },
  sizes,
});

const total = Object.values(sizes).reduce((a, b) => a + b, 0);
console.log(`exported ${Object.keys(sizes).length} files, ${(total / 1e6).toFixed(1)} MB, hash ${world.hash}, commit ${commit.slice(0, 7)}`);
for (const [name, t] of Object.entries(tiers)) console.log(`  ${name}: trees ${t.trees} -> ${t.expectedTrees}, rocks ${t.rocks} -> ${t.expectedRocks}`);
for (const s of Object.values(poses.stops)) console.log(`  pose ${s.name}: pos ${s.position.map((v) => v.toFixed(2)).join(', ')} yaw ${s.yaw.toFixed(4)} push ${s.collisionPushM.toFixed(3)} m house ${s.distToHouseM?.toFixed(1)} m bench ${s.distToNearestBenchM.toFixed(1)} m`);
