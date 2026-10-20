#!/usr/bin/env node
// Duplication ratchet: runs jscpd (config: .jscpd.json) and fails if the clone count or the
// duplicated-lines percentage rises above scripts/lint/jscpd-baseline.json.
//   --update   rewrite the baseline to the current numbers
import { spawnSync, execFileSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..', '..');
const baselinePath = path.join(here, 'jscpd-baseline.json');
const update = process.argv.includes('--update');

const out = fs.mkdtempSync(path.join(os.tmpdir(), 'pincer-jscpd-'));
try {
  const bin = path.join(here, 'node_modules', '.bin', 'jscpd');
  const run = spawnSync(bin, ['--config', path.join(root, '.jscpd.json'), '--output', out], { cwd: root, encoding: 'utf8' });
  const reportPath = path.join(out, 'jscpd-report.json');
  if (!fs.existsSync(reportPath)) {
    console.error(`jscpd produced no report (exit ${run.status}).\n${run.stdout || ''}${run.stderr || ''}`);
    process.exit(2);
  }
  const report = JSON.parse(fs.readFileSync(reportPath, 'utf8'));
  const total = report.statistics.total;
  const current = { clones: total.clones, percentage: Math.ceil(total.percentage * 100 - 1e-9) / 100 };

  if (update) {
    fs.writeFileSync(baselinePath, JSON.stringify(current, null, 2) + '\n');
    console.log(`jscpd baseline updated: ${current.clones} clones, ${current.percentage.toFixed(2)}%`);
    process.exit(0);
  }

  const baseline = JSON.parse(fs.readFileSync(baselinePath, 'utf8'));
  const exact = total.percentage;
  const pct = `${exact.toFixed(2)}% duplicated lines (baseline ${baseline.percentage.toFixed(2)}%)`;
  if (total.clones > baseline.clones || exact > baseline.percentage + 1e-9) {
    console.error(`Duplicate code: ${total.clones} clones (baseline ${baseline.clones}), ${pct}.`);
    console.error('Extract a shared helper, or if the duplicate is intentional run scripts/lint.sh --update-baselines and justify it in the PR.');
    const changed = changedFiles();
    const rel = (f) => path.relative(root, path.resolve(root, f.name));
    const fmt = (f) => `${rel(f)}:${f.start}-${f.end}`;
    const all = report.duplicates;
    const mine = all.filter((d) => changed.has(rel(d.firstFile)) || changed.has(rel(d.secondFile)));
    const shown = mine.length ? mine : all;
    console.error(`\n${mine.length ? 'Clones touching files you changed' : 'All clones'} (${shown.length}):`);
    for (const d of shown) console.error(`  ${fmt(d.firstFile)}  <->  ${fmt(d.secondFile)}  (${d.lines} lines)`);
    process.exit(1);
  }
  console.log(`jscpd ok: ${total.clones} clones (baseline ${baseline.clones}), ${pct}.`);
  if (total.clones < baseline.clones || exact < baseline.percentage - 0.005) {
    console.log('Note: duplication dropped below the baseline. Lower it with scripts/lint.sh --update-baselines.');
  }
} finally {
  fs.rmSync(out, { recursive: true, force: true });
}

function changedFiles() {
  const files = new Set();
  const git = (...args) => {
    try {
      return execFileSync('git', args, { cwd: root, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] });
    } catch {
      return '';
    }
  };
  for (const text of [git('diff', '--name-only', 'origin/main...HEAD'), git('diff', '--name-only', 'HEAD'), git('ls-files', '--others', '--exclude-standard')]) {
    for (const line of text.split('\n')) if (line) files.add(line);
  }
  return files;
}
