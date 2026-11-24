extends RefCounted

# Main-thread and GPU time per frame on Web, measured from JavaScript.
#
# The Web build is single-threaded: each requestAnimationFrame callback runs one whole Godot
# iteration (input, physics, scripts, render submit, WebGL calls). Wrapping
# window.requestAnimationFrame times that callback with performance.now(), which is the CPU cost
# of the frame on the main thread. Godot's main loop looks the global up on every frame, so the
# wrapper can be installed after start-up.
#
# GPU time needs EXT_disjoint_timer_query_webgl2: one TIME_ELAPSED query around each callback's
# WebGL calls, read back frames later. Desktop Chrome has it; iOS Safari does not, so there the
# verdict is inferred from CPU time against the frame interval (see analyze()).
#
# Limits: Safari rounds performance.now() to 1 ms; a WebGL call can block when the GPU is backed up,
# which shows as CPU time (so "CPU well under the frame" is the reliable direction); the browser's
# own compositing after the callback is in neither number.

const JS_INSTALL := """
(() => {
  if (window.__ft) return 'present';
  const ft = window.__ft = { rec: false, cpu: [], iv: [], gpu: [], pend: [], gl: null, ext: null,
    gpuState: 'n/a', noGpu: false, prevStart: 0, prevCpu: -1, disjoint: 0 };
  const raf = window.requestAnimationFrame.bind(window);
  ft.initGpu = () => {
    if (ft.gl || ft.noGpu) return;
    const c = document.getElementById('canvas') || document.querySelector('canvas');
    const gl = c && c.getContext('webgl2');
    if (!gl) { ft.gpuState = 'n/a (no webgl2 context)'; return; }
    ft.gl = gl;
    ft.ext = gl.getExtension('EXT_disjoint_timer_query_webgl2');
    ft.gpuState = ft.ext ? 'timer query' : 'n/a (no timer query)';
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
      ft.iv.push(t0 - ft.prevStart);
    }
    try {
      cb(ts);
    } finally {
      const t1 = performance.now();
      if (q) { ft.gl.endQuery(ft.ext.TIME_ELAPSED_EXT); ft.pend.push(q); }
      if (ft.rec) { ft.prevStart = t0; ft.prevCpu = t1 - t0; }
    }
  });
  ft.start = (noGpu) => {
    ft.noGpu = !!noGpu;
    if (ft.noGpu) { ft.gl = null; ft.ext = null; ft.gpuState = 'n/a (?nogputimer)'; }
    else ft.initGpu();
    if (ft.gl) for (const q of ft.pend) ft.gl.deleteQuery(q);
    ft.pend = []; ft.cpu = []; ft.iv = []; ft.gpu = []; ft.prevCpu = -1; ft.disjoint = 0;
    ft.rec = true;
  };
  ft.stop = () => {
    ft.rec = false;
    return JSON.stringify({ cpu: ft.cpu, iv: ft.iv, gpu: ft.gpu, gpu_state: ft.gpuState, disjoint: ft.disjoint });
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


# Which side sets the frame time. Per frame: the interval the CPU work alone would force (rounded
# up to whole vsyncs when the display paces the frames: 20 ms of CPU cannot fit one 16.7 ms vsync)
# against the interval that followed. At 90% or more of it the CPU explains the frame; at 70% or
# less something after the CPU work held the frame (GPU or present). The stage verdict is the side
# that holds at least 60% of the frames, else "mixed". With a GPU timer the measured GPU time is
# reported next to it.
static func analyze(js: Dictionary) -> Dictionary:
	var cpu: Array = js.get("cpu", [])
	var iv: Array = js.get("iv", [])
	var gpu: Array = js.get("gpu", [])
	var out := {"gpu_state": str(js.get("gpu_state", "n/a")), "frames_js": cpu.size()}
	if cpu.is_empty():
		out["bound"] = "n/a"
		out["bound_note"] = "no main-thread timer (Web only)"
		return out
	var locked := vsync_locked(iv)
	var n_cpu := 0
	var n_gpu := 0
	for i in cpu.size():
		var c := float(cpu[i])
		var floor_ms := c
		if locked:
			floor_ms = maxf(1.0, ceilf(c / VSYNC_MS - 0.05)) * VSYNC_MS
		var r := floor_ms / maxf(float(iv[i]), 0.1)
		if r >= 0.9:
			n_cpu += 1
		elif r <= 0.7:
			n_gpu += 1
	var n := cpu.size()
	var cpu_avg := avg(cpu)
	var iv_avg := avg(iv)
	out["cpu_avg"] = snappedf(cpu_avg, 0.01)
	out["cpu_p95"] = snappedf(p95(cpu), 0.01)
	out["frame_avg"] = snappedf(iv_avg, 0.01)
	out["frame_p95"] = snappedf(p95(iv), 0.01)
	out["vsync_locked"] = locked
	out["cpu_share"] = snappedf(float(n_cpu) / n, 0.01)
	out["gpu_share"] = snappedf(float(n_gpu) / n, 0.01)
	var has_gpu := gpu.size() >= 10
	out["gpu_avg"] = snappedf(avg(gpu), 0.01) if has_gpu else -1.0
	out["gpu_p95"] = snappedf(p95(gpu), 0.01) if has_gpu else -1.0
	var other_side := "GPU-bound" if has_gpu else "GPU/present-bound"
	var bound := "mixed"
	var share := 1.0 - float(n_cpu + n_gpu) / n
	if n_cpu >= 0.6 * n:
		bound = "CPU-bound"
		share = float(n_cpu) / n
	elif n_gpu >= 0.6 * n:
		bound = other_side
		share = float(n_gpu) / n
	out["bound"] = bound
	var note := "%s (%d%% of frames), CPU %.1f of %.1f ms" % [bound, roundi(share * 100.0), cpu_avg, iv_avg]
	if locked:
		note += " at 60 Hz"
	note += (", GPU %.1f" % avg(gpu)) if has_gpu else ", GPU n/a"
	out["bound_note"] = note
	return out
