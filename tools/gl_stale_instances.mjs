// Runs tools/gl_stale_instances.html in GPU Chrome (Stillwater's launcher; takes the GPU lock
// when gpu-run is installed) in its three modes and prints how many samples drew this frame's
// instance data. Serve tools/ yourself:
//   BASE=http://127.0.0.1:<port>/ gpu-run node tools/gl_stale_instances.mjs [--stillwater <path>]
// On ANGLE Vulkan (Intel UHD 730) the plain mode reads stale data; nodisable and alt read fresh.
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const argVal = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const SW = path.resolve(argVal('--stillwater', '/home/hoalong/Projects/stillwater'));
const BASE = (process.env.BASE || '').replace(/\/?$/, '/');
if (!process.env.BASE) throw new Error('set BASE to a server for tools/');

const { launchBrowser } = await import(pathToFileURL(path.join(SW, 'tools/chrome.mjs')).href);
const { browser, renderer } = await launchBrowser([]);
console.log('renderer', renderer);
try {
  for (const mode of ['', 'nodisable', 'alt']) {
    const page = await browser.newPage();
    await page.goto(`${BASE}gl_stale_instances.html?${mode}`);
    await page.waitForFunction('window.__result', { timeout: 120000 });
    const r = await page.evaluate('window.__result');
    console.log(`${(mode || 'as Godot draws').padEnd(14)} fresh ${r.good} / ${r.good + r.bad}`);
    await page.close();
  }
} finally {
  await browser.close();
}
