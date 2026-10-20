import assert from 'node:assert/strict';
import zlib from 'node:zlib';
import { crc32, encodePng, pngChunk } from '../png.mjs';
import { hasPairingScope, hasScope, scopeApproved } from '../scopes.mjs';
import { isObject, jsonClone } from '../util.mjs';
import { additionalPropertiesProblem, closedObjectProblem, commonFieldTypes } from '../params.mjs';

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

  // scopeApproved takes a Set too (paired-device scopes).
  assert.equal(scopeApproved(new Set(['operator.write']), 'operator.read'), true);
  assert.equal(scopeApproved(new Set(['operator.admin']), 'operator.pairing'), true);
  assert.equal(scopeApproved(new Set(['operator.read']), 'operator.write'), false);
  assert.equal(scopeApproved(new Set(), 'operator.read'), false);

  // jsonClone keeps JSON semantics (unlike structuredClone).
  assert.equal(jsonClone(undefined), undefined);
  assert.deepEqual(jsonClone({ a: 1, b: undefined, c: [1, { d: 2 }] }), { a: 1, c: [1, { d: 2 }] });
  assert.equal('b' in jsonClone({ b: undefined }), false);
  assert.equal(jsonClone({ at: new Date(0) }).at, '1970-01-01T00:00:00.000Z');
  const original = { nested: { x: 1 } };
  const copy = jsonClone(original);
  copy.nested.x = 2;
  assert.equal(original.nested.x, 1);

  // additionalPropertiesProblem.
  const allowed = ['channel', 'accountId'];
  assert.equal(additionalPropertiesProblem('channels.start', [], allowed), 'invalid channels.start params: must be object');
  assert.equal(additionalPropertiesProblem('channels.start', null, allowed), 'invalid channels.start params: must be object');
  assert.equal(
    additionalPropertiesProblem('channels.start', { channel: 'x', bogus: 1 }, allowed),
    'invalid channels.start params: must NOT have additional properties (bogus)',
  );
  assert.equal(additionalPropertiesProblem('channels.start', { channel: 'x' }, allowed), null);
  assert.equal(additionalPropertiesProblem('channels.start', {}, allowed), null);

  // closedObjectProblem and the shared field types.
  const types = { ...commonFieldTypes, flag: (v) => (v === true ? undefined : 'must be equal to constant') };
  const schema = { required: ['name'], fields: { name: 'nonEmpty', note: 'string', on: 'boolean', hash: 'sha256', flag: 'flag' } };
  assert.equal(closedObjectProblem(schema, {}, types), "at root: must have required property 'name'");
  assert.equal(closedObjectProblem(schema, { name: 'a', extra: 1 }, types), "at root: unexpected property 'extra'");
  assert.equal(closedObjectProblem(schema, { name: '' }, types), 'at /name: must NOT have fewer than 1 characters');
  assert.equal(closedObjectProblem(schema, { name: 1 }, types), 'at /name: must be string');
  assert.equal(closedObjectProblem(schema, { name: 'a', note: 1 }, types), 'at /note: must be string');
  assert.equal(closedObjectProblem(schema, { name: 'a', on: 'yes' }, types), 'at /on: must be boolean');
  assert.equal(closedObjectProblem(schema, { name: 'a', hash: 'abc' }, types), 'at /hash: must match pattern "^[a-fA-F0-9]{64}$"');
  assert.equal(closedObjectProblem(schema, { name: 'a', flag: false }, types), 'at /flag: must be equal to constant');
  assert.equal(closedObjectProblem(schema, { name: 'a', hash: 'A'.repeat(64), on: false, flag: true }, types), undefined);
  assert.equal(closedObjectProblem({ fields: { a: 'string' } }, {}, types), undefined);
}
