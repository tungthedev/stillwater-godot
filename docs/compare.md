# Same load on both engines

How to run Stillwater and this Godot port with the same world, the same systems and the same
bench route, so their frame times compare.

## The two URLs

Godot (this repo's Web build, `build/web`):

```
http://<host>:<port>/index.html?bench
```

Stillwater (a build or dev server of the Stillwater repo, commit `6f67883` or later):

```
http://<host>:<port>/?bench=trailhead,forest,walk&q=low&dur=20&stopDur=5&warmup=60&no=rocks,props,birds,motes,fly,spray,mist,shadow&nowater
```

Open each on the phone, wait for the result panel, screenshot it.

## What each flag does

| Flag | Effect in Stillwater | Why |
| --- | --- | --- |
| `bench=trailhead,forest,walk` | Bench route: the two stops, then the trail walk | Godot runs the same three stages |
| `q=low` | `low` tier (scale 0.6, max 0.9 MP, bloom 3 levels, FXAA, no MSAA, no god rays) | Godot ports `low` |
| `dur=20` | Walk lasts 20 s at 2.0 m/s from the trailhead (40 m) | Godot walks 20 s at 2.0 m/s |
| `stopDur=5` | Each stop measures at least 5 s (and 100 frames, cap 30 s) | Godot uses the same rule |
| `warmup=60` | 60 frames before each stage is measured | Godot settles 2 s (and at least 6 frames); 60 frames is 1 to 2 s |
| `no=rocks` | Hides rocks | Godot has none |
| `no=props` | Hides props and the village | Godot has none |
| `no=birds` | Hides birds | Godot has none |
| `no=motes` | Hides motes and fireflies | Godot has none |
| `no=fly` | Hides butterflies | Godot has none |
| `no=spray` | Hides the stream spray | Godot has no stream |
| `no=mist` | Hides the waterfall mist | Godot has no waterfall |
| `no=shadow` | Turns off the sun shadow map | Nothing in the Godot port casts or receives a shadow map; Godot's Shadow button defaults to off |
| `nowater` | The lake mesh is not added | Godot has no water |

Every `no=` name above is checked against `src/world/buildWorld.js` (the `OFF.has(...)` list and
`createRenderFlags`) and `src/main.js` (`nowater`). Left on, because Godot draws them too:
`terrain`, `trees` (with the four hero oaks), `grass` (grass and flowers), `clouds` (cumulus),
`sky` (sky dome with cirrus). Reflections are already off at `low` (`reflEvery: 0`).

## What cannot be switched off in Stillwater

These still draw (or run) in Stillwater and have no Godot counterpart, so Stillwater carries a bit
more load than Godot at the same URL:

- **ferns**, **logs**, **light shafts** (`shafts`): registry systems with no `no=` switch.
- **stream** body and **waterfall** body: only their spray and mist have switches.
- **shore** decals.
- **terrain shadow pass**: the heightmap sun-visibility pass that terrain, trees and grass read.
  Godot does not port it (`shaders/terrain.gdshader`).
- **sky LUT** and **ambient read-back**: drawn once at a fixed time of day, not per frame.

The look checks (`captures/slice4`, `captures/slice5`) hide ferns, logs and light shafts at runtime
instead (`tools/shoot_stillwater.mjs --hide ferns,logs,shafts`); the bench URL cannot.

## Render size: same rule, one trap

Both engines size the 3D render the same way on a phone: device pixels times 0.6, capped at
0.9 MP (`capScaleForPixels`). On an iPhone at 390 x 844 CSS points and dpr 3 (1170 x 2532 device
pixels) that is 644 x 1393. The post composite runs on all 1170 x 2532 pixels in both.

The trap: Stillwater applies the device pixel ratio and the cap only when it detects a phone
(`isMobileDevice`: phone user agent, touch, or a mobile GPU name). On a desktop browser at dpr 3
without a phone user agent it renders 234 x 506 (0.6 of the CSS size). Godot always renders at
device pixels. So:

- On the iPhone itself the two match.
- In desktop Chrome, compare at dpr 1 (the look checks use 675 x 1130 at dpr 1: both 405 x 678),
  or emulate a phone user agent with touch on the Stillwater side.

## Godot levers

The Godot build's buttons (and start-up flags) change cost; each run's panel records them:

| Button | Flag | Values | What it changes |
| --- | --- | --- | --- |
| Res | `res=auto\|100\|50\|40` | auto = Stillwater's rule | Internal 3D size; `100`/`50`/`40` are plain scales of the device pixels, no cap |
| Dist | `dist=100\|50\|25` | 60 km / 8 km / 4 km | Camera far plane (terrain, impostors, clouds beyond it are culled) and tree hero / mid / bush radii x1 / x0.75 / x0.5 |
| Dens | `dens=100\|75\|50\|25` | % of the `low` tier | Trees by rank (rank < 0.55 x dens x 65536) and the first N grass, flower ranks per tile |
| Post | `nopost` | on / off | Off: no bloom, FXAA, grain; objects grade themselves; one upscale blit |
| Shadow | `shadow` | off / on | Godot sun shadow map (nothing casts into it) |
| Grass, Trees | `nograss`, `notrees` | on / off | Hide the system |
| | `ldr` | | Force the 8-bit scene target (post off), for browsers without float colour buffers |

## Fixed in slice5-3: terrain and grass froze at the first frames (Godot, GPU Chrome)

Builds up to slice5-2 lost the ground during the walk in GPU Chrome
(`captures/slice5/walk_bug/`). The GPU kept drawing the terrain and grass instance data of
the first few frames: Godot rewrote the MultiMesh buffer every frame, but its GLES3 renderer
disables the instance attributes after each draw, and with that pattern Chrome's ANGLE (seen on
Vulkan, Intel UHD 730) keeps reading the old data. `tools/gl_stale_instances.html` reproduces it
in plain WebGL2. Once the trail turned, the frozen node set was out of view and only sky showed.
Fixed by alternating two MultiMeshes per draw (`systems/swap_multimesh.gd`), so each frame points
the attributes at another buffer. `tools/walk_check.mjs` guards it.

What this changes in earlier numbers: the slice 4 and slice 5 `?bench` walk stages and the
`?bench` forest stage (it runs after the trailhead in the same page) drew a frozen, partly
off-screen terrain and grass, so their fps read high. Single-pose loads (`?pose=forest`,
`tools/measure_web.mjs`) were right: their frozen data is that pose's own. Before/after numbers:
`captures/slice5/walk_fix/`.
