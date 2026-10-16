import assert from 'node:assert/strict';
import { BROWSER_PAGE_TITLE, BROWSER_PAGE_URL } from '../link-preview.mjs';

export async function run(ctx) {
  const { client } = ctx;
  assert.ok(client.hello.features.methods.includes('controlUi.linkPreview'));
  const preview = await client.send('controlUi.linkPreview', { url: BROWSER_PAGE_URL });
  assert.equal(preview.title, BROWSER_PAGE_TITLE);
  assert.match(preview.imageDataUrl, /^data:image\/png;base64,/);
  assert.match(preview.faviconDataUrl, /^data:image\/png;base64,/);
  assert.ok(preview.imageDataUrl.length <= 350_000 && preview.faviconDataUrl.length <= 90_000);
  assert.deepEqual(await client.send('controlUi.linkPreview', { url: 'https://unknown.example/page' }), {});
  await assert.rejects(client.send('controlUi.linkPreview', { url: 'ftp://example.com' }));
}
