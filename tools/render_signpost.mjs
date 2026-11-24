// Renders Stillwater's 3-board trailhead signpost texture (props.js textTexture) into a single
// 512x384 RGBA8 PNG atlas (3 rows of 512x128: Stillwater Lake, Larch Saddle, Stillwater Peak).
// Runs in headless Chrome under gpu-run (like tools/render_atlas.mjs).
// Usage: node tools/render_signpost.mjs <stillwater path> <out.pngdata> <json rows>
import fs from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const [sw, out, rowsJson] = process.argv.slice(2);
if (!sw || !out || !rowsJson) {
  console.error('usage: node tools/render_signpost.mjs <stillwater path> <out.pngdata> <json rows>');
  process.exit(2);
}
const rows = JSON.parse(rowsJson);
const req = createRequire(path.join(sw, 'package.json'));
const puppeteer = (await import(pathToFileURL(req.resolve('puppeteer-core')).href)).default;
const { findChrome } = await import(pathToFileURL(path.join(sw, 'tools/chrome.mjs')).href);

const browser = await puppeteer.launch({ executablePath: findChrome(), headless: true, args: ['--no-sandbox'] });
try {
  const page = await browser.newPage();
  await page.setContent('<!doctype html><canvas id="c" width="512" height="384"></canvas>');
  const dataUrl = await page.evaluate((boardRows) => {
    const c = document.getElementById('c');
    const ctx = c.getContext('2d');
    const w = 512;
    const h = 128;
    // Deterministic PRNG for wood grain so the baked PNG is reproducible.
    let s = 4219;
    const rnd = () => {
      s = (s + 0x6d2b79f5) | 0;
      let t = Math.imul(s ^ (s >>> 15), 1 | s);
      t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };

    boardRows.forEach((lines, bi) => {
      const y0 = bi * h;
      ctx.save();
      ctx.translate(0, y0);
      ctx.fillStyle = '#f0ddb8';
      ctx.fillRect(0, 0, w, h);
      for (let i = 0; i < 65; i++) {
        ctx.strokeStyle = `rgba(110,74,38,${(0.05 + rnd() * 0.11).toFixed(3)})`;
        ctx.lineWidth = 1.4;
        ctx.beginPath();
        const y = rnd() * h;
        ctx.moveTo(0, y);
        ctx.bezierCurveTo(w * 0.3, y + rnd() * 5 - 2.5, w * 0.6, y + rnd() * 5 - 2.5, w, y + rnd() * 3 - 1.5);
        ctx.stroke();
      }
      ctx.strokeStyle = '#5c3b1e';
      ctx.lineWidth = 6;
      ctx.strokeRect(6, 6, w - 12, h - 12);

      ctx.textAlign = 'center';
      ctx.textBaseline = 'middle';
      ctx.shadowColor = 'rgba(255,248,232,0.55)';
      ctx.shadowBlur = 2;
      ctx.shadowOffsetY = 1;
      lines.forEach((txt, i) => {
        ctx.fillStyle = i === 0 ? '#231308' : '#4a2b13';
        ctx.font = i === 0 ? '700 46px Georgia, serif' : '700 32px Georgia, serif';
        ctx.fillText(txt, w / 2, h / 2 + (i - (lines.length - 1) / 2) * 42);
      });
      ctx.restore();
    });
    return c.toDataURL('image/png');
  }, rows);
  fs.writeFileSync(out, Buffer.from(dataUrl.split(',')[1], 'base64'));
  console.log(`signpost: wrote ${out} (${rows.length} boards)`);
} finally {
  await browser.close();
}
