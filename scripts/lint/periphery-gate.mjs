#!/usr/bin/env node
// Dead-code gate over Periphery's JSON results (scripts/lint/periphery.sh runs Periphery first).
//
//   node scripts/lint/periphery-gate.mjs <results.json>            fail on any unexplained result
//   node scripts/lint/periphery-gate.mjs <results.json> --update   rewrite the baseline instead
//
// Periphery only sees what the macOS debug SwiftPM build compiles (with PincerChecks, PincerMacDev and
// the tests as consumers). It can't see Apps/ (the app targets, extensions and intents) or code that
// build skips (`#if os(iOS)`, the `#else` of `#if DEBUG`, ...), so a declaration used only from there
// looks unused. Those go in periphery-baseline.json with a reason, or get a
// `// periphery:ignore - <reason>` comment. An unused import is ignored when the file has a skipped
// region (the import may serve it), and unused parameters are ignored (signature churn).
import { readFileSync, writeFileSync, readdirSync, statSync, existsSync } from 'node:fs';
import { join, relative, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..');
const baselinePath = join(here, 'periphery-baseline.json');

const args = process.argv.slice(2);
const update = args.includes('--update');
const resultsPath = args.find((a) => !a.startsWith('--'));
if (!resultsPath) {
  console.error('usage: periphery-gate.mjs <periphery-results.json> [--update]');
  process.exit(2);
}

function swiftFiles(dir) {
  const out = [];
  if (!existsSync(dir)) return out;
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) out.push(...swiftFiles(path));
    else if (name.endsWith('.swift')) out.push(path);
  }
  return out;
}

// Evaluates an `#if` condition as the macOS debug SwiftPM build sees it.
export function compiledOnMacDebug(condition) {
  const expr = condition
    .replace(/\/\/.*$/, '')
    .replace(/\bos\(\s*macOS\s*\)/g, 'true')
    .replace(/\bos\(\s*\w+\s*\)/g, 'false')
    .replace(/\bcanImport\(\s*UIKit\s*\)/g, 'false')
    .replace(/\bcanImport\(\s*[\w.]+\s*\)/g, 'true')
    .replace(/\btargetEnvironment\([^)]*\)/g, 'false')
    .replace(/\b(arch|compiler|swift|hasFeature|hasAttribute)\([^)]*\)/g, 'true')
    .replace(/\bDEBUG\b/g, 'true')
    .replace(/\bSWIFT_PACKAGE\b/g, 'true')
    .replace(/\b(?!true\b|false\b)[A-Za-z_]\w*\b/g, 'false');
  if (!/^[\s()!&|truefals]*$/.test(expr)) return true;
  try {
    return Boolean(Function(`return (${expr});`)());
  } catch {
    return true;
  }
}

