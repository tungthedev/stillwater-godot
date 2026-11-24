extends RefCounted

# Start-up switches: `?name` / `?name=value` in the page URL on Web, `--name` / `--name=value`
# after `--` on the desktop command line.


static func has(name: String) -> bool:
	if OS.has_feature("web"):
		return bool(JavaScriptBridge.eval("new URLSearchParams(location.search).has('%s')" % name))
	for a in OS.get_cmdline_user_args():
		if a == "--" + name or a.begins_with("--%s=" % name):
			return true
	return false


static func value(name: String, fallback: String = "") -> String:
	if OS.has_feature("web"):
		var v = JavaScriptBridge.eval("new URLSearchParams(location.search).get('%s') || ''" % name)
		return str(v) if v != null and str(v) != "" else fallback
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--%s=" % name):
			return a.substr(name.length() + 3)
	return fallback


# Art-style switch: ?style=painterly|classic (default painterly).
static func style() -> String:
	return "classic" if value("style", "painterly").to_lower() == "classic" else "painterly"


# Web: can this browser render to float colour buffers (what the RGBA16F scene target needs)?
# Desktop GL always can.
static func float_targets() -> bool:
	if not OS.has_feature("web"):
		return true
	return bool(JavaScriptBridge.eval("(() => { const gl = document.createElement('canvas').getContext('webgl2'); return !!gl && !!(gl.getExtension('EXT_color_buffer_float') || gl.getExtension('EXT_color_buffer_half_float')); })()"))


static func device_pixel_ratio() -> float:
	if OS.has_feature("web"):
		return float(JavaScriptBridge.eval("window.devicePixelRatio || 1"))
	return DisplayServer.screen_get_scale()


static func user_agent() -> String:
	if OS.has_feature("web"):
		return str(JavaScriptBridge.eval("navigator.userAgent"))
	return "%s desktop" % OS.get_name()


# The GPU name. On Web Godot only sees the masked "WebKit WebGL", so ask the browser for the
# unmasked one (Safari answers "Apple GPU").
static func gpu_name() -> String:
	if OS.has_feature("web"):
		return str(JavaScriptBridge.eval("(() => { const gl = document.createElement('canvas').getContext('webgl2'); const x = gl && gl.getExtension('WEBGL_debug_renderer_info'); return gl ? String(x ? gl.getParameter(x.UNMASKED_RENDERER_WEBGL) : gl.getParameter(gl.RENDERER)) : 'no webgl2'; })()"))
	return RenderingServer.get_video_adapter_name()
