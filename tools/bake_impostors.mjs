// Bakes the far-tree impostor atlas with Stillwater's own baker (bakeImpostorAtlas in
// src/world/treeImpostor.js) in GPU Chrome, from the same near-mid (mid1) meshes and atlas size
// Stillwater main uses at the low tier, and reads it back so Godot ships the identical atlas.
// Also writes the leaf card atlas (fluffyAtlas) with dilated transparent-border RGB so mipmaps
// and linear filtering never pull dark fringes onto leaf card cutouts.
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
// Stillwater trees.js bakes impostors from midGeoFine (mid1: near-mid fringe crowns).
const bakeLod = 'mid1';
// Bushes have no impostor (trees.js KINDS imp = -1); the rest keep their order (imp index).
const IMP_KINDS = [0, 1, 2, 4, 5];
const bakeMeshes = IMP_KINDS.map((v) => meshes.meshes.find((m) => m.kind === v && m.lod === bakeLod));
if (bakeMeshes.some((m) => !m)) throw new Error(`missing ${bakeLod} mesh in data/valley/meshes.json`);

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
    const leafCanvas = fluffy.fluffyAtlas();
    // Dilate opaque leaf-edge RGB outward into the transparent background of the card region
    // (u < 0.76) so bilinear filtering and mipmaps never pull dark grey into leaf cutout edges.
    // Keep the dilated RGBA buffer directly (Canvas2D putImageData premultiplies and zeroes RGB
    // where alpha == 0), and wrap it in a DataTexture for the impostor baker too.
    let leafRgba;
    let leafW, leafH;
    let leaf;
    {
      const c = leafCanvas.image;
      const W = c.width, H = c.height;
      leafW = W; leafH = H;
      const cardW = Math.floor(W * 0.76);
      const ctx = c.getContext('2d');
      const img = ctx.getImageData(0, 0, W, H);
      const d = img.data;
      const valid = new Uint8Array(cardW * H);
      for (let y = 0; y < H; y++) {
        for (let x = 0; x < cardW; x++) {
          const o = (y * W + x) * 4;
          if (d[o + 3] <= 6) d[o + 3] = 0;
          if (d[o + 3] >= 120) valid[y * cardW + x] = 1;
        }
      }
      const nextValid = new Uint8Array(valid);
      const tmp = new Uint8Array(cardW * H * 3);
      for (let pass = 0; pass < 24; pass++) {
        let changed = 0;
        for (let y = 0; y < H; y++) {
          for (let x = 0; x < cardW; x++) {
            const idx = y * cardW + x;
            if (valid[idx]) continue;
            let sr = 0, sg = 0, sb = 0, cnt = 0;
            for (let dy = -1; dy <= 1; dy++) {
              const ny = y + dy;
              if (ny < 0 || ny >= H) continue;
              for (let dx = -1; dx <= 1; dx++) {
                const nx = x + dx;
                if (nx < 0 || nx >= cardW) continue;
                if (valid[ny * cardW + nx]) {
                  const no = (ny * W + nx) * 4;
                  sr += d[no]; sg += d[no + 1]; sb += d[no + 2]; cnt++;
                }
              }
            }
            if (cnt > 0) {
              tmp[idx * 3] = Math.round(sr / cnt);
              tmp[idx * 3 + 1] = Math.round(sg / cnt);
              tmp[idx * 3 + 2] = Math.round(sb / cnt);
              nextValid[idx] = 1;
              changed++;
            }
          }
        }
        if (!changed) break;
        for (let y = 0; y < H; y++) {
          for (let x = 0; x < cardW; x++) {
            const idx = y * cardW + x;
            if (!valid[idx] && nextValid[idx]) {
              const o = (y * W + x) * 4;
              d[o] = tmp[idx * 3];
              d[o + 1] = tmp[idx * 3 + 1];
              d[o + 2] = tmp[idx * 3 + 2];
              valid[idx] = 1;
            }
          }
        }
      }
      // Fill any remaining distant transparent texels with bright outer-leaf tone.
      for (let y = 0; y < H; y++) {
        for (let x = 0; x < cardW; x++) {
          if (!valid[y * cardW + x]) {
            const o = (y * W + x) * 4;
            d[o] = 236; d[o + 1] = 244; d[o + 2] = 224;
          }
        }
      }
      leafRgba = Array.from(d);
      leaf = new THREE.DataTexture(new Uint8Array(d), W, H, THREE.RGBAFormat, THREE.UnsignedByteType);
      leaf.colorSpace = THREE.SRGBColorSpace;
      leaf.flipY = true;
      leaf.generateMipmaps = true;
      leaf.minFilter = THREE.LinearMipmapLinearFilter;
      leaf.magFilter = THREE.LinearFilter;
      leaf.needsUpdate = true;
    }
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
      leafRgba,
      leafSize: [leafW, leafH],
    };
  }, bakeMeshes, tier.treeAtlas);
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
// Encode leaf_atlas directly from RGBA ImageData so transparent pixels preserve their dilated RGB
// (Canvas toDataURL premultiplies alpha and zeroes RGB where alpha == 0).
fs.writeFileSync(path.join(OUT, 'leaf_atlas.pngdata'), encodePng(result.leafSize[0], result.leafSize[1], 4, Buffer.from(result.leafRgba)));
const info = {
  stillwaterCommit: meta.stillwaterCommit,
  tier: 'low',
  size,
  bakeLod,
  species: IMP_KINDS.map((v, i) => ({ imp: i, kind: v, mesh: bakeMeshes[i].file })),
  frames: result.frames,
  grid: result.grid,
  gridRule: 'x columns, y tile size / atlas size, z pad / tile size, w max mip level (treeImpostor.js uImpGrid)',
  rows: 'image row 0 is the GL bottom row: sample with the game uv unchanged',
  leafAtlas: { file: 'leaf_atlas.pngdata', size: result.leafSize, colorSpace: 'srgb', rows: 'canvas order (top row first): v_godot = 1 - v_game' },
  coverage: covered / (size * size),
};
fs.writeFileSync(path.join(OUT, 'impostors.json'), JSON.stringify(info, null, 1) + '\n');
console.log(`impostor atlas ${size}px, ${IMP_KINDS.length} species from ${bakeLod}, coverage ${(info.coverage * 100).toFixed(1)}%, grid ${info.grid.map((v) => +v.toFixed(4)).join(', ')}`);
