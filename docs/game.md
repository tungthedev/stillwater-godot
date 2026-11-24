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
- Trees block with the full canonical list, as in Stillwater on every tier, so at `low` about 39%
  of the trunks that block are not drawn (147,463 colliders, 90,010 drawn trees, bushes excluded).
- Benches, rocks, props, the village and the bridge do not block or seat yet: they arrive with W3
  through `session.interactables` (benches) and `player.colliders` / `player.ground_override`.
- The pause sheet shows a Perf button where Stillwater shows the quality picker (only `low` exists).
- Text shadows are a faint grown copy: Godot labels have no blurred shadow.

## Check flags

- `?walklog`: records each system's script time per frame in play (`window.__walk`), for
  `tools/free_walk_check.mjs`.
- `?spawn=x,z,yaw`: start the walk somewhere else (check legs).
- `?debug`: show the perf readout and levers at load.

## Checks

- `BASE=... gpu-run node tools/free_walk_check.mjs --build w1-1`: four legs with real input (keys
  with Shift through the meadow, the Trail button through the forest, the stick up a slope and into
  the east edge); fails on too little ground covered, sky below the horizon, repeated script frames
  over 5 ms in terrain, trees or grass (or one over 10 ms), leaving the boundary, page errors.
- `GODOT=... STILLWATER=... gpu-run node tools/game_shots.mjs`: title, place card, walking and pause
  at the same moments in both games, phone portrait, phone landscape and desktop.
