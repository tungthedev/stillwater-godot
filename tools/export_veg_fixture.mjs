// Writes data/valley/veg_fixture.json from Stillwater's own grassTiles.js: the packed per-rank
// scatter (q16 local x/z and four q16 randoms) of the grass and flower layouts plus a few tile
// mirror bits, so tests/check_world.gd can prove systems/grass.gd places every root where
// Stillwater does. Layouts are GRASS_LAYOUT / FLOWER_LAYOUT in src/world/grass.js.
//   node tools/export_veg_fixture.mjs [--stillwater <path>]
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const args = process.argv.slice(2);
const i = args.indexOf('--stillwater');
const SW = path.resolve(i >= 0 ? args[i + 1] : '/home/hoalong/Projects/stillwater');
const tiles = await import(pathToFileURL(path.join(SW, 'src/world/grassTiles.js')).href);
const grass = await import(pathToFileURL(path.join(SW, 'src/world/grass.js')).href);

const layout = (L) => ({ ...L, packed: Array.from(tiles.generateTileScatter(L.maxCount, L.tileSize, L.seed, true).packed) });
const flips = [[0, 0], [1, 0], [-1, -1], [81, 107], [-67, -47], [-45, -32], [123456, -98765]]
  .map(([tx, tz]) => ({ tx, tz, ...tiles.tileFlipBits(tx, tz) }));
const out = { grass: layout(grass.GRASS_LAYOUT), flowers: layout(grass.FLOWER_LAYOUT), flips };
const file = path.resolve('data/valley/veg_fixture.json');
fs.writeFileSync(file, JSON.stringify(out) + '\n');
console.log('wrote', file, fs.statSync(file).size, 'bytes');
