import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = fileURLToPath(new URL('../dist/', import.meta.url));
const assets = path.join(root, '_astro');
const files = (await readdir(assets)).filter((file) => file.endsWith('.css'));
const css = (await Promise.all(files.map((file) => readFile(path.join(assets, file), 'utf8')))).join('\n');
const rules = [...css.matchAll(/([^{}]+)\{([^{}]+)\}/g)];

// Check emitted assets, so a missing stylesheet import cannot silently restore Pagefind's
// width/height animation. The important declaration deliberately overrides its scoped styles.
const filter = rules.find(([, selector, declarations]) =>
    selector.includes('.pagefind-ui__filter-value--checked')
    && /transition\s*:\s*none\s*!important(?:;|$)/.test(declarations));
assert.ok(filter, 'Rendered docs must override the Pagefind checkmark layout transition');

const install = rules.find(([, selector, declarations]) =>
    selector.includes('.install-link') && /box-shadow\s*:\s*none(?:;|$)/.test(declarations));
assert.ok(install, 'Rendered Install button must have no blur glow');
console.log('Rendered docs motion: OK');
