extends RefCounted

# Main-thread time, the part of it spent waiting on the GPU, and GPU time per frame on Web, all
# measured from JavaScript.
#
# The Web build is single-threaded: each requestAnimationFrame callback runs one whole Godot
# iteration (input, physics, scripts, render submit, WebGL calls). Wrapping
# window.requestAnimationFrame times that callback with performance.now(): the main-thread time of
# the frame. Godot's main loop looks the global up on every frame, so the wrapper can be installed
# after start-up.
#
# Part of that time is not work. WebGL calls that return state (getParameter, getError, readPixels,
# ...) are synchronous round trips to the browser's GPU process, which first runs every command
# queued before them; when the GPU is behind, the main thread sits in that call until it catches
# up. Emscripten's frame commit (blitOffscreenFramebuffer) makes such a call every frame, so in a
# GPU-heavy frame most of the "render" span is a wait for the GPU (seen in Chrome traces as
# CommandBufferHelper::Finish). Those calls are timed on Godot's context and reported as "wait";
# CPU work = main-thread time - wait.
#
# GPU time needs EXT_disjoint_timer_query_webgl2: one TIME_ELAPSED query around each callback,
# read back frames later. Desktop Chrome has it; iOS Safari does not. It spans from the first to the
# last GPU command of the frame, so it includes GPU idle gaps while the CPU is still submitting.
#
# Limits: Safari rounds performance.now() to 1 ms; a wait also builds up when the GPU process itself
# is slow, not only the GPU; the browser's compositing after the callback is in none of these.

const JS_INSTALL := """
(() => {
  if (window.__ft) return 'present';
  const ft = window.__ft = { rec: false, inCb: false, cpu: [], iv: [], wait: [], gpu: [], pend: [], gl: null,
    ext: null, gpuState: 'n/a', noGpu: false, prevStart: 0, prevCpu: -1, prevWait: 0, waitAcc: 0, waitBy: {},
    disjoint: 0 };
  const raf = window.requestAnimationFrame.bind(window);
  const SYNC = ['getParameter', 'getError', 'readPixels', 'clientWaitSync', 'getBufferSubData', 'getSyncParameter',
    'getQueryParameter', 'finish', 'checkFramebufferStatus', 'getShaderParameter', 'getProgramParameter',
    'getShaderInfoLog', 'getProgramInfoLog', 'getUniformLocation', 'getAttribLocation', 'getActiveUniform',
    'getUniformBlockIndex', 'getFramebufferAttachmentParameter', 'getIndexedParameter', 'getTexParameter',
    'getInternalformatParameter', 'getRenderbufferParameter', 'getVertexAttrib', 'getUniform', 'isEnabled'];
  ft.context = () => {
    if (ft.gl) return ft.gl;
    const c = document.getElementById('canvas') || document.querySelector('canvas');
    const gl = c && c.getContext('webgl2');
    if (!gl) return null;
    for (const m of SYNC) {
      const orig = gl[m];
      if (typeof orig !== 'function') continue;
      gl[m] = function (...a) {
        if (!ft.inCb) return orig.apply(gl, a);
        const t = performance.now();
        try {
          return orig.apply(gl, a);
        } finally {
          const d = performance.now() - t;
          ft.waitAcc += d;
          const k = m + (m === 'getParameter' ? ':0x' + Number(a[0]).toString(16) : '');
          ft.waitBy[k] = (ft.waitBy[k] || 0) + d;
        }
      };
    }
    ft.gl = gl;
    return gl;
  };
  ft.poll = () => {
    const gl = ft.gl, ext = ft.ext;
    if (gl.getParameter(ext.GPU_DISJOINT_EXT)) {
      ft.disjoint++;
      for (const q of ft.pend) gl.deleteQuery(q);
      ft.pend = [];
      return;
    }
    while (ft.pend.length && gl.getQueryParameter(ft.pend[0], gl.QUERY_RESULT_AVAILABLE)) {
      const q = ft.pend.shift();
      ft.gpu.push(gl.getQueryParameter(q, gl.QUERY_RESULT) / 1e6);
      gl.deleteQuery(q);
    }
  };
  window.requestAnimationFrame = (cb) => raf((ts) => {
    let q = null;
    if (ft.rec && ft.ext) {
      ft.poll();
      q = ft.gl.createQuery();
      ft.gl.beginQuery(ft.ext.TIME_ELAPSED_EXT, q);
    }
    const t0 = performance.now();
    if (ft.rec && ft.prevCpu >= 0) {
      ft.cpu.push(ft.prevCpu);
      ft.wait.push(ft.prevWait);
      ft.iv.push(t0 - ft.prevStart);
    }
    ft.waitAcc = 0;
    ft.inCb = ft.rec;
    try {
      cb(ts);
    } finally {
      ft.inCb = false;
      const t1 = performance.now();
      if (q) { ft.gl.endQuery(ft.ext.TIME_ELAPSED_EXT); ft.pend.push(q); }
      if (ft.rec && !ft.fresh) { ft.prevStart = t0; ft.prevCpu = t1 - t0; ft.prevWait = ft.waitAcc; }
      ft.fresh = false;
    }
  });
  ft.start = (noGpu) => {
    const gl = ft.context();
    if (gl) for (const q of ft.pend) gl.deleteQuery(q);
    ft.ext = gl && !noGpu ? gl.getExtension('EXT_disjoint_timer_query_webgl2') : null;
    ft.gpuState = !gl ? 'n/a (no webgl2 context)' : noGpu ? 'off (?nogputimer)' : ft.ext ? 'timer query' : 'n/a (no timer query)';
    ft.pend = []; ft.cpu = []; ft.iv = []; ft.wait = []; ft.gpu = []; ft.waitBy = {};
    ft.prevCpu = -1; ft.disjoint = 0;
    // Called from inside a frame: that frame is only partly timed, so recording starts with the next.
    ft.rec = true;
    ft.fresh = true;
  };
  ft.stop = () => {
    ft.rec = false;
    ft.inCb = false;
    return JSON.stringify({ cpu: ft.cpu, iv: ft.iv, wait: ft.wait, gpu: ft.gpu, wait_by: ft.waitBy,
      gpu_state: ft.gpuState, disjoint: ft.disjoint });
  };
  return 'installed';
})()
"""

