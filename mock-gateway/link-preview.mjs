import zlib from 'node:zlib';
import { pngChunk } from './seed.mjs';
import { sendErr, sendRes } from './util.mjs';

// `controlUi.linkPreview` (openclaw src/gateway/control-ui-contract.ts): params exactly {url};
// result {title?, description?, imageDataUrl?, faviconDataUrl?}, or {} when there is nothing to show.
export const LINK_PREVIEW_METHOD = 'controlUi.linkPreview';
export const LINK_PREVIEW_METHODS = new Set([LINK_PREVIEW_METHOD]);

export const BROWSER_PAGE_URL = 'https://www.marriott.com/reservation/availabilitySearch.mi?destinationAddress.city=Lisbon&fromDate=11%2F14%2F2026&toDate=11%2F17%2F2026';
export const BROWSER_PAGE_TITLE = 'Find & Book Hotels in Lisbon | Marriott Bonvoy';
export const BROWSER_PAGE_DESCRIPTION = 'Compare rates for 3 nights in Lisbon, 14 to 17 November.';

function solidPng(width, height, pixel) {
  const raw = Buffer.alloc((width * 4 + 1) * height);
  for (let y = 0; y < height; y++) {
    const row = y * (width * 4 + 1);
    for (let x = 0; x < width; x++) {
      const [r, g, b] = pixel(x, y);
      raw.set([r, g, b, 255], row + 1 + x * 4);
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8;
  ihdr[9] = 6;
  return Buffer.concat([
    Buffer.from('89504e470d0a1a0a', 'hex'),
    pngChunk('IHDR', ihdr),
    pngChunk('IDAT', zlib.deflateSync(raw)),
    pngChunk('IEND', Buffer.alloc(0)),
  ]);
}

const dataUrl = (png) => `data:image/png;base64,${png.toString('base64')}`;

export function browserPreviewResult() {
  return {
    title: BROWSER_PAGE_TITLE,
    description: BROWSER_PAGE_DESCRIPTION,
    imageDataUrl: dataUrl(solidPng(191, 100, (x, y) => [150 + Math.floor(x / 4), 40 + y, 60 + Math.floor(y / 2)])),
    faviconDataUrl: dataUrl(solidPng(16, 16, (x, y) => ((x + y) % 4 < 2 ? [176, 38, 63] : [255, 255, 255]))),
  };
}

export function handleLinkPreviewRequest(state, conn, msg) {
  if (!LINK_PREVIEW_METHODS.has(msg.method)) return false;
  const url = msg.params?.url;
  if (typeof url !== 'string' || !/^https?:\/\//.test(url)) {
    sendErr(conn, msg.id, 'INVALID_REQUEST', 'invalid controlUi.linkPreview params: url must be an http(s) URL');
    return true;
  }
  sendRes(conn, msg.id, url === BROWSER_PAGE_URL ? browserPreviewResult() : {});
  return true;
}
