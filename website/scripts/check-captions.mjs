import { readFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const website = fileURLToPath(new URL('..', import.meta.url));

async function checkCaption(page, marker, expected) {
	const file = path.join(website, 'dist', page, 'index.html');
	const html = await readFile(file, 'utf8');
	const captions = [...html.matchAll(/<figcaption\b[^>]*>([\s\S]*?)<\/figcaption>/gi)].map((match) => match[1]);
	const caption = captions.find((value) => value.includes(marker));
	if (!caption) throw new Error(`${page}: rendered DocScreenshot caption containing “${marker}” was not found`);
	if (/\\u[0-9a-f]{4}/i.test(caption)) throw new Error(`${page}: rendered caption contains a literal Unicode escape`);
	if (!caption.includes(expected)) throw new Error(`${page}: rendered caption is missing “${expected}”`);
}

await checkCaption('guides/agents', 'workspace instructions', 'agent’s workspace instructions');
await checkCaption('guides/transcript', 'forwarded messages retain her name', 'Kiko’s forwarded messages retain her name');
console.log('Rendered DocScreenshot captions: OK');
