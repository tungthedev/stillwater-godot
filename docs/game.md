# The game page (W1)

The default page (`index.html`) is the game: title, then walking. `?bench`, `?pose=`, `?shot=` and
`?bench-shot=` pages run the fixed bench cameras exactly as before and create no game nodes.

## Controls (Stillwater's)

| | Desktop | Phone |
| --- | --- | --- |
| Start | click anywhere (captures the mouse) | tap anywhere |
| Walk | WASD / arrows, Shift strides (4.6 m/s) | left half: floating stick where the thumb lands |
| Look | mouse while captured | right half: drag |
| Follow the trail | Q | Trail button |
| Sit / stand | E | Sit button |
| Pause | Esc (or losing the pointer lock) | pause button, top right |
| Hide HUD | H | |
| Perf readout and levers | G, or Perf on the pause sheet | Perf on the pause sheet |

Not here yet, because their systems come later: Lamp and F (headlamp), Time and T, `[ ]` (hour),
M (music). The clock stays at 16:00.

## Differences from Stillwater

- Ground is the rendered height (near map blended into the far map past 1828 m), not the near map
  alone; they differ only between 1828 m and the 1850 m boundary.
- Trees block with the full canonical list, as in Stillwater on every tier, so at `low` about 45%
  of the trunks that block are not drawn (147,463 non-bush colliders, 81,202 of them drawn).
- Benches, rocks, props, the village and the bridge do not block or seat yet: they arrive with W3
  through `session.interactables` (benches) and `player.colliders` / `player.ground_override`.
- The pause sheet shows a Perf button where Stillwater shows the quality picker (only `low` exists).
- Text shadows are a faint grown copy: Godot labels have no blurred shadow.
- Pause freezes the walk, as in Stillwater; Q, Sit and the Trail button still toggle while paused
  (Stillwater keeps those actions live on the pause sheet too) and take effect on resume.
- After a Bench run from the pause sheet, the results panel sits over the sheet: Close, then tap to
  continue.

## Check flags

- `?walklog`: records each system's script time per frame in play (`window.__walk`), for
  `tools/free_walk_check.mjs`.
- `?spawn=x,z,yaw`: start the walk somewhere else (check legs).
- `?debug`: show the perf readout and levers at load.
- `?probe=bake`: on-device self-test for the grass bake pipeline (RGBA8 SubViewport round trip,
  partial `CLEAR_MODE_NEVER` update, 3D vertex-shader `texelFetch`, and a real trailhead grass tile
  baked and read back against CPU heights/normals/tallness/alpha); shows a phone-readable PASS/FAIL
  panel and writes `window.__probe`.
- `?probe=terrain`: on-device bisection for a black terrain. Renders the trailhead (terrain and sky
  only) offscreen once per variant and shows OK / BLACK per row with the ground colour, plus
  `window.__probe`: default, the other post mode, classic style, light floor off, atmosphere
  bypassed, classic indirect, classic toon ramp, NaN guards off, albedo only, each old
  undefined-behaviour construct switched back on, the driver's math mode (FAST or SAFE), and the
  terrain shader with one `isnan()` call put back as in s1-2 (rows in yellow are information only). Those
  rows run with no grass system; the last rows first run the real grass bake, the flower bake, or
  both, hide the blades and render the terrain again. The two CONTROL rows force a NaN and must
  read BLACK. Desktop:
  `xvfb-run -a godot --path . -- --probe=terrain --quit` prints `TERRAIN_PROBE PASS`.
- `?dbg_terrain=<bits>`: the same switches in the real game (bit values at the top of
  `shaders/stillwater.gdshaderinc`), e.g. `?dbg_terrain=1024` reproduces the iPhone black ground on
  desktop and `?dbg_terrain=1` puts the old trail `pow()` back.
- `?grassdbg=1`: shades grass blades black (0) to white (max) by decoded tallness while leaving the
  ground normal, to verify on-device whether blade tallness decodes as non-zero.

## Checks

- `BASE=... gpu-run node tools/free_walk_check.mjs --build w1-1`: four legs with real input (keys
  with Shift through the meadow, the Trail button through the forest, the stick up a slope and into
  the east edge); fails on too little ground covered, sky below the horizon, repeated script frames
  over 5 ms in terrain, trees or grass (or one over 10 ms), leaving the boundary, page errors. A
  single frame between 5 and 10 ms only warns, which is looser than a flat 5 ms limit; it measures
  script time only, not GPU upload or bake gaps.
- `BASE=... gpu-run node tools/game_ui_check.mjs --build w1-1`: touch on the phone view: pause holds
  the walker still, single-touch and second-finger taps on HUD buttons (Sit/Stand, Trail, Pause)
  while the stick thumb is held fire once without double-firing or turning into look input, stick
  recovery reclaims an orphaned touch without `touchEnd`, clears cleanly on `touchCancel`, and keeps
  the stick ring visible on a quick release + re-touch, two thumbs walk and look at once (lifting
  one keeps the other), Perf on the pause sheet shows the levers and runs Bench from the game,
  `?debug` shows them at load, and the HUD stays inside injected iPhone safe-area insets (portrait
  at load, landscape on a resize). Control rects and state come from `window.__ui` (`?walklog`).
- `GODOT=... STILLWATER=... gpu-run node tools/game_shots.mjs`: title, place card, walking and pause
  at the same moments in both games, phone portrait, phone landscape and desktop.
