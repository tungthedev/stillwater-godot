// Bakes the far-tree impostor atlas with Stillwater's own baker (bakeImpostorAtlas in
// src/world/treeImpostor.js) in GPU Chrome, from the same hero meshes and atlas size the game
// uses at the low tier, and reads it back so Godot ships the identical atlas instead of baking
// its own at load. Also writes the leaf card atlas (fluffyAtlas) the tree meshes sample.
//
// Outputs (data/trees/):
//   impostor_albedo.pngdata  RGBA8, gamma-2 albedo premultiplied by coverage (as baked)
//   impostor_normal.pngdata  RGBA8, view-space normal * 0.5 + 0.5, premultiplied by coverage
//   leaf_atlas.pngdata       RGBA8 sRGB leaf / foliage / bark atlas
//   impostors.json           per-species frames, grid, mesh list, row order
// Image row 0 is the GL bottom row, so Godot's uv (v = 0 at row 0) equals the game's uv.
//
// Usage: gpu-run node tools/bake_impostors.mjs [--stillwater <path>]
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { encodePng } from './png.mjs';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(HERE, '..');
const OUT = path.join(ROOT, 'data/trees');
const args = process.argv.slice(2);
const argVal = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const SW = path.resolve(argVal('--stillwater', '/home/hoalong/Projects/stillwater'));

const meta = JSON.parse(fs.readFileSync(path.join(ROOT, 'data/valley/meta.json'), 'utf8'));
const meshes = JSON.parse(fs.readFileSync(path.join(ROOT, 'data/valley/meshes.json'), 'utf8'));
const tier = meta.tiers.low;
const heroLod = tier.treeDetail >= 2 ? 'hero2' : 'hero1';
// Bushes have no impostor (trees.js KINDS imp = -1); the rest keep their order (imp index).
const IMP_KINDS = [0, 1, 2, 4, 5];
const heroMeshes = IMP_KINDS.map((v) => meshes.meshes.find((m) => m.kind === v && m.lod === heroLod));

const { launchBrowser } = await import(pathToFileURL(path.join(SW, 'tools/chrome.mjs')).href);
const ORIGIN = 'http://stillwater.local';
const MIME = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.html': 'text/html' };
const PAGE = `<!doctype html><script type="importmap">{"imports":{"three":"/node_modules/three/build/three.module.js"}}</script>`;

const { browser, renderer } = await launchBrowser();
console.log('renderer', renderer);
let result;
try {
  const page = await browser.newPage();
  await page.setRequestInterception(true);
  page.on('request', (r) => {
    const u = new URL(r.url());
    if (u.origin !== ORIGIN) return r.abort();
    if (u.pathname === '/') return r.respond({ status: 200, contentType: 'text/html', body: PAGE });
    const file = path.join(SW, decodeURIComponent(u.pathname));
    if (!file.startsWith(SW) || !fs.existsSync(file)) return r.respond({ status: 404, body: '' });
    r.respond({ status: 200, contentType: MIME[path.extname(file)] || 'application/octet-stream', body: fs.readFileSync(file) });
  });
  page.on('pageerror', (e) => console.error('page error:', e.message));
  page.on('console', (m) => console.log('page:', m.text()));
  await page.goto(ORIGIN + '/');
  result = await page.evaluate(async (specs, size) => {
    const THREE = await import('three');
    const fluffy = await import('/src/world/fluffy.js');
    const { bakeImpostorAtlas } = await import('/src/world/treeImpostor.js');
    const canvas = document.createElement('canvas');
    canvas.width = canvas.height = 64;
    const renderer = new THREE.WebGLRenderer({ canvas });
    const leaf = fluffy.fluffyAtlas();
    const geos = specs.map((m) => fluffy[m.generator](m.seed, m.options));
    const imp = bakeImpostorAtlas(renderer, geos, leaf, size);
    // Copy mip 0 of each baked texture into a readable RGBA8 target, texel for texel.
    const rt = new THREE.WebGLRenderTarget(size, size, { type: THREE.UnsignedByteType, format: THREE.RGBAFormat, depthBuffer: false });
    const mat = new THREE.RawShaderMaterial({
      glslVersion: THREE.GLSL3,
      uniforms: { src: { value: null } },
      vertexShader: 'in vec3 position; void main() { gl_Position = vec4(position.xy * 2.0, 0.0, 1.0); }',
      fragmentShader: 'precision highp float; uniform sampler2D src; out vec4 o; void main() { o = texelFetch(src, ivec2(gl_FragCoord.xy), 0); }',
    });
    const quad = new THREE.Mesh(new THREE.PlaneGeometry(1, 1), mat);
    const scene = new THREE.Scene();
    scene.add(quad);
    const cam = new THREE.OrthographicCamera(-1, 1, 1, -1, 0, 1);
    const read = (tex) => {
      mat.uniforms.src.value = tex;
      renderer.setRenderTarget(rt);
      renderer.render(scene, cam);
      const buf = new Uint8Array(size * size * 4);
      renderer.readRenderTargetPixels(rt, 0, 0, size, size, buf);
      renderer.setRenderTarget(null);
      return Array.from(buf);
    };
    return {
      albedo: read(imp.albedo),
      normal: read(imp.normal),
      frames: imp.frames.map((f) => [f.x, f.y, f.z, f.w]),
      grid: [imp.grid.x, imp.grid.y, imp.grid.z, imp.grid.w],
      leafPng: leaf.image.toDataURL('image/png'),
      leafSize: [leaf.image.width, leaf.image.height],
    };
  }, heroMeshes, tier.treeAtlas);
} finally {
  await browser.close();
}

fs.mkdirSync(OUT, { recursive: true });
const size = tier.treeAtlas;
const albedo = Buffer.from(result.albedo);
const normal = Buffer.from(result.normal);
let covered = 0;
for (let i = 3; i < albedo.length; i += 4) if (albedo[i] > 0) covered++;
fs.writeFileSync(path.join(OUT, 'impostor_albedo.pngdata'), encodePng(size, size, 4, albedo));
fs.writeFileSync(path.join(OUT, 'impostor_normal.pngdata'), encodePng(size, size, 4, normal));
fs.writeFileSync(path.join(OUT, 'leaf_atlas.pngdata'), Buffer.from(result.leafPng.split(',')[1], 'base64'));
const info = {
  stillwaterCommit: meta.stillwaterCommit,
  tier: 'low',
  size,
  heroLod,
  species: IMP_KINDS.map((v, i) => ({ imp: i, kind: v, mesh: heroMeshes[i].file })),
  frames: result.frames,
  grid: result.grid,
  gridRule: 'x columns, y tile size / atlas size, z pad / tile size, w max mip level (treeImpostor.js uImpGrid)',
  rows: 'image row 0 is the GL bottom row: sample with the game uv unchanged',
  leafAtlas: { file: 'leaf_atlas.pngdata', size: result.leafSize, colorSpace: 'srgb', rows: 'canvas order (top row first): v_godot = 1 - v_game' },
  coverage: covered / (size * size),
};
fs.writeFileSync(path.join(OUT, 'impostors.json'), JSON.stringify(info, null, 1) + '\n');
console.log(`impostor atlas ${size}px, ${IMP_KINDS.length} species from ${heroLod}, coverage ${(info.coverage * 100).toFixed(1)}%, grid ${info.grid.map((v) => +v.toFixed(4)).join(', ')}`);
