// Records a Chrome trace of the Web build at one pose and prints where the page's main thread
// spends each frame: the time inside WebGL calls that wait on the GPU process (Chrome's command
// buffer flow control and sync IPC) versus everything else. That tells real main-thread work from
// main-thread time that is GPU time in disguise, which the in-game timer cannot do.
//   BASE=http://127.0.0.1:<port>/ gpu-run node --max-old-space-size=6000 tools/trace_web.mjs
//     [--view phone|desk] [--pose trailhead] [--query '&res=40'] [--secs 2] [--out trace.json] [--vsync]
//     [--stillwater <path>]   (a trace is hundreds of MB; node's default heap is too small)
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const argVal = (name, def) => { const i = args.indexOf(name); return i >= 0 ? args[i + 1] : def; };
const SW = path.resolve(argVal('--stillwater', '/home/hoalong/Projects/stillwater'));
const VIEWS = {
  desk: { width: 675, height: 1130, deviceScaleFactor: 1 },
  phone: { width: 390, height: 844, deviceScaleFactor: 3, isMobile: true, hasTouch: true },
};
const VIEW = VIEWS[argVal('--view', 'phone')];
const POSE = argVal('--pose', 'trailhead');
const QUERY = argVal('--query', '');
const SECS = Number(argVal('--secs', '2'));
const OUT = argVal('--out', '');
const BASE = (process.env.BASE || '').replace(/\/?$/, '/');
if (!process.env.BASE) throw new Error('set BASE to the server for build/web');

const { launchBrowser } = await import(pathToFileURL(path.join(SW, 'tools/chrome.mjs')).href);
const { browser, renderer } = await launchBrowser(args.includes('--vsync') ? [] : ['--disable-gpu-vsync', '--disable-frame-rate-limit']);
console.log('renderer', renderer);
let events;
try {
  const page = await browser.newPage();
  const logs = [];
  page.on('console', (m) => logs.push(m.text()));
  await page.setViewport(VIEW);
  await page.goto(`${BASE}index.html?pose=${POSE}&noui${QUERY}`, { waitUntil: 'load', timeout: 180000 });
  const t0 = Date.now();
  while (!logs.some((l) => l.startsWith('BUILD'))) {
    if (Date.now() - t0 > 120000) throw new Error('no BUILD line');
    await new Promise((r) => setTimeout(r, 200));
  }
  console.log(logs.find((l) => l.startsWith('BUILD')));
  await new Promise((r) => setTimeout(r, 5000));
  await page.tracing.start({
    categories: ['toplevel', 'gpu', 'devtools.timeline', 'blink'],
  });
  await new Promise((r) => setTimeout(r, SECS * 1000));
  const buf = await page.tracing.stop();
  const text = Buffer.from(buf).toString();
  const trace = JSON.parse(text);
  events = trace.traceEvents || trace;
  if (OUT) fs.writeFileSync(OUT, text);
} finally {
  await browser.close();
}

// Threads by name.
const names = new Map();
for (const e of events) if (e.ph === 'M' && e.name === 'thread_name') names.set(`${e.pid}:${e.tid}`, e.args.name);
const mainKeys = [...names].filter(([, n]) => n === 'CrRendererMain').map(([k]) => k);
// The busiest renderer main thread is the page's.
const byThread = new Map();
for (const e of events) {
  const k = `${e.pid}:${e.tid}`;
  if (!byThread.has(k)) byThread.set(k, []);
  byThread.get(k).push(e);
}
const main = mainKeys.map((k) => [k, byThread.get(k) || []]).sort((a, b) => b[1].length - a[1].length)[0];
if (!main) throw new Error('no renderer main thread in the trace');
const evs = main[1].filter((e) => e.ph === 'X' && e.dur);
// Frames: the rAF callbacks.
const frames = evs.filter((e) => e.name === 'FireAnimationFrame');
const span = frames.length > 1 ? (frames[frames.length - 1].ts - frames[0].ts) / 1000 : SECS * 1000;
const total = (pred) => evs.filter(pred).reduce((s, e) => s + e.dur, 0) / 1000;
const agg = new Map();
for (const e of evs) {
  const a = agg.get(e.name) || { n: 0, ms: 0 };
  a.n += 1;
  a.ms += e.dur / 1000;
  agg.set(e.name, a);
}
const n = Math.max(1, frames.length - 1);
console.log(`main thread ${main[0]}: ${frames.length} rAF callbacks over ${span.toFixed(0)} ms (${(span / n).toFixed(2)} ms per frame)`);
console.log(`rAF callback ${(total((e) => e.name === 'FireAnimationFrame') / frames.length).toFixed(2)} ms per frame`);
const WAIT_RE = /Wait|Sync|Flush|Finish|ReadPixels|GetError|GetQuery|GetParameter/i;
console.log('per-frame ms of main-thread events (top 25 by total; nested events overlap):');
for (const [name, a] of [...agg].sort((x, y) => y[1].ms - x[1].ms).slice(0, 25)) {
  console.log(`  ${(a.ms / frames.length).toFixed(3).padStart(8)} ms  x${(a.n / frames.length).toFixed(1).padStart(6)}  ${name}${WAIT_RE.test(name) ? '   <- wait' : ''}`);
}
const waits = [...agg].filter(([k]) => WAIT_RE.test(k));
console.log('wait-like events per frame:', waits.map(([k, a]) => `${k} ${(a.ms / frames.length).toFixed(2)}`).join(', ') || 'none');
// GPU process main thread: how busy is it?
const gpuMain = [...names].filter(([, nm]) => nm === 'CrGpuMain').map(([k]) => k);
for (const k of gpuMain) {
  const g = (byThread.get(k) || []).filter((e) => e.ph === 'X' && e.dur);
  const top = new Map();
  for (const e of g) { const a = top.get(e.name) || 0; top.set(e.name, a + e.dur / 1000); }
  console.log(`GPU main ${k}: top`, [...top].sort((a, b) => b[1] - a[1]).slice(0, 8).map(([nm, ms]) => `${nm} ${(ms / frames.length).toFixed(2)}`).join(' | '));
}
