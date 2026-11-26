import { test } from 'node:test';
import assert from 'node:assert/strict';
import { networkSettings } from '../src/network.ts';

test('defaults to direct and ignores unused proxy fields', () => {
  assert.equal(networkSettings({}).mode, 'direct');
  assert.equal(networkSettings({ connectionMode: 'direct', proxyPort: 'bad' }).mode, 'direct');
  assert.equal(networkSettings({ connectionMode: 'system', proxyHost: 'bad/path' }).mode, 'system');
});
test('accepts explicit SOCKS5 and HTTP proxy endpoints', () => {
  for (const connectionMode of ['socks5', 'http']) {
    assert.deepEqual(networkSettings({ connectionMode, proxyHost: ' localhost ', proxyPort: '1080' }),
      { mode: connectionMode, proxyHost: 'localhost', proxyPort: 1080 });
  }
});
test('rejects invalid proxy modes, hosts, and ports', () => {
  assert.throws(() => networkSettings({ connectionMode: 'unknown' }));
  for (const proxyPort of ['0', '65536', '1.5', '1e3', '-1', 'NaN']) {
    assert.throws(() => networkSettings({ connectionMode: 'socks5', proxyPort }));
  }
  for (const proxyHost of ['http://localhost', 'name@example.com', 'local host', '\u0001']) {
    assert.throws(() => networkSettings({ connectionMode: 'http', proxyHost }));
  }
});
