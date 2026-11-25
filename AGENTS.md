# Stillwater (Godot): agent guide

A Godot 4.7 port of the Stillwater valley walk, built for phones first. It uses the GL Compatibility
renderer (WebGL2 on the web). iPhone Safari is the main test target; native iOS comes later.

## The look: Studio Ghibli, for everything

Everything built in this game follows the look, feel and vibe of a Studio Ghibli film: terrain, grass,
trees, sky, sun, clouds, mountains, water, houses, interiors, props, light, motion and UI. That doesn't
mean a 2D renderer. It means a 3D world you walk through that feels like a Ghibli background painting:

- painted surfaces (gouache-like colour and soft tonal steps, no photo detail or shiny highlights)
- shapes read as soft masses with a few crisp lit edges
- colour graded after "When Marnie Was There": pale cyan day skies, deep true greens, warm evenings
- no ink outlines on scenery
- small life in the frame: wind as moving light, drifting clouds, smoke, birds

Judge every visual change side by side with film stills (Ghibli's free still library:
https://www.ghibli.jp/info/013772/), and say how it moves toward them. Speed still comes first: the
look must fit the phone budget.

## Commands

- Web build: `godot --headless --export-release "Web" build/web/index.html`. A healthy `index.pck` is
  about 16 MB; far more means stray files got packed (check the preset's exclude filter).
- Headless tests (exit code 1 on failure):
  - `godot --headless --path . -s tests/check_world.gd`
  - `godot --headless --path . -s tests/terrain_budget.gd`
  - `godot --headless --path . -s tests/frame_budget.gd` (add `-- --style=classic` for the classic look)
  - `godot --headless --path . -s tests/frame_timer_verdict.gd`
- GPU tests (need a display, or `xvfb-run -a`):
  - `godot --path . --rendering-driver opengl3 --resolution 675x1130 -s tests/post_parity.gd` (add
    `-- --tod=<preset>` to check one time of day)
  - `godot --path . -s tests/bake_probe.gd`
- Browser tools in `tools/` (`walk_check`, `game_ui_check`, `game_shots`, `probe_shot`, `bench_web`) take
  `BASE=http://127.0.0.1:<port>/` and launch Chrome through `tools/chrome.mjs` from a checkout of the
  [Stillwater](https://github.com/tungthedev/stillwater) repo (`--stillwater <path>`). They refuse
  software rendering, so timings mean something. If a `gpu-run` lock command exists on the machine,
  run them through it.
- Serve a build on your own free port; don't take one someone else is using.

## Where things live

- `main.gd`: loads the world (`world/compact_world.gd`) and creates every system.
- `systems/*.gd`: one file per system. Each header comment states what it draws and its budget.
- `systems/environment.gd`: the six time-of-day presets (`_preset_spec`): sky, fog, light and grade.
- `shaders/stillwater.gdshaderinc`: shared world uniforms, lighting and the in-object grade (`w_grade`).
- `shaders/post_composite.gdshader`: the post grade.
- `world/`: data loading and queries. `world_data.gd` is the full-precision loader that tests use.
- `data/valley/`: baked valley data. `tools/export_web.mjs` packs it into `data/valley/web/`, which the
  game loads.

## Rules

- **iPhone Safari (ANGLE on Metal):** never call `isnan()` in a shader, because it switches the whole
  shader to slow safe math. Never `pow()` a value that can be negative: it becomes NaN and renders
  black. Clamp first.
- **Compatibility renderer only.** No compute, no features that only Forward+ or Mobile have.
- **Two grade paths must match.** The post grade and `w_grade` (used when post is off) must give the
  same picture; `tests/post_parity.gd` checks this. Change both together.
- **Speed comes first.** Keep each system inside the budget in its header. No new render passes,
  render targets or full-screen texture reads without a measured reason. A visual or speed change ships
  with before/after shots from the same camera and an interleaved bench against the old build
  (alternate old and new runs; single runs vary by about ±0.3 ms).
- **Same world on every setting.** Quality levers change only what is drawn, never placement or
  collision.
- **Evidence** (shots, bench JSON, logs) goes in `captures/<slice>/`. Godot ignores that folder.
- **Comments say why**, never review history.
- `docs/` is excluded from exports, so design images there don't bloat the game.
