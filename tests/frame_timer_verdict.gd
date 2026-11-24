extends SceneTree

# The iPhone paces frames at 60 Hz, which headless Chrome does not, so the paced branch of
# FrameTimer.analyze() is checked here on synthetic frames.
# Run: godot --headless --path . -s tests/frame_timer_verdict.gd   (exit code 1 on any failure)

const FrameTimer := preload("res://systems/frame_timer.gd")


func _init() -> void:
	var fails := 0
	var cases := [
		["2 vsyncs, 20 ms work", [33.3, 33.4], 20.0, 0.0, "CPU-bound"],
		["2 vsyncs, 10 ms work", [33.3, 33.4], 10.0, 0.0, "GPU-bound"],
		["2 vsyncs, 30 ms CPU of which 18 wait", [33.3, 33.4], 30.0, 18.0, "GPU-bound"],
		["1 ms clock: 33 / 34 ms, 20 ms work", [33.0, 34.0], 20.0, 0.0, "CPU-bound"],
		["every vsync, 5 ms work", [16.0, 17.0], 5.0, 0.0, "60 Hz cap"],
		["uncapped, 26 ms work of 28", [27.5, 28.5], 26.0, 0.0, "CPU-bound"],
		["uncapped, 8 + 18 wait of 28", [27.5, 28.5], 26.0, 18.0, "GPU-bound"],
	]
	for c in cases:
		var iv: Array = []
		var cpu: Array = []
		var wait: Array = []
		for i in 100:
			iv.append(c[1][i % 2])
			cpu.append(c[2])
			wait.append(c[3])
		var r := FrameTimer.analyze({"cpu": cpu, "iv": iv, "wait": wait, "gpu": []})
		var ok: bool = r.bound == c[4]
		fails += 0 if ok else 1
		print("%s %s: %s (want %s)" % ["ok  " if ok else "FAIL", c[0], r.bound_note, c[4]])
	print("FRAME_TIMER_VERDICT %s (%d failures)" % ["PASS" if fails == 0 else "FAIL", fails])
	quit(1 if fails else 0)
