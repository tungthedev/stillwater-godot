// Renders Stillwater's fluffy tree atlas (fluffyAtlas in src/world/fluffy.js) to a PNG.
// The atlas is drawn with Canvas 2D, so it needs a real browser; this runs the game's own
// module in headless Chrome. Run it under gpu-run (export_world.mjs does that for you).
// Usage: node tools/render_atlas.mjs <stillwater path> <out.png>
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const [sw, out] = process.argv.slice(2);
if (!sw || !out) {
  console.error('usage: node tools/render_atlas.mjs <stillwater path> <out.png>');
  process.exit(2);
}
const req = createRequire(path.join(sw, 'package.json'));
const puppeteer = (await import(pathToFileURL(req.resolve('puppeteer-core')).href)).default;
const { findChrome } = await import(pathToFileURL(path.join(sw, 'tools/chrome.mjs')).href);

const ORIGIN = 'http://stillwater.local';
const MIME = { '.js': 'text/javascript', '.mjs': 'text/javascript', '.html': 'text/html' };
const PAGE = `<!doctype html><script type="importmap">{"imports":{"three":"/node_modules/three/build/three.module.js"}}</script>`;

const browser = await puppeteer.launch({ executablePath: findChrome(), headless: true, args: ['--no-sandbox'] });
try {
  const page = await browser.newPage();
  await page.setRequestInterception(true);
  page.on('request', (r) => {
    const u = new URL(r.url());
    if (u.origin !== ORIGIN) return r.abort();
    if (u.pathname === '/') return r.respond({ status: 200, contentType: 'text/html', body: PAGE });
    const file = path.join(sw, decodeURIComponent(u.pathname));
    if (!file.startsWith(sw) || !fs.existsSync(file)) return r.respond({ status: 404, body: '' });
    r.respond({ status: 200, contentType: MIME[path.extname(file)] || 'application/octet-stream', body: fs.readFileSync(file) });
  });
  page.on('pageerror', (e) => console.error('page error:', e.message));
  await page.goto(ORIGIN + '/');
  const dataUrl = await page.evaluate(async () => {
    const { fluffyAtlas } = await import('/src/world/fluffy.js');
    return fluffyAtlas().image.toDataURL('image/png');
  });
  fs.writeFileSync(out, Buffer.from(dataUrl.split(',')[1], 'base64'));
  console.log(`atlas: wrote ${out}`);
} finally {
  await browser.close();
}