// The text of every region of `source` that the macOS debug build doesn't compile.
export function skippedRegions(source) {
  const stack = []; // { parentLive, taken, live }
  let live = true;
  const kept = [];
  for (const line of source.split('\n')) {
    const directive = line.match(/^\s*#(if|elseif|else|endif)\b(.*)$/);
    if (directive) {
      const [, kind, rest] = directive;
      if (kind === 'if') {
        const value = compiledOnMacDebug(rest);
        stack.push({ parentLive: live, taken: value });
        live = live && value;
      } else if (kind === 'elseif' && stack.length) {
        const top = stack[stack.length - 1];
        const value = !top.taken && compiledOnMacDebug(rest);
        top.taken ||= value;
        live = top.parentLive && value;
      } else if (kind === 'else' && stack.length) {
        const top = stack[stack.length - 1];
        live = top.parentLive && !top.taken;
        top.taken = true;
      } else if (kind === 'endif' && stack.length) {
        live = stack.pop().parentLive;
      }
      continue;
    }
    if (!live) kept.push(line);
  }
  return kept.join('\n');
}

const key = (r) => `${r.file}|${r.kind}|${r.name}|${r.hint}`;

const results = JSON.parse(readFileSync(resultsPath, 'utf8')).map((r) => ({
  file: r.location.replace(/:\d+:\d+$/, ''),
  line: Number(r.location.match(/:(\d+):\d+$/)?.[1] ?? 0),
  kind: r.kind,
  name: r.name,
  hint: r.hints.join(','),
  accessibility: r.accessibility,
}));

const blindFiles = new Set();
for (const file of [...swiftFiles(join(root, 'Sources')), ...swiftFiles(join(root, 'Tests'))]) {
  if (skippedRegions(readFileSync(file, 'utf8')).trim()) blindFiles.add(relative(root, file));
}

const fileText = new Map();
const projected = (r) => {
  if (!fileText.has(r.file)) fileText.set(r.file, readFileSync(join(root, r.file), 'utf8'));
  return new RegExp(`\\$${r.name}\\b`).test(fileText.get(r.file));
};

const baseline = existsSync(baselinePath) ? JSON.parse(readFileSync(baselinePath, 'utf8')) : { entries: [] };
const baselined = new Map(baseline.entries.map((e) => [key(e), e]));

const failures = [];
const matchedBaseline = new Set();
// Same-named declarations of one kind in one file share a key; an entry's `count` (default 1) is
// how many of them it covers, so another one still fails.
const used = new Map();
let retained = 0;
let baselinedCount = 0;
for (const r of results) {
  if (r.kind === 'var.parameter') {
    retained++;
    continue;
  }
  // Periphery 3.8 doesn't count a property wrapper's projected value (`$name`, as in a `@State`
  // passed on as a binding) as a read.
  if (r.kind === 'var.instance' && projected(r)) {
    retained++;
    continue;
  }
  // An import can be needed only by a region the macOS build skips.
  if (r.kind === 'module' && blindFiles.has(r.file)) {
    retained++;
    continue;
  }
  const entry = baselined.get(key(r));
  if (entry && (used.get(key(r)) ?? 0) < (entry.count ?? 1)) {
    used.set(key(r), (used.get(key(r)) ?? 0) + 1);
    matchedBaseline.add(key(r));
    baselinedCount++;
    continue;
  }
  failures.push(r);
}

if (update) {
  const byKey = new Map();
  for (const e of baselined.values()) {
    if (matchedBaseline.has(key(e))) byKey.set(key(e), { ...e, count: used.get(key(e)) });
  }
  for (const r of failures) {
    const e = byKey.get(key(r)) ?? { file: r.file, kind: r.kind, name: r.name, hint: r.hint, reason: 'TODO: why this must stay', count: 0 };
    e.count++;
    byKey.set(key(r), e);
  }
  const entries = [...byKey.values()].map(({ count, ...e }) => (count > 1 ? { ...e, count } : e));
  entries.sort((a, b) => key(a).localeCompare(key(b)));
  writeFileSync(baselinePath, `${JSON.stringify({ entries }, null, 2)}\n`);
  console.log(`Wrote ${entries.length} baseline entries to ${relative(root, baselinePath)}. Fill in every reason.`);
  process.exit(0);
}

const stale = baseline.entries.filter((e) => !matchedBaseline.has(key(e)));
console.log(
  `Periphery: ${results.length} results, ${retained} ignored (parameters, $projections, imports a skipped #if region may need), ` +
    `${baselinedCount} baselined, ${failures.length} new.`,
);
if (stale.length) {
  console.log(`\nThese baseline entries no longer match anything; remove them from ${relative(root, baselinePath)}:`);
  for (const e of stale) console.log(`  ${e.file}  ${e.kind} ${e.name} (${e.hint})`);
}
if (failures.length) {
  const what = { unused: 'unused', assignOnlyProperty: 'assigned but never read', redundantProtocol: 'redundant protocol' };
  console.log('\nDead code:');
  for (const r of failures) {
    const text = `${r.kind} '${r.name}' is ${what[r.hint] ?? r.hint}`;
    console.log(`  ${r.file}:${r.line}: ${text}`);
    if (process.env.GITHUB_ACTIONS) console.log(`::error file=${r.file},line=${r.line}::${text}`);
  }
  console.log(
    '\nDelete it. If it really is used (reflection, a runtime entry point, a Apps/ or iOS-only code, which Periphery can\'t see), ' +
      "add `// periphery:ignore - <reason>` above the declaration, or list it with a reason in " +
      `${relative(root, baselinePath)} (scripts/lint.sh --update-baselines adds new results).`,
  );
  process.exit(1);
}
const missingReasons = baseline.entries.filter((e) => !e.reason || e.reason.startsWith('TODO'));
if (missingReasons.length) {
  console.log(`\n${missingReasons.length} baseline entries have no reason; add one to each.`);
  process.exit(1);
}
