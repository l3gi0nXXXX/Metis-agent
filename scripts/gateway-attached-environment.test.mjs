import assert from 'node:assert/strict';
import test from 'node:test';
import { attachedBusinessEnvironment } from './metis-stdio-broker.mjs';

const marker = 'METIS_STDIO_ATTACHED_CF_ENV_V1';
const cf = '__CF_USER_TEXT_ENCODING';
const encode = (original) => JSON.stringify([1,
  Object.hasOwn(original, cf), original[cf] ?? '',
  Object.hasOwn(original, marker), original[marker] ?? '']);

test('R-NG-CF-ENV-P1 decoder preserves original optional CF and colliding marker bytes', () => {
  let scenarios = 0;
  for (const value of [undefined, '', '合成😀\n\"quoted\"', '0x0:0:0']) {
    for (const previous of [undefined, '', '原见证😀\n']) {
      const original = { PATH: '/usr/bin:/bin', EMPTY: '' };
      for (const [key, entry] of [[cf, value], [marker, previous]]) {
        if (entry !== undefined) original[key] = entry;
      }
      const helper = { ...original, [marker]: encode(original), [cf]: 'runtime-added' };
      const snapshot = { ...helper };
      assert.deepEqual(attachedBusinessEnvironment(helper, 'darwin'), original);
      assert.deepEqual(helper, snapshot);
      scenarios += 1;
    }
  }
  assert.equal(scenarios, 12);
});

test('R-NG-CF-ENV-N1 decoder rejects invalid witness without exposing values', () => {
  const invalid = ['{', 'null', '{}', '[]', JSON.stringify([2, false, '', false, '']),
    JSON.stringify([1, false, '', false, '', 'extra']), JSON.stringify([1, 0, '', false, '']),
    JSON.stringify([1, false, '', 0, '']), JSON.stringify([1, false, 'not-empty', false, '']),
    JSON.stringify([1, false, '', false, 'not-empty']), JSON.stringify([1, true, '\0', false, '']),
    JSON.stringify([1, false, '', true, '\ud800']), JSON.stringify([1, true, '\ud800', false, '']),
    JSON.stringify([1, false, '', false])];
  for (const text of invalid) {
    const environment = { [marker]: text, [cf]: 'runtime-added' };
    const snapshot = { ...environment };
    assert.throws(() => attachedBusinessEnvironment(environment, 'darwin'),
      { message: 'attached_environment_invalid' });
    assert.deepEqual(environment, snapshot);
  }
  assert.deepEqual(attachedBusinessEnvironment({ EMPTY: '' }, 'darwin'), { EMPTY: '' });
  assert.deepEqual(attachedBusinessEnvironment({ [marker]: 'user-value' }, 'linux'), { [marker]: 'user-value' });
});