const VSYNC_MS := 1000.0 / 60.0


static func available() -> bool:
	return OS.has_feature("web")


static func install() -> void:
	if available():
		JavaScriptBridge.eval(JS_INSTALL)


static func start(no_gpu: bool) -> void:
	if available():
		JavaScriptBridge.eval("window.__ft && window.__ft.start(%s)" % ("true" if no_gpu else "false"))


static func stop() -> Dictionary:
	if not available():
		return {}
	var s = JavaScriptBridge.eval("window.__ft ? window.__ft.stop() : ''")
	if s == null or str(s) == "":
		return {}
	var d = JSON.parse_string(str(s))
	return d if d is Dictionary else {}


static func avg(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var t := 0.0
	for v in a:
		t += float(v)
	return t / a.size()


# Nearest rank, as the bench's frame percentiles.
static func p95(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := a.duplicate()
	s.sort()
	return float(s[clampi(int(ceil(0.95 * s.size())) - 1, 0, s.size() - 1)])


# A display that paces rAF to 60 Hz puts most frame intervals on whole vsyncs (16.7, 33.3, 50 ms).
static func vsync_locked(iv: Array) -> bool:
	if iv.size() < 10:
		return false
	var on := 0
	for v in iv:
		var k := roundf(float(v) / VSYNC_MS)
		if k >= 1.0 and absf(float(v) - k * VSYNC_MS) < 1.5:
			on += 1
	return on >= 0.7 * iv.size()


# Which side sets the frame time. Per frame: the interval the CPU work alone (main-thread time minus
# GPU waits) would force, rounded up to whole vsyncs when the display paces the frames (20 ms of
# work cannot fit one 16.7 ms vsync), against the interval that followed. At 90% or more of it the
# CPU explains the frame; at 70% or less the rest of the frame went to waiting on the GPU (inside a
# WebGL call or before the next rAF). The stage verdict is the side that holds at least 60% of
# the frames, else "mixed".
static func analyze(js: Dictionary) -> Dictionary:
	var cpu: Array = js.get("cpu", [])
	var iv: Array = js.get("iv", [])
	var wait: Array = js.get("wait", [])
	var gpu: Array = js.get("gpu", [])
	var out := {"gpu_state": str(js.get("gpu_state", "n/a")), "frames_js": cpu.size()}
	if cpu.is_empty() or wait.size() != cpu.size():
		out["bound"] = "n/a"
		out["bound_note"] = "no main-thread timer (Web only)"
		return out
	var locked := vsync_locked(iv)
	var work: Array[float] = []
	var n_cpu := 0
	var n_gpu := 0
	for i in cpu.size():
		var w := maxf(0.0, float(cpu[i]) - float(wait[i]))
		work.append(w)
		var need := w
		if locked:
			need = maxf(1.0, ceilf(w / VSYNC_MS - 0.05)) * VSYNC_MS
		var r := need / maxf(float(iv[i]), 0.1)
		if r >= 0.9:
			n_cpu += 1
		elif r <= 0.7:
			n_gpu += 1
	var n := cpu.size()
	var iv_avg := avg(iv)
	out["cpu_avg"] = snappedf(avg(cpu), 0.01)
	out["cpu_p95"] = snappedf(p95(cpu), 0.01)
	out["wait_avg"] = snappedf(avg(wait), 0.01)
	out["wait_p95"] = snappedf(p95(wait), 0.01)
	out["work_avg"] = snappedf(avg(work), 0.01)
	out["work_p95"] = snappedf(p95(work), 0.01)
	out["frame_avg"] = snappedf(iv_avg, 0.01)
	out["frame_p95"] = snappedf(p95(iv), 0.01)
	out["vsync_locked"] = locked
	out["cpu_share"] = snappedf(float(n_cpu) / n, 0.01)
	out["gpu_share"] = snappedf(float(n_gpu) / n, 0.01)
	var has_gpu := gpu.size() >= 10
	out["gpu_avg"] = snappedf(avg(gpu), 0.01) if has_gpu else -1.0
	out["gpu_p95"] = snappedf(p95(gpu), 0.01) if has_gpu else -1.0
	# Where the waits were, ms per frame, biggest first.
	var by: Dictionary = js.get("wait_by", {})
	var keys := by.keys()
	keys.sort_custom(func(a: String, b: String) -> bool: return float(by[a]) > float(by[b]))
	var wait_by := {}
	for k in keys.slice(0, 4):
		wait_by[k] = snappedf(float(by[k]) / n, 0.01)
	out["wait_by"] = wait_by
	var bound := "mixed"
	var share := 1.0 - float(n_cpu + n_gpu) / n
	if n_cpu >= 0.6 * n:
		bound = "CPU-bound"
		share = float(n_cpu) / n
	elif n_gpu >= 0.6 * n:
		bound = "GPU-bound"
		share = float(n_gpu) / n
	out["bound"] = bound
	var note := "%s (%d%% of frames): work %.1f + wait %.1f of %.1f ms" % [bound, roundi(share * 100.0), avg(work), avg(wait), iv_avg]
	if locked:
		note += " at 60 Hz"
	note += (", GPU timer %.1f" % avg(gpu)) if has_gpu else ", GPU timer n/a"
	out["bound_note"] = note
	return out
