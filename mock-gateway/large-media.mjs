import zlib from 'node:zlib';
import { makePng, pngChunk } from './seed.mjs';

// Big images for memory and size-cap testing (`image huge` and `image many` in chat.mjs).
// Built on first use so a plain mock start doesn't hold tens of megabytes.

export const HUGE_ARTIFACT_ID = 'art-huge-1';
export const HUGE_BYTES = 26 * 1024 * 1024;
export const MANY_COUNT = 40;
export const MANY_WIDTH = 3000;
export const MANY_HEIGHT = 2000;

export const manyArtifactId = (index) => `art-many-${String(index + 1).padStart(2, '0')}`;

let hugePng;
let manyPng;

/** A valid PNG (the 320×200 chart) padded with a private ancillary chunk to just over 25 MiB. */
export function makeHugePng() {
  if (!hugePng) {
    const png = makePng();
    const iend = png.subarray(png.length - 12);
    hugePng = Buffer.concat([
      png.subarray(0, png.length - 12),
      pngChunk('mkPd', Buffer.alloc(HUGE_BYTES - png.length - 12)),
      iend,
    ]);
  }
  return hugePng;
}

/** A gradient PNG that compresses to a few hundred KB but decodes to width × height × 4 bytes. */
export function makeLargePng(width = MANY_WIDTH, height = MANY_HEIGHT) {
  if (!manyPng) {
    const stride = width * 4 + 1;
    const raw = Buffer.alloc(stride * height);
    for (let y = 0; y < height; y++) {
      const row = y * stride;
      for (let x = 0; x < width; x++) {
        const i = row + 1 + x * 4;
        raw[i] = (x * 255 / width) | 0;
        raw[i + 1] = (y * 255 / height) | 0;
        raw[i + 2] = ((x >> 6) + (y >> 6)) & 1 ? 200 : 90;
        raw[i + 3] = 255;
      }
    }
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(width, 0);
    ihdr.writeUInt32BE(height, 4);
    ihdr[8] = 8;
    ihdr[9] = 6;
    manyPng = Buffer.concat([
      Buffer.from('89504e470d0a1a0a', 'hex'),
      pngChunk('IHDR', ihdr),
      pngChunk('IDAT', zlib.deflateSync(raw, { level: 1 })),
      pngChunk('IEND', Buffer.alloc(0)),
    ]);
  }
  return manyPng;
}

function imageRef(artifactId, alt, width, height) {
  return { type: 'image', artifactId, mimeType: 'image/png', alt, width, height };
}

/** Registers the artifacts and returns the image blocks for `image huge` / `image many`. */
export function largeImageBlocks(state, kind) {
  if (kind === 'huge') {
    state.artifacts.set(HUGE_ARTIFACT_ID, { artifactId: HUGE_ARTIFACT_ID, mimeType: 'image/png', data: makeHugePng() });
    return [imageRef(HUGE_ARTIFACT_ID, 'Oversized image (26 MiB)', 320, 200)];
  }
  const data = makeLargePng();
  return Array.from({ length: MANY_COUNT }, (_, i) => {
    const artifactId = manyArtifactId(i);
    state.artifacts.set(artifactId, { artifactId, mimeType: 'image/png', data });
    return imageRef(artifactId, `Large image ${i + 1} of ${MANY_COUNT}`, MANY_WIDTH, MANY_HEIGHT);
  });
}
