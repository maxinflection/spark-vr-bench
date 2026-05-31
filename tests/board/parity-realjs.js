// parity-realjs.js (bd <ISSUE>) — run the REAL index.html canonical-view
// selection against a board.json and confirm each cell's headline matches an
// expected static table. This extracts selectMeasurement/deviatingAxes/effective
// verbatim from docs/board/index.html (no reimplementation), so it catches a
// drift between the page's actual logic and the Python port in check-parity.py.
//
// Usage: node parity-realjs.js <board.json> <expected.json>
//   expected.json: { "<model_id>": { "<bench_id>": <ratio | "NA" | [label,note]> } }
// Exit 0 = all match; 1 = mismatch / load error. Invoked by check-parity.py
// when node is on PATH; harmless to skip if it isn't.
//
// NB: deliberately NOT in strict mode — we direct-eval the page's function
// DECLARATIONS so they populate this scope (and close over `state`/`html`),
// which strict-mode eval forbids.
const fs = require('fs');
const path = require('path');

const [, , boardPath, expectedPath] = process.argv;
if (!boardPath || !expectedPath) {
  console.error('usage: node parity-realjs.js <board.json> <expected.json>');
  process.exit(1);
}
const htmlPath = path.join(__dirname, '..', '..', 'docs', 'board', 'index.html');
const html = fs.readFileSync(htmlPath, 'utf8');

// Lift a named function's source by brace-matching from its declaration.
function grab(name) {
  const re = new RegExp('function ' + name + '\\s*\\([^)]*\\)\\s*\\{');
  const i = html.search(re);
  if (i < 0) throw new Error('function not found in index.html: ' + name);
  let depth = 0;
  for (let k = html.indexOf('{', i); k < html.length; k++) {
    if (html[k] === '{') depth++;
    else if (html[k] === '}') { depth--; if (depth === 0) return html.slice(i, k + 1); }
  }
  throw new Error('unbalanced braces for ' + name);
}

const board = JSON.parse(fs.readFileSync(boardPath, 'utf8'));
const expected = JSON.parse(fs.readFileSync(expectedPath, 'utf8'));
const state = { dims: board.condition_dims };   // the globals the functions close over
/* eslint-disable no-eval */
eval(grab('effective'));
eval(grab('deviatingAxes'));
eval(grab('selectMeasurement'));
/* eslint-enable no-eval */

const benches = {};
board.benches.forEach((b) => { benches[b.id] = b; });
const map = {};
board.scores.forEach((s) => { map[s.model_id + '|' + s.bench_id] = s; });

let fails = 0;
let n = 0;
for (const [mid, cells] of Object.entries(expected)) {
  for (const [bid, exp] of Object.entries(cells)) {
    if (bid === 'sec-bench-patched') continue;
    n++;
    const entry = map[mid + '|' + bid];
    const sel = entry ? selectMeasurement(entry.measurements, benches[bid], 'canonical') : null;
    if (sel === null) {
      console.log('  ✗', mid, bid, 'expected', exp, 'got blank'); fails++;
    } else if (typeof exp === 'string') {   // tier cell, e.g. 'T1'
      if (sel.m.label !== exp) { console.log('  ✗', mid, bid, 'tier', exp, 'got', sel.m.label); fails++; }
    } else if (sel.m.value === null || Math.abs(sel.m.value - exp) > 1e-9) {
      console.log('  ✗', mid, bid, 'expected', exp, 'got', sel.m.value); fails++;
    }
  }
}
console.log('[real-JS] ' + n + ' cells via the actual index.html selectMeasurement, ' + fails + ' mismatch(es)');
process.exit(fails ? 1 : 0);
