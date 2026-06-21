// One-time data tool: enrich the bundled pass dataset with a per-vertex
// elevation profile so the app can draw a detailed height-over-sea-level curve
// offline (the base dataset's `geometry` is bare [lat,lon]).
//
// For every pass it fetches the elevation of each geometry vertex from the
// Open-Meteo Elevation API (Copernicus DEM GLO-90, ~90 m) in a single batched
// request, and writes assets/data/pass_elevations_ch.json:
//
//   { "_attribution": "...", "_source": "...",
//     "elevations": { "<osmId|name>": [ele0, ele1, ...], ... } }
//
// The elevation array is aligned 1:1 with that pass's geometry order, so the
// app pairs them by index. Re-run after regenerating passes_ch.json.
//
//   node tools/fetch_pass_elevations.mjs

import { readFileSync, writeFileSync, existsSync } from 'node:fs';

const SRC = 'assets/data/passes_ch.json';
const OUT = 'assets/data/pass_elevations_ch.json';
const API = 'https://api.open-meteo.com/v1/elevation';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function elevationsFor(geometry) {
  const lat = geometry.map((g) => g[0].toFixed(6)).join(',');
  const lon = geometry.map((g) => g[1].toFixed(6)).join(',');
  const url = `${API}?latitude=${lat}&longitude=${lon}`;
  for (let attempt = 0; attempt < 12; attempt++) {
    try {
      const res = await fetch(url);
      if (res.status === 429) {
        // The public API throttles by coordinate count; wait out the window.
        process.stdout.write('(429, waiting 60s) ');
        await sleep(60000);
        continue;
      }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const json = await res.json();
      const ele = json.elevation;
      if (!Array.isArray(ele) || ele.length !== geometry.length) {
        throw new Error(`len ${ele?.length} != ${geometry.length}`);
      }
      return ele.map((e) => Math.round(e));
    } catch (e) {
      if (attempt >= 11) throw e;
      await sleep(2000 * (attempt + 1)); // back off on transient blips
    }
  }
}

function makeOut(elevations) {
  return {
    _attribution:
      'Elevation © Copernicus DEM GLO-90 via Open-Meteo (open-meteo.com).',
    _source: 'https://api.open-meteo.com/v1/elevation',
    elevations,
  };
}

async function main() {
  const doc = JSON.parse(readFileSync(SRC, 'utf8'));
  const passes = Array.isArray(doc) ? doc : doc.passes;
  // Resume: keep anything already fetched from a previous (interrupted) run.
  const elevations =
    existsSync(OUT) ? (JSON.parse(readFileSync(OUT, 'utf8')).elevations ?? {}) : {};
  let ok = 0;
  let skipped = 0;
  for (let i = 0; i < passes.length; i++) {
    const p = passes[i];
    const id = p.osmId != null ? String(p.osmId) : p.name;
    const geom = p.geometry;
    if (!Array.isArray(geom) || geom.length < 2) {
      skipped++;
      continue;
    }
    if (Array.isArray(elevations[id]) && elevations[id].length === geom.length) {
      ok++;
      continue; // already have it
    }
    process.stdout.write(`[${i + 1}/${passes.length}] ${p.name} (${geom.length} pts) … `);
    elevations[id] = await elevationsFor(geom);
    ok++;
    console.log('ok');
    writeFileSync(OUT, JSON.stringify(makeOut(elevations))); // incremental save
    await sleep(300); // be polite to the public API
  }
  writeFileSync(OUT, JSON.stringify(makeOut(elevations)));
  console.log(`\nWrote ${OUT}: ${ok} passes, ${skipped} skipped.`);
}

main().catch((e) => {
  console.error('FAILED:', e);
  process.exit(1);
});
