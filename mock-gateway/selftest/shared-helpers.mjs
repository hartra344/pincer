import assert from 'node:assert/strict';
import zlib from 'node:zlib';
import { crc32, encodePng, pngChunk } from '../png.mjs';
import { hasPairingScope, hasScope, scopeApproved } from '../scopes.mjs';
import { isObject } from '../util.mjs';

export async function run() {
  // Scopes: admin covers everything, write covers read, nothing else crosses over.
  assert.equal(scopeApproved(['operator.read'], 'operator.read'), true);
  assert.equal(scopeApproved(['operator.write'], 'operator.read'), true);
  assert.equal(scopeApproved(['operator.admin'], 'operator.pairing'), true);
  assert.equal(scopeApproved(['operator.read'], 'operator.write'), false);
  assert.equal(scopeApproved(['operator.write'], 'operator.admin'), false);
  assert.equal(scopeApproved([], 'operator.read'), false);
  assert.equal(hasScope({}, 'operator.read'), false);
  assert.equal(hasScope({ scopes: ['operator.write'] }, 'operator.write'), true);
  assert.equal(hasPairingScope({ scopes: ['operator.pairing'] }), true);
  assert.equal(hasPairingScope({ scopes: ['operator.admin'] }), true);
  assert.equal(hasPairingScope({ scopes: ['operator.write'] }), false);
  assert.equal(hasPairingScope({}), false);

  // isObject: plain objects only.
  assert.equal(isObject({}), true);
  assert.equal(isObject([]), false);
  assert.equal(isObject(null), false);
  assert.equal(isObject(undefined), false);
  assert.equal(isObject('x'), false);

  // PNG helpers.
  assert.equal(crc32(Buffer.from('IEND')), 0xae426082);
  const iend = pngChunk('IEND', Buffer.alloc(0));
  assert.equal(iend.toString('hex'), '0000000049454e44ae426082');
  const raw = Buffer.from([0, 10, 20, 30, 255, 0, 40, 50, 60, 255]);
  const png = encodePng(2, 1, 6, raw);
  assert.equal(png.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  assert.equal(png.readUInt32BE(16), 2);
  assert.equal(png.readUInt32BE(20), 1);
  assert.equal(png[24], 8);
  assert.equal(png[25], 6);
  assert.deepEqual(png.subarray(png.length - 12), iend);
  const idatAt = png.indexOf('IDAT');
  const idat = png.subarray(idatAt + 4, idatAt + 4 + png.readUInt32BE(idatAt - 4));
  assert.deepEqual(zlib.inflateSync(idat), raw);
  assert.equal(encodePng(2, 1, 0, raw)[25], 0);
}
